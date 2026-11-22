package profile

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/events"
	"high-eq/server/internal/membership"
)

// The event is only a key. Direction comes from the user's explicit judgment,
// never from the suggested response, transcript, score, or voice rhythm.
type fact struct {
	Vote     *vote  `json:"vote,omitempty"`
	Positive bool   `json:"positive"`
	Scene    string `json:"scene,omitempty"`
}

type activityContext struct {
	Scene string `json:"scene"`
}

func (s *Service) readActivityContext(ctx context.Context, tx pgx.Tx, u, activity uuid.UUID) (string, error) {
	var b []byte
	if e := tx.QueryRow(ctx, `select context_enc from activity_profile_context where user_id=$1 and activity_id=$2`, u, activity).Scan(&b); e != nil {
		return "", e
	}
	var c activityContext
	if e := s.open("activity-context", u, activity, b, &c); e != nil {
		return "", e
	}
	if c.Scene != "" && !scene(c.Scene) {
		return "", errors.New("invalid activity context")
	}
	return c.Scene, nil
}

// bindActivityContext freezes the source scene, including a verified null.
// A nil input may reuse the frozen value; a provided value must match it.
func (s *Service) bindActivityContext(ctx context.Context, tx pgx.Tx, u, activity uuid.UUID, sc *string) (string, error) {
	var initial activityContext
	if sc != nil {
		initial.Scene = *sc
	}
	b, e := s.seal("activity-context", u, activity, initial)
	if e != nil {
		return "", e
	}
	if _, e = tx.Exec(ctx, `insert into activity_profile_context(user_id,activity_id,context_enc) values($1,$2,$3) on conflict(user_id,activity_id) do nothing`, u, activity, b); e != nil {
		return "", e
	}
	got, e := s.readActivityContext(ctx, tx, u, activity)
	if e != nil {
		return "", e
	}
	if sc != nil && got != *sc {
		return "", membership.ErrConflict
	}
	return got, nil
}

