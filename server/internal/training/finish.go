package training

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/scoring"
)

func (s *Service) Finish(parent context.Context, p accounts.Principal, id uuid.UUID) (any, error) {
	j, replay, e := s.claim(parent, p, id, uuid.Nil, "finish", "")
	if e != nil {
		return nil, e
	}
	if replay != nil {
		return replay.Data, nil
	}
	if j.Result != nil {
		return j.Result, nil
	}
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), 80*time.Second)
	defer cancel()
	r, e := s.runner(p, &j)
	if e != nil {
		return nil, s.failed(ctx, j, ErrGeneration)
	}
	svc := scoring.New(r, j.scope())
	turns := make([]scoring.Turn, 0, len(j.Messages))
	for _, m := range j.Messages {
		turns = append(turns, scoring.Turn{Role: string(m.Role), Text: m.Text})
	}
	var full *scoring.Full
	var progress *scoring.Progress
	var call uuid.UUID
	var term *gateway.Terminal
	if j.Target == nil {
		v, err := svc.ScoreSession(ctx, j.scene, turns, j.profile)
		full, call, term, e = v.Value, v.CallID, v.Terminal, err
	} else {
		v, err := svc.ScoreSkill(ctx, j.scene, turns, j.profile, *j.Target)
		progress, term, e = v.Value, v.Terminal, err
	}
	if term != nil {
		if e := s.settleTerminal(ctx, &j, *term); e != nil && !errors.Is(e, errSettlementPending) {
			return nil, e
		}
		return term, nil
	}
	if e != nil || full == nil && progress == nil {
		return nil, s.failed(ctx, j, ErrGeneration)
	}
	var result *Result
	e = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if e := s.check(ctx, tx, j); e != nil {
			return e
		}
		if e := s.allowed(ctx, tx, j.user, j.input); e != nil {
			return e
		}
		if full != nil {
			b, e := s.seal(j.user, j.source, "score", full)
			if e != nil {
				return e
			}
			if _, e = tx.Exec(ctx, `insert into scores(id,activity_id,activity_kind,detail_enc)values($1,$2,'practice',$3)`, j.source, id, b); e != nil {
				return e
			}
			if e = gateway.LinkScoreTx(ctx, tx, j.user, call, id, j.source); e != nil {
				return e
			}
		} else {
			b, e := s.seal(j.user, j.source, "progress", progress)
			if e != nil {
				return e
			}
			_, e = tx.Exec(ctx, `insert into drill_progress(activity_id,target_item,progress_enc,retry_at)values($1,$2,$3,case when $4='retry_in_three_days' then now()+interval '3 days' when $4='retry_now' then now() end)`, id, *j.Target, b, progress.NextAction)
			if e != nil {
				return e
			}
		}
		if j.held { // Explicit retry of a refunded scoring operation; the approved reply already exists.
			if e := s.Rights.SaveApproved(ctx, tx, j.user, id, j.token, func(pgx.Tx) error { return nil }); e != nil {
				return e
			}
		}
		if e := s.endTx(ctx, tx, j, membership.Completed); e != nil {
			return e
		}
		if _, e := tx.Exec(ctx, `update practice_work set delivery_pending=true,completed_at=now() where activity_id=$1`, id); e != nil {
			return e
		}
		r, e := s.load(ctx, tx, j.user, id)
		result = r.Result
		return e
	})
	if e != nil {
		return nil, s.failed(ctx, j, e)
	}
	_ = s.deliver(ctx, j.user, id)
	return result, nil
}
