package emotion

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

func WindowKey(ctx context.Context, tx pgx.Tx, u uuid.UUID, channel string, at time.Time) (uuid.UUID, error) {
	var id uuid.UUID
	if !aligned(at) || (channel != "health" && channel != "voice") {
		return id, Invalid
	}
	e := tx.QueryRow(ctx, `select purge_id from signal_windows where user_id=$1 and channel=$2 and starts_at=$3`, u, channel, at).Scan(&id)
	return id, e
}
func Hooks(fields *fieldcrypt.Cipher) privacy.Module {
	s := Service{Fields: fields}
	return privacy.Module{Name: "emotion", Delete: func(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
		// Baselines and adjustments are views over surviving sources. Never extend an
		// aggregate's life by touching updated_at. Drop any old materialization.
		switch d.Scope {
		case "signal_windows", "signal_events", "contacts", "account":
			_, e := tx.Exec(ctx, `delete from signal_baselines where user_id=$1`, d.UserID)
			return e
		}
		return nil
	}, Export: func(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
		now := time.Now()
		from := now.Add(-retention)
		e := s.windows(ctx, tx, q.UserID, from, now, func(w Window) error { return emit(map[string]any{"window": w}) })
		if e != nil {
			return e
		}
		e = s.walkEvents(ctx, tx, q.UserID, from, now, func(r record) error { return emit(map[string]any{"event": r.SignalEvent}) })
		if e != nil {
			return e
		}
		b, e := s.Baselines(ctx, tx, q.UserID, now)
		if e != nil {
			return e
		}
		return emit(map[string]any{"baselines": b})
	}}
}

type root struct {
	user, id uuid.UUID
	scope    string
}

// Only keys leave discovery; erase under the coordinator lock, including frozen
// accounts. Old sources already disappear from reads before the next sweep.
func (s Service) PurgeDue(ctx context.Context, now time.Time) error {
	cut := now.Add(-retention)
	for {
		rows, e := s.DB.Query(ctx, `select user_id,purge_id,'signal_windows' from signal_windows where starts_at<=$1 union all select user_id,id,'signal_events' from signal_events where occurred_at<=$1 limit 128`, cut)
		if e != nil {
			return e
		}
		batch, e := pgx.CollectRows(rows, func(row pgx.CollectableRow) (v root, e error) { e = row.Scan(&v.user, &v.id, &v.scope); return })
		if e != nil || len(batch) == 0 {
			return e
		}
		for _, v := range batch {
			if e = s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: v.user, SourceID: v.id, Scope: v.scope}); e != nil {
				return e
			}
		}
	}
}

// At-least-once delivery, with one immutable ID/time per explicit answer. A
// crash after dispatch retries the same feedback_id; T25 deduplicates by it.
func (s Service) Deliver(ctx context.Context, u, id uuid.UUID) error {
	var f events.Feedback
	e := s.Data.Access(ctx, u, func(tx pgx.Tx) error {
		var pending bool
		e := tx.QueryRow(ctx, `select feedback_pending from signal_events where user_id=$1 and id=$2`, u, id).Scan(&pending)
		if e != nil || !pending {
			return e
		}
		r, e := s.event(ctx, tx, u, id, time.Now())
		if e != nil {
			return e
		}
		if r.Kind != Self || r.ConfirmedAt == nil || r.FeedbackID == uuid.Nil {
			return Invalid
		}
		f = events.Feedback{UserID: u, SourceID: id, FeedbackID: r.FeedbackID, SourceKind: "self_event", Subject: "self", OccurredAt: *r.ConfirmedAt}
		return nil
	})
	if e != nil || f.SourceID == uuid.Nil {
		return e
	}
	if e = s.Bus.PublishFeedback(ctx, f); e != nil {
		return e
	}
	return s.Data.Access(ctx, u, func(tx pgx.Tx) error {
		_, e := tx.Exec(ctx, `update signal_events set feedback_pending=false where user_id=$1 and id=$2`, u, id)
		return e
	})
}
func (s Service) ReplayPending(ctx context.Context) error {
	var after uuid.UUID
	var failed error
	for {
		rows, e := s.DB.Query(ctx, `select user_id,id from signal_events where feedback_pending and id>$1 and occurred_at>$2 order by id limit 128`, after, time.Now().Add(-retention))
		if e != nil {
			return e
		}
		batch, e := pgx.CollectRows(rows, func(row pgx.CollectableRow) (v root, e error) { e = row.Scan(&v.user, &v.id); return })
		if e != nil {
			return e
		}
		for _, v := range batch {
			if e = s.Deliver(ctx, v.user, v.id); e != nil {
				failed = errors.New("feedback pending")
			}
			after = v.id
		}
		if len(batch) < 128 {
			return failed
		}
	}
}