func (s *Service) signal(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (r emotion.FeedbackSource, e error) {
	var b []byte
	var contact *uuid.UUID
	e = tx.QueryRow(ctx, `select event_enc,contact_id from signal_events where user_id=$1 and id=$2 and occurred_at>now()-interval '4320 hours'`, u, id).Scan(&b, &contact)
	if e == nil {
		r, e = (emotion.Service{Fields: s.Fields}).DecodeFeedback(u, id, b)
		if errors.Is(e, emotion.Invalid) {
			e = accounts.ErrInvalid
		}
	}
	if e == nil && (!same(contact, r.ContactId)) {
		e = accounts.ErrInvalid
	}
	return
}
func same(a, b *uuid.UUID) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
func (s *Service) guardFeedback(ctx context.Context, tx pgx.Tx, u uuid.UUID, c *uuid.UUID) error {
	if c == nil {
		return nil
	}
	return s.write(ctx, tx, u, c)
}

// RecordActivity belongs in T21/T23's explicit feedback transaction, before publishing the key.
// One source + subject is one vote. Replaying it cannot increase confidence.
func (s *Service) RecordActivity(ctx context.Context, tx pgx.Tx, v events.Feedback, note, sc string) error {
	if v.FeedbackID == uuid.Nil || v.OccurredAt.IsZero() || (sc != "" && !scene(sc)) || (v.SourceKind != "reply" && v.SourceKind != "review") {
		return accounts.ErrInvalid
	}
	var activity uuid.UUID
	var parent *uuid.UUID
	if e := tx.QueryRow(ctx, `select id,contact_id from activities where user_id=$1 and source_id=$2 and kind::text=$3 and state='complete'`, v.UserID, v.SourceID, v.SourceKind).Scan(&activity, &parent); e != nil {
		return e
	}
	if e := s.guardFeedback(ctx, tx, v.UserID, parent); e != nil {
		return e
	}
	f := fact{}
	switch v.Subject {
	case "contact":
		if parent == nil || !same(parent, v.ContactID) {
			return accounts.ErrInvalid
		}
		x, ok := observed(note)
		if !ok {
			return accounts.ErrInvalid
		}
		if x.Axis == 6 {
			d, e := s.read(ctx, tx, v.UserID, *parent)
			if e != nil {
				return e
			}
			if d.Scene != "partner" {
				return accounts.ErrInvalid
			}
		}
		f.Vote = &x
	case "self":
		if v.ContactID != nil || (note != "本人上头" && note != "本人没有上头") {
			return accounts.ErrInvalid
		}
		var sourceScene *string
		if v.SourceKind == "review" {
			original, e := s.reviewActivityScene(ctx, tx, v.UserID, activity)
			if e != nil {
				return e
			}
			if sc != "" && sc != original {
				return membership.ErrConflict
			}
			sourceScene = &original
		} else if sc != "" {
			sourceScene = &sc
		}
		frozen, e := s.bindActivityContext(ctx, tx, v.UserID, activity, sourceScene)
		if e != nil {
			return e
		}
		f.Scene = frozen
		f.Positive = note == "本人上头"
	default:
		return accounts.ErrInvalid
	}
	enc, e := s.seal("feedback", v.UserID, v.FeedbackID, f)
	if e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `insert into profile_observations(id,user_id,activity_id,subject,fact_enc,occurred_at) values($1,$2,$3,$4,$5,$6) on conflict do nothing`, v.FeedbackID, v.UserID, activity, v.Subject, enc, v.OccurredAt)
	if e != nil {
		return e
	}
	var existing uuid.UUID
	var b []byte
	e = tx.QueryRow(ctx, `select id,fact_enc from profile_observations where user_id=$1 and activity_id=$2 and subject=$3`, v.UserID, activity, v.Subject).Scan(&existing, &b)
	if e != nil {
		return e
	}
	var old fact
	if e = s.open("feedback", v.UserID, existing, b, &old); e != nil {
		return e
	}
	if existing != v.FeedbackID || old.Positive != f.Positive || old.Scene != f.Scene || (old.Vote != nil) != (f.Vote != nil) || old.Vote != nil && *old.Vote != *f.Vote {
		return membership.ErrConflict
	}
	return nil
}
func (s *Service) Consume(ctx context.Context, tx pgx.Tx, v events.Feedback) error {
	if v.FeedbackID == uuid.Nil || v.OccurredAt.IsZero() {
		return accounts.ErrInvalid
	}
	if v.SourceKind == "self_event" {
		if v.Subject != "self" || v.ContactID != nil {
			return accounts.ErrInvalid
		}
		r, e := s.signal(ctx, tx, v.UserID, v.SourceID)
		if e != nil {
			return e
		}
		if v.FeedbackID != r.FeedbackID || !v.OccurredAt.Equal(*r.ConfirmedAt) {
			return accounts.ErrInvalid
		}
		if e = s.guardFeedback(ctx, tx, v.UserID, r.ContactId); e != nil {
			return e
		}
		for _, purpose := range []string{"health", "voice"} {
			if e = consent(ctx, tx, v.UserID, purpose); e != nil {
				return e
			}
		}
		b, e := s.seal("feedback", v.UserID, v.FeedbackID, fact{Positive: r.Positive()})
		if e != nil {
			return e
		}
		_, e = tx.Exec(ctx, `insert into profile_observations(id,user_id,event_id,subject,fact_enc,occurred_at,applied) values($1,$2,$3,'self',$4,$5,true) on conflict(event_id) do nothing`, v.FeedbackID, v.UserID, v.SourceID, b, v.OccurredAt)
		return e
	}
	var contact *uuid.UUID
	var at time.Time
	e := tx.QueryRow(ctx, `select a.contact_id,o.occurred_at from profile_observations o join activities a on a.id=o.activity_id where o.id=$1 and o.user_id=$2 and a.source_id=$3 and a.kind::text=$4 and a.state='complete' and o.subject=$5`, v.FeedbackID, v.UserID, v.SourceID, v.SourceKind, v.Subject).Scan(&contact, &at)
	if e != nil {
		return e
	}
	if (v.Subject == "contact" && !same(contact, v.ContactID)) || (v.Subject == "self" && v.ContactID != nil) || !at.Equal(v.OccurredAt.Truncate(time.Microsecond)) {
		return accounts.ErrInvalid
	}
	if e = s.guardFeedback(ctx, tx, v.UserID, contact); e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `update profile_observations set applied=true where id=$1`, v.FeedbackID)
	return e
}
func (s *Service) Explicit(ctx context.Context, tx pgx.Tx, u uuid.UUID, in app.SendProfileFeedbackInput) error {
	if !in.Confirmed || in.Subject == "conversation" || in.SourceId == uuid.Nil {
		return accounts.ErrInvalid
	}
	var kind string
	var parent *uuid.UUID
	e := tx.QueryRow(ctx, `select kind::text,contact_id from activities where user_id=$1 and source_id=$2 and kind in ('review','reply')`, u, in.SourceId).Scan(&kind, &parent)
	if errors.Is(e, pgx.ErrNoRows) {
		r, e := s.signal(ctx, tx, u, in.SourceId)
		if e != nil {
			return e
		}
		if in.Subject != "self" || (in.ContactId != nil && !same(in.ContactId, r.ContactId)) {
			return accounts.ErrInvalid
		}
		return s.Consume(ctx, tx, events.Feedback{UserID: u, SourceID: r.Id, Subject: "self", SourceKind: "self_event", FeedbackID: r.FeedbackID, OccurredAt: *r.ConfirmedAt})
	}
	if e != nil {
		return e
	}
	if in.ContactId != nil && !same(in.ContactId, parent) {
		return accounts.ErrInvalid
	}
	v := events.Feedback{UserID: u, SourceID: in.SourceId, Subject: string(in.Subject), SourceKind: kind, FeedbackID: uuid.NewSHA1(in.SourceId, []byte(in.Subject)), OccurredAt: time.Now().UTC().Truncate(time.Microsecond)}
	if in.Subject == "contact" {
		v.ContactID = in.ContactId
	}
	// An omitted note may confirm an existing source judgment, never invent one.
	if in.Note == nil {
		e = tx.QueryRow(ctx, `select o.id,o.occurred_at from profile_observations o join activities a on a.id=o.activity_id where a.user_id=$1 and a.source_id=$2 and o.subject=$3`, u, in.SourceId, v.Subject).Scan(&v.FeedbackID, &v.OccurredAt)
		if errors.Is(e, pgx.ErrNoRows) {
			return accounts.ErrInvalid
		}
		if e != nil {
			return e
		}
		return s.Consume(ctx, tx, v)
	}
	if e = s.RecordActivity(ctx, tx, v, *in.Note, ""); e != nil {
		return e
	}
	if e = tx.QueryRow(ctx, `select occurred_at from profile_observations where user_id=$1 and id=$2`, u, v.FeedbackID).Scan(&v.OccurredAt); e != nil {
		return e
	}
	return s.Consume(ctx, tx, v)
}
func (s *Service) votes(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) ([]vote, error) {
	rows, e := tx.Query(ctx, `select o.id,o.fact_enc from profile_observations o join activities a on a.id=o.activity_id where o.applied and o.subject='contact' and o.user_id=$1 and a.contact_id=$2`, u, id)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	var out []vote
	for rows.Next() {
		var key uuid.UUID
		var b []byte
		var f fact
		if e = rows.Scan(&key, &b); e != nil {
			return nil, e
		}
		if e = s.open("feedback", u, key, b, &f); e != nil {
			return nil, e
		}
		if f.Vote != nil {
			out = append(out, *f.Vote)
		}
	}
	return out, rows.Err()
}
