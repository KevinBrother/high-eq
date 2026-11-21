// Package events is the synchronous, in-process T03 bus. Publishers call a
// Publish method only after committing the source; a returned error must be
// retried with the original event. Subscribe during startup, before serving.
package events

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/privacy"
)

type Topic[T any] struct {
	handlers []func(context.Context, pgx.Tx, T) error
}

func (t *Topic[T]) HasSubscribers() bool { return len(t.handlers) != 0 }

func (t *Topic[T]) Subscribe(h func(context.Context, pgx.Tx, T) error) {
	t.handlers = append(t.handlers, h)
}
func (t *Topic[T]) dispatch(ctx context.Context, tx pgx.Tx, v T) error {
	if len(t.handlers) == 0 {
		return errors.New("no subscriber")
	}
	for _, h := range t.handlers {
		if e := h(ctx, tx, v); e != nil {
			return e
		}
	}
	return nil
}

type Assessment struct {
	UserID       uuid.UUID `json:"user_id"`
	AssessmentID uuid.UUID `json:"assessment_id"`
	OccurredAt   time.Time `json:"occurred_at"`
}
type Drill struct {
	UserID     uuid.UUID `json:"user_id"`
	ActivityID uuid.UUID `json:"activity_id"`
	LevelID    uuid.UUID `json:"level_id"`
	OccurredAt time.Time `json:"occurred_at"`
	TargetItem string    `json:"target_item"`
	Score      int       `json:"score"`
}
type Feedback struct {
	FeedbackID uuid.UUID  `json:"feedback_id"`
	UserID     uuid.UUID  `json:"user_id"`
	SourceID   uuid.UUID  `json:"source_id"`
	SourceKind string     `json:"source_kind"`
	Subject    string     `json:"subject"`
	ContactID  *uuid.UUID `json:"contact_id,omitempty"`
	OccurredAt time.Time  `json:"occurred_at"`
}
type Score struct {
	privacy.ScoreKey
	ScoreValues
}
type ScoreValues struct {
	NVC struct {
		Observation int `json:"observation"`
		Feeling     int `json:"feeling"`
		Need        int `json:"need"`
		Request     int `json:"request"`
		Total       int `json:"total"`
	} `json:"nvc"`
	Emotion struct {
		ReadOthers     int `json:"read_others"`
		SelfManagement int `json:"self_management"`
		Relationship   int `json:"relationship"`
	} `json:"emotion"`
}
type Bus struct {
	guard               *privacy.Coordinator
	decode              func(privacy.ScoreSource) (ScoreValues, error)
	ScoreCompleted      Topic[Score]
	AssessmentCompleted Topic[Assessment]
	DrillProgressed     Topic[Drill]
	ProfileFeedback     Topic[Feedback]
}

// decode is supplied by the trusted score owner, not by subscribers. Without
// the T12/T19/T23 envelope decoder, score publication fails closed.
func New(guard *privacy.Coordinator, decode func(privacy.ScoreSource) (ScoreValues, error)) *Bus {
	return &Bus{guard: guard, decode: decode}
}
func (b *Bus) PublishScore(ctx context.Context, v Score) error {
	if b.decode == nil {
		return errors.New("canonical score decoder unavailable")
	}
	return b.guard.ConsumeScore(ctx, v.ScoreKey, func(ctx context.Context, tx pgx.Tx, src privacy.ScoreSource) error {
		values, err := b.decode(src)
		if err != nil {
			return err
		}
		return b.ScoreCompleted.dispatch(ctx, tx, Score{src.ScoreKey, values})
	})
}
func (b *Bus) PublishAssessment(ctx context.Context, v Assessment) error {
	return b.guard.Access(ctx, v.UserID, func(tx pgx.Tx) error {
		if e := tx.QueryRow(ctx, `select completed_at from assessments where user_id=$1 and id=$2 for update`, v.UserID, v.AssessmentID).Scan(&v.OccurredAt); e != nil {
			return e
		}
		if e := b.AssessmentCompleted.dispatch(ctx, tx, v); e != nil {
			return e
		}
		// Acknowledge the outbox in the same transaction as subscriber writes.
		_, e := tx.Exec(ctx, `update assessments set completion_pending=false where id=$1 and user_id=$2 and completion_pending`, v.AssessmentID, v.UserID)
		return e
	})
}
func (b *Bus) PublishDrill(ctx context.Context, v Drill) error {
	return b.guard.Access(ctx, v.UserID, func(tx pgx.Tx) error {
		var id uuid.UUID
		if e := tx.QueryRow(ctx, `select id from activities where user_id=$1 and id=$2 and kind='drill' for update`, v.UserID, v.ActivityID).Scan(&id); e != nil {
			return e
		}
		return b.DrillProgressed.dispatch(ctx, tx, v)
	})
}
func (b *Bus) PublishFeedback(ctx context.Context, v Feedback) error {
	return b.guard.Access(ctx, v.UserID, func(tx pgx.Tx) error {
		scope := map[string]string{"reply": "replies", "review": "reviews", "self_event": "signal_events"}[v.SourceKind]
		if scope == "" || (v.Subject != "self" && v.Subject != "contact") || (v.Subject == "contact") != (v.ContactID != nil) || (v.SourceKind == "self_event" && v.Subject != "self") {
			return errors.New("invalid feedback subject")
		}
		var id uuid.UUID
		if e := tx.QueryRow(ctx, `select root_id from erasure_roots where user_id=$1 and scope=$2 and root_id=$3 and ($4::uuid is null or parent_id=$4)`, v.UserID, scope, v.SourceID, v.ContactID).Scan(&id); e != nil {
			return e
		}
		return b.ProfileFeedback.dispatch(ctx, tx, v)
	})
}
