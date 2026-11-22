package replies

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
	"time"
)

func Hooks(c *fieldcrypt.Cipher) privacy.Module {
	return privacy.Module{Name: "replies", Delete: verifyErased, Export: func(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
		rows, e := tx.Query(ctx, `select a.id,r.request_id,a.contact_id,a.created_at,a.state,a.content_enc from activities a join reply_requests r on r.activity_id=a.id where a.user_id=$1 order by a.created_at,a.id`, q.UserID)
		if e != nil {
			return e
		}
		defer rows.Close()
		for rows.Next() {
			var id, request uuid.UUID
			var contact *uuid.UUID
			var at time.Time
			var state string
			var enc []byte
			if e = rows.Scan(&id, &request, &contact, &at, &state, &enc); e != nil {
				return e
			}
			row := map[string]any{"id": id, "request_id": request, "contact_id": contact, "created_at": at, "state": state}
			if len(enc) > 0 {
				b, e := c.Open(enc, aad(q.UserID, id, "result"))
				if e != nil {
					return e
				}
				row["result"] = json.RawMessage(b)
			}
			if e = emit(row); e != nil {
				return e
			}
		}
		if e = rows.Err(); e != nil {
			return e
		}
		rows, e = tx.Query(ctx, `select f.id,a.id,f.occurred_at,f.outcome_enc from reply_feedback f join activities a on a.id=f.activity_id where a.user_id=$1 order by f.occurred_at,f.id`, q.UserID)
		if e != nil {
			return e
		}
		defer rows.Close()
		for rows.Next() {
			var fid, id uuid.UUID
			var at time.Time
			var enc []byte
			if e = rows.Scan(&fid, &id, &at, &enc); e != nil {
				return e
			}
			b, e := c.Open(enc, aad(q.UserID, fid, "outcome"))
			if e != nil {
				return e
			}
			if e = emit(map[string]any{"feedback_id": fid, "reply_id": id, "feedback": json.RawMessage(b), "occurred_at": at}); e != nil {
				return e
			}
		}
		return rows.Err()
	}}
}

// Coordinator deletes the root first; both reply tables and associated AI logs
// have cascading FKs. The aggregate daily usage intentionally survives source erasure.
func verifyErased(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
	if d.Scope != "replies" && d.Scope != "contacts" && d.Scope != "account" {
		return nil
	}
	var remains bool
	e := tx.QueryRow(ctx, `select exists(select from activities where user_id=$1 and kind='reply' and ($2='account' or ($2='contacts' and contact_id=$3) or ($2='replies' and source_id=$3)))`, d.UserID, d.Scope, d.SourceID).Scan(&remains)
	if e == nil && remains {
		return errors.New("reply root remains")
	}
	return e
}

// DeletionKey resolves the public Reply.id for T35, in its authenticated
// account transaction. The caller passes only this internal key to Data.Delete.
func DeletionKey(ctx context.Context, tx pgx.Tx, user, replyID uuid.UUID) (uuid.UUID, error) {
	var key uuid.UUID
	e := tx.QueryRow(ctx, `select source_id from activities where user_id=$1 and id=$2 and kind='reply'`, user, replyID).Scan(&key)
	if errors.Is(e, pgx.ErrNoRows) {
		return uuid.Nil, ErrMissing
	}
	return key, e
}
