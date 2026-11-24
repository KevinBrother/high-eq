package accounts

import (
	"context"
	"errors"
	"time"
	_ "time/tzdata" // scratch image has no zoneinfo files

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/privacy"
)

func account(ctx context.Context, tx pgx.Tx, id uuid.UUID) (app.Account, error) {
	a := app.Account{UserId: id, Bindings: []app.AccountBindings{}}
	e := tx.QueryRow(ctx, `select timezone,closure_requested_at+interval '360 hours' from users where id=$1`, id).Scan(&a.Timezone, &a.FrozenUntil)
	if e != nil {
		return a, e
	}
	rows, e := tx.Query(ctx, "select provider from login_identities where user_id=$1 order by provider", id)
	if e != nil {
		return a, e
	}
	defer rows.Close()
	for rows.Next() {
		var v app.AccountBindings
		if e = rows.Scan(&v); e != nil {
			return a, e
		}
		a.Bindings = append(a.Bindings, v)
	}
	return a, rows.Err()
}
func (s *Service) Me(ctx context.Context, p Principal, timezone *string) (app.Account, error) {
	var a app.Account
	if timezone != nil {
		if !validText(*timezone, 128) || *timezone == "Local" {
			return a, ErrInvalid
		}
		if _, e := time.LoadLocation(*timezone); e != nil {
			return a, ErrInvalid
		}
	}
	e := s.WithSession(ctx, p, timezone == nil, func(tx pgx.Tx) error {
		if timezone != nil {
			if _, e := tx.Exec(ctx, "update users set timezone=$1 where id=$2", *timezone, p.User); e != nil {
				return e
			}
		}
		var e error
		a, e = account(ctx, tx, p.User)
		return e
	})
	return a, e
}
func (s *Service) Freeze(ctx context.Context, p Principal, c app.Credential) (app.FreezeAccountResult, error) {
	var out app.FreezeAccountResult
	i, e := s.verify(ctx, c)
	if e != nil {
		return out, e
	}
	e = s.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if e := s.reauth(ctx, tx, p.User, i); e != nil {
			return e
		}
		if _, e := tx.Exec(ctx, "delete from auth_sessions where user_id=$1", p.User); e != nil {
			return e
		}
		return tx.QueryRow(ctx, `update users set closure_requested_at=clock_timestamp() where id=$1 returning closure_requested_at+interval '360 hours'`, p.User).Scan(&out.FrozenUntil)
	})
	return out, e
}
func (s *Service) CancelClosure(ctx context.Context, p Principal) error {
	return s.WithSession(ctx, p, true, func(tx pgx.Tx) error {
		tag, e := tx.Exec(ctx, `update users set closure_requested_at=null where id=$1 and (closure_requested_at is null or closure_requested_at>clock_timestamp()-interval '360 hours')`, p.User)
		if e != nil {
			return e
		}
		if tag.RowsAffected() == 0 {
			return ErrAuth
		}
		return nil
	})
}

// Only discover expired IDs here. The coordinator journals, locks and invokes
// every registered hook. Cancellation is impossible once the deadline is reached.
func (s *Service) PurgeDue(ctx context.Context) error {
	if _, e := s.db.Exec(ctx, `delete from sms_challenges where sent_at<clock_timestamp()-interval '24 hours'`); e != nil {
		return e
	}
	if _, e := s.db.Exec(ctx, `delete from auth_sessions where expires_at<=clock_timestamp()`); e != nil {
		return e
	}
	// Take one database-clock cutoff so accounts that become due during the
	// scan are left for the next pass.
	var cutoff time.Time
	if e := s.db.QueryRow(ctx, `select clock_timestamp()-interval '360 hours'`).Scan(&cutoff); e != nil {
		return e
	}

	const batchSize = 100
	type candidate struct {
		requestedAt pgtype.Timestamptz
		id          uuid.UUID
	}
	var after candidate
	var firstDeleteErr error
	for {
		rows, e := s.db.Query(ctx, `
			select closure_requested_at,id from users
			where closure_requested_at<=$1
				and ($2::timestamptz is null or (closure_requested_at,id)>($2,$3::uuid))
			order by closure_requested_at,id limit $4`, cutoff, after.requestedAt, after.id, batchSize)
		if e != nil {
			return errors.Join(firstDeleteErr, e)
		}
		page, e := pgx.CollectRows(rows, func(row pgx.CollectableRow) (candidate, error) {
			var item candidate
			err := row.Scan(&item.requestedAt, &item.id)
			return item, err
		})
		if e != nil {
			return errors.Join(firstDeleteErr, e)
		}
		for _, item := range page {
			if e := ctx.Err(); e != nil {
				return errors.Join(firstDeleteErr, e)
			}
			if e := s.guard.DeleteIf(ctx, privacy.Deletion{Scope: "account", UserID: item.id, OperationID: uuid.New()}, func(tx pgx.Tx) (uuid.UUID, bool, error) {
				var due bool
				e := tx.QueryRow(ctx, `select coalesce(closure_requested_at<=clock_timestamp()-interval '360 hours',false) from users where id=$1`, item.id).Scan(&due)
				return uuid.Nil, due, e
			}); e != nil && firstDeleteErr == nil {
				firstDeleteErr = e
			}
		}
		if len(page) < batchSize {
			return errors.Join(firstDeleteErr, ctx.Err())
		}
		// Advance even if a candidate is still present after an unsuccessful deletion.
		after = page[len(page)-1]
	}
}
