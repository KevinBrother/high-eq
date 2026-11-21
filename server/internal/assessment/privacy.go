package assessment

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

func Hooks(f *fieldcrypt.Cipher) privacy.Module {
	return privacy.Module{Name: "assessments", Delete: verifyDeleted, Export: func(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
		rows, e := tx.Query(ctx, `select id,instrument_version,completed_at,answers_enc,scores_enc from assessments where user_id=$1 order by completed_at,id`, q.UserID)
		if e != nil {
			return e
		}
		defer rows.Close()
		for rows.Next() {
			var r record
			var a, v []byte
			var answers []int
			var scores Scores
			if e = rows.Scan(&r.ID, &r.Version, &r.At, &a, &v); e != nil {
				return e
			}
			if e = r.open(f, q.UserID, "answers_enc", a, &answers); e != nil {
				return e
			}
			if e = r.open(f, q.UserID, "scores_enc", v, &scores); e != nil {
				return e
			}
			if e = emit(struct {
				Result
				Version string `json:"version"`
				Answers []int  `json:"answers"`
			}{r.result(scores), r.Version, answers}); e != nil {
				return e
			}
		}
		return rows.Err()
	}}
}

// The coordinator already removes the source (or cascades the whole account).
// The delivery marker lives on the source, so no orphan outbox copy can survive.
func verifyDeleted(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
	if d.Scope != "account" && d.Scope != "assessments" {
		return nil
	}
	var remains bool
	e := tx.QueryRow(ctx, `select exists(select from assessments where user_id=$1 and ($2 or id=$3))`, d.UserID, d.Scope == "account", d.SourceID).Scan(&remains)
	if e != nil {
		return e
	}
	if remains {
		return errors.New("assessment source remains")
	}
	return nil
}
