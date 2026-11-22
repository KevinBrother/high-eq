package reviews

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
)

// generatedCheckpointTTL bounds how long an unmoderated model output can be
// retained for retry. Expired bytes are discarded before any new dispatch.
const generatedCheckpointTTL = 15 * time.Minute

const expiredCheckpointBatch = 256

// purgeExpiredGenerated physically removes unmoderated model output once its
// replay window has elapsed, even if the user never retries the request. It
// closes the request key and any held worker in the same transaction so a
// worker cannot settle bytes after the user was told recovery had expired.
func (s *Service) purgeExpiredGenerated(ctx context.Context) error {
	type candidate struct {
		activity uuid.UUID
		user     uuid.UUID
	}
	for {
		rows, err := s.DB.Query(ctx, `select activity_id,user_id from review_requests
where generated_enc is not null and generated_at<=now()-make_interval(secs=>$1)
order by user_id,activity_id limit $2`, int(generatedCheckpointTTL.Seconds()), expiredCheckpointBatch)
		if err != nil {
			return err
		}
		candidates, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (candidate, error) {
			var c candidate
			err := row.Scan(&c.activity, &c.user)
			return c, err
		})
		if err != nil {
			return err
		}
		if len(candidates) == 0 {
			return nil
		}
		err = pgx.BeginFunc(ctx, s.DB, func(tx pgx.Tx) error {
			// WithSession and SaveApproved also lock the user before the request.
			// Keep the same order to serialize expiry with settlement and deletion.
			var last uuid.UUID
			for _, c := range candidates {
				if c.user == last {
					continue
				}
				last = c.user
				var locked uuid.UUID
				err := tx.QueryRow(ctx, `select id from users where id=$1 for update`, c.user).Scan(&locked)
				if errors.Is(err, pgx.ErrNoRows) {
					continue
				}
				if err != nil {
					return err
				}
			}
			for _, c := range candidates {
				if _, err := s.expireGeneratedCheckpoint(ctx, tx, c.activity, c.user); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
		if len(candidates) < expiredCheckpointBatch {
			return nil
		}
	}
}

// expireGeneratedCheckpoint permanently closes a request whose unmoderated
// output has outlived its replay window. The caller must hold the user row lock;
// this function locks the request row before touching its activity or quota
// attempt, matching the settlement and deletion lock order.
func (s *Service) expireGeneratedCheckpoint(ctx context.Context, tx pgx.Tx, activity, user uuid.UUID) (bool, error) {
	var expired bool
	err := tx.QueryRow(ctx, `select generated_expired or (generated_enc is not null and generated_at<=now()-make_interval(secs=>$3))
from review_requests where activity_id=$1 and user_id=$2 for update`, activity, user, int(generatedCheckpointTTL.Seconds())).Scan(&expired)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if !expired {
		return false, nil
	}
	if _, err = tx.Exec(ctx, `update review_requests
set repair_enc=null,generated_enc=null,generated_task=null,generated_call_id=null,generated_at=null,generated_expired=true
where activity_id=$1 and user_id=$2`, activity, user); err != nil {
		return false, err
	}
	if _, err = tx.Exec(ctx, `update quota_attempts set state='failed' where activity_id=$1 and state='held'`, activity); err != nil {
		return false, err
	}
	if _, err = tx.Exec(ctx, `update activities set state='failed'
where id=$1 and user_id=$2 and state in ('pending','active','moderation_unavailable')`, activity, user); err != nil {
		return false, err
	}
	return true, nil
}

func (s *Service) loadGenerated(ctx context.Context, tx pgx.Tx, user, activity uuid.UUID, task gateway.Task, raw []byte, call uuid.UUID, fresh bool) (*gateway.Generated, error) {
	if raw == nil || call == uuid.Nil {
		return nil, nil
	}
	if !fresh || (task != gateway.ReviewAnalysis && task != gateway.Scoring) {
		_, err := tx.Exec(ctx, `update review_requests set generated_enc=null,generated_task=null,generated_call_id=null,generated_at=null,generated_expired=true where activity_id=$1 and user_id=$2`, activity, user)
		return nil, err
	}
	plain, err := s.Fields.Open(raw, aad(user, activity, "generated:"+string(task)))
	if err != nil {
		return nil, err
	}
	return &gateway.Generated{Task: task, Raw: string(plain), CallID: call}, nil
}

// saveGenerated fences the checkpoint to the worker that still owns the held
// quota token. A stale worker cannot overwrite a newer worker's checkpoint.
func (s *Service) saveGenerated(ctx context.Context, p accounts.Principal, activity, token uuid.UUID, in app.ReviewInput, task gateway.Task, call uuid.UUID, raw string) error {
	if call == uuid.Nil || raw == "" || (task != gateway.ReviewAnalysis && task != gateway.Scoring) {
		return gateway.ErrRequest
	}
	sealed, err := s.Fields.Seal([]byte(raw), aad(p.User, activity, "generated:"+string(task)))
	if err != nil {
		return err
	}
	return s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if err := s.allow(ctx, tx, p.User, in); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `update review_requests r
set generated_enc=$3,generated_task=$4,generated_call_id=$5,generated_at=now(),generated_expired=false
from quota_attempts q
where r.activity_id=$1 and r.user_id=$2 and q.activity_id=r.activity_id
  and r.generated_expired=false and q.token=$6 and q.state='held'`, activity, p.User, sealed, string(task), call, token)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return membership.ErrConflict
		}
		return nil
	})
}

// persistTerminal is the activity-state half of terminal settlement. It is
// deliberately fenced by the worker token and remains idempotent for a replay
// from the same worker. It never overwrites a newer active worker.
func (s *Service) persistTerminal(ctx context.Context, p accounts.Principal, activity, token uuid.UUID, out membership.Outcome) error {
	c, done := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer done()
	return s.Data.Access(c, p.User, func(tx pgx.Tx) error {
		var expired bool
		err := tx.QueryRow(c, `select generated_expired from review_requests
where activity_id=$1 and user_id=$2 for update`, activity, p.User).Scan(&expired)
		if errors.Is(err, pgx.ErrNoRows) {
			return membership.ErrConflict
		}
		if err != nil {
			return err
		}
		if expired {
			return membership.ErrConflict
		}
		tag, err := tx.Exec(c, `update activities a set state=$4
from quota_attempts q
where a.id=$1 and a.user_id=$2 and q.activity_id=a.id
  and q.token=$3 and q.state='held' and a.state='active'`, activity, p.User, token, string(out))
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			var current string
			var currentToken uuid.UUID
			if err = tx.QueryRow(c, `select a.state,coalesce(q.token,$3)
from activities a left join quota_attempts q on q.activity_id=a.id
where a.id=$1 and a.user_id=$2`, activity, p.User, token).Scan(&current, &currentToken); err != nil {
				return err
			}
			if current != string(out) || currentToken != token {
				return membership.ErrConflict
			}
		}
		if out != membership.ModerationUnavailable {
			_, err = tx.Exec(c, `update review_requests set repair_enc=null,generated_enc=null,generated_task=null,generated_call_id=null,generated_at=null
where activity_id=$1 and user_id=$2 and generated_expired=false`, activity, p.User)
		}
		return err
	})
}
