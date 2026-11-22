package marks

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

func Hooks(f *fieldcrypt.Cipher) privacy.Module {
	return privacy.Module{Name: "manual_marks", Export: func(ctx context.Context, tx pgx.Tx, r privacy.ExportRequest, emit privacy.Emit) error {
		return (Service{Fields: f}).walk(ctx, tx, r.UserID, time.Now().Add(-retention), nil, nil, func(_ time.Time, m app.Mark) error { return emit(m) })
	}, Delete: func(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
		// Coordinator erased the root before hooks; FK cascades remove aliases even
		// for contact and account deletion. Check the postcondition in that transaction.
		var q string
		args := []any{d.UserID, d.SourceID}
		switch d.Scope {
		case "account":
			args = args[:1]
			q = `select exists(select from mark_requests where user_id=$1 union all select from manual_marks where user_id=$1)`
		case "manual_marks":
			q = `select exists(select from mark_requests where user_id=$1 and mark_id=$2 union all select from manual_marks where user_id=$1 and id=$2)`
		case "contacts":
			q = `select exists(select from manual_marks where user_id=$1 and contact_id=$2)`
		default:
			return nil
		}
		var remains bool
		e := tx.QueryRow(ctx, q, args...).Scan(&remains)
		if e == nil && remains {
			return errors.New("mark erasure incomplete")
		}
		return e
	}}
}

func (s Service) PurgeDue(ctx context.Context, now time.Time) error {
	if e := s.resumePending(ctx); e != nil {
		return e
	}
	for {
		rows, e := s.DB.Query(ctx, `select user_id,id from manual_marks where accepted_at<=$1 order by accepted_at limit 128`, now.Add(-retention))
		if e != nil {
			return e
		}
		batch, e := pgx.CollectRows(rows, func(r pgx.CollectableRow) (v privacy.Deletion, e error) {
			v.Scope = "manual_marks"
			v.OperationID = uuid.New()
			e = r.Scan(&v.UserID, &v.SourceID)
			return
		})
		if e != nil || len(batch) == 0 {
			return e
		}
		for _, d := range batch {
			if e = s.Data.Delete(ctx, d); e != nil {
				return e
			}
		}
	}
}

// resumePending completes deletion intents left behind by an interrupted
// finish. It deliberately resumes only T32A manual-mark roots.
func (s Service) resumePending(ctx context.Context) error {
	for {
		rows, e := s.DB.Query(ctx, `select e.user_id,e.root_id from erasure_roots e join pending_erasure p using(root_id) where e.scope='manual_marks' order by e.root_id limit 128`)
		if e != nil {
			return e
		}
		batch, e := pgx.CollectRows(rows, func(r pgx.CollectableRow) (privacy.Deletion, error) {
			d := privacy.Deletion{Scope: "manual_marks", OperationID: uuid.New()}
			e := r.Scan(&d.UserID, &d.SourceID)
			return d, e
		})
		if e != nil || len(batch) == 0 {
			return e
		}
		for _, d := range batch {
			if e = s.Data.Delete(ctx, d); e != nil {
				return e
			}
		}
	}
}
