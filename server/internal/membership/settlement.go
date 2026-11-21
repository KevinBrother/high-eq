package membership

import (
	"context"
	"errors"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Operation IDs are existing activities, never client-supplied account IDs.
// Only the caller receiving Work=true should start generation (after commit).
type Attempt struct {
	Token uuid.UUID
	State string
	Work  bool
}
type operation struct {
	Attempt
	feature string
	until   time.Time
}

func load(ctx context.Context, tx pgx.Tx, user, id uuid.UUID) (operation, error) {
	var op operation
	e := tx.QueryRow(ctx, `select a.kind::text,coalesce(q.state,''),coalesce(q.token,$3),coalesce(q.valid_until,a.created_at)
        from activities a left join quota_attempts q on q.activity_id=a.id
        where a.id=$1 and a.user_id=$2`, id, user, uuid.Nil).Scan(&op.feature, &op.State, &op.Token, &op.until)
	if e == nil && !slices.Contains(features, op.feature) {
		return op, ErrConflict
	}
	return op, e
}

// Begin returns the existing operation on reconnect. An expired worker can be replaced;
// moderation failures require explicit Retry with the failed attempt's token.
func (s *Service) Begin(ctx context.Context, tx pgx.Tx, user, id uuid.UUID) (Attempt, error) {
	return s.begin(ctx, tx, user, id, uuid.Nil)
}
func (s *Service) Retry(ctx context.Context, tx pgx.Tx, user, id, previous uuid.UUID) (Attempt, error) {
	if previous == uuid.Nil {
		return Attempt{}, ErrConflict
	}
	return s.begin(ctx, tx, user, id, previous)
}
func (s *Service) begin(ctx context.Context, tx pgx.Tx, user, id, previous uuid.UUID) (Attempt, error) {
	op, e := load(ctx, tx, user, id)
	if e != nil {
		return Attempt{}, e
	}
	a, e := s.access(ctx, tx, user)
	if e != nil {
		return Attempt{}, e
	}
	if previous != uuid.Nil {
		if previous != op.Token || op.State != string(ModerationUnavailable) {
			return op.Attempt, nil
		}
	} else if op.State != "" && !(op.State == "held" && !op.until.After(a.at)) {
		return op.Attempt, nil
	}
	metered := a.Daily[op.feature] != nil
	if metered {
		if _, e = s.capacity(ctx, tx, user, op.feature, a, id, true); e != nil {
			return Attempt{}, e
		}
	}
	at := Attempt{Token: uuid.New(), State: "held", Work: true}
	_, e = tx.Exec(ctx, `insert into quota_attempts(activity_id,token,state,held_day,valid_until,metered)
        values($1,$2,'held',$3::date,$4,$5)
        on conflict(activity_id) do update set token=excluded.token,state='held',held_day=excluded.held_day,valid_until=excluded.valid_until,metered=excluded.metered`, id, at.Token, a.day, a.at.Add(time.Duration(s.policy.LeaseSeconds)*time.Second), metered)
	return at, e
}

// SaveApproved is called only after whole-output moderation. persist writes the
// retrievable encrypted source in THIS transaction (never external IO). On any
// error the caller must roll back, including writes performed by persist.
func (s *Service) SaveApproved(ctx context.Context, tx pgx.Tx, user, id, token uuid.UUID, persist func(pgx.Tx) error) error {
	op, e := load(ctx, tx, user, id)
	if e != nil {
		return e
	}
	if op.Token != token || token == uuid.Nil {
		return ErrConflict
	}
	switch op.State {
	case "accepted", "complete":
		return nil
	case "held":
	default:
		return ErrConflict
	}
	a, e := s.access(ctx, tx, user)
	if e != nil {
		return e
	}
	if !op.until.After(a.at) || persist == nil {
		return ErrConflict
	}
	metered := a.Daily[op.feature] != nil
	if metered {
		if _, e = s.capacity(ctx, tx, user, op.feature, a, id, true); e != nil {
			return e
		}
	}
	if e = persist(tx); e != nil {
		return e
	}
	var saved bool
	if e = tx.QueryRow(ctx, `select (case when kind='practice' then exists(
            select from practice_messages where activity_id=a.id and role='assistant' and octet_length(content_enc)>0
        ) else octet_length(content_enc)>0 end) is true
        from activities a where a.id=$1 and user_id=$2`, id, user).Scan(&saved); e != nil {
		return e
	}
	if !saved {
		return errors.New("approved result is not retrievable")
	}
	if metered {
		tag, e := tx.Exec(ctx, `insert into quota_ledger(activity_id,charged_day,charged_at) values($1,$2::date,$3)
            on conflict(activity_id) do update set charged_day=excluded.charged_day,charged_at=excluded.charged_at,refunded_at=null
            where quota_ledger.refunded_at is not null`, id, a.day, a.at)
		if e != nil {
			return e
		}
		if tag.RowsAffected() != 1 {
			return ErrConflict
		}
		if _, e = tx.Exec(ctx, `insert into daily_quota_usage(user_id,feature,charged_day,used) values($1,$2,$3::date,1)
            on conflict(user_id,feature,charged_day) do update set used=daily_quota_usage.used+1`, user, op.feature, a.day); e != nil {
			return e
		}
	}
	state := "accepted"
	if op.feature != "practice" {
		state = "complete"
	}
	_, e = tx.Exec(ctx, `update quota_attempts set state=$2 where activity_id=$1`, id, state)
	return e
}

type Outcome string

const (
	Completed             Outcome = "complete"
	Exited                Outcome = "exited"
	Failed                Outcome = "failed"
	Safety                Outcome = "safety"
	ModerationUnavailable Outcome = "moderation_unavailable"
)

func transition(from string, event Outcome) (string, bool, error) {
	switch event {
	case Completed, Exited, Failed, Safety, ModerationUnavailable:
	default:
		return from, false, ErrConflict
	}
	switch from {
	case "held", "accepted":
	case "":
		return from, false, ErrConflict
	default:
		return from, false, nil
	}
	if event == Completed && from != "accepted" {
		return from, false, ErrConflict
	}
	return string(event), event == Failed || event == Safety || event == ModerationUnavailable, nil
}

// Finish never requires the quota cache. A rollback, duplicate notification or
// next-day retry cannot refund twice; deletion of a source is NOT a refund.
func (s *Service) Finish(ctx context.Context, tx pgx.Tx, user, id, token uuid.UUID, event Outcome) error {
	op, e := load(ctx, tx, user, id)
	if e != nil {
		return e
	}
	if token != op.Token || token == uuid.Nil {
		return ErrConflict
	}
	state, refund, e := transition(op.State, event)
	if e != nil || op.State == state {
		return e
	}
	if refund {
		var day string
		e = tx.QueryRow(ctx, `update quota_ledger set refunded_at=greatest(charged_at,$2::timestamptz) where activity_id=$1 and refunded_at is null returning charged_day::text`, id, s.now()).Scan(&day)
		if e == nil {
			tag, e := tx.Exec(ctx, `update daily_quota_usage set used=used-1 where user_id=$1 and feature=$2 and charged_day=$3::date and used>0`, user, op.feature, day)
			if e != nil {
				return e
			}
			if tag.RowsAffected() != 1 {
				return errors.New("missing original daily charge")
			}
		} else if !errors.Is(e, pgx.ErrNoRows) {
			return e
		}
	}
	_, e = tx.Exec(ctx, `update quota_attempts set state=$2 where activity_id=$1`, id, state)
	return e
}
