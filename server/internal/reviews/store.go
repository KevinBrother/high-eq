package reviews

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

type journal struct {
	Submitted app.ReviewInput `json:"submitted"`
	Phrase    string          `json:"repair_phrase"`
}

func (s *Service) save(ctx context.Context, p accounts.Principal, in app.ReviewInput, w work, phrase string, full scoring.Full, call uuid.UUID) (v app.Review, err error) {
	b, e := json.Marshal(full)
	if e != nil {
		return v, e
	}
	if e = json.Unmarshal(b, &v.Score); e != nil {
		return v, e
	}
	v.Id = w.id
	v.Score.ScoreId = w.source
	v.Submitted = in
	v.RepairPhrase = phrase
	detail, e := s.Fields.Seal(b, aad(p.User, w.source, "score"))
	if e != nil {
		return v, e
	}
	// The source keys live only in nullable FK columns. Deleting an expired
	// mark/event severs the link without destroying the user-authored journal.
	journalInput := in
	journalInput.MarkId, journalInput.SignalEventId = nil, nil
	b, e = json.Marshal(journal{journalInput, phrase})
	if e != nil {
		return v, e
	}
	content, e := s.Fields.Seal(b, aad(p.User, w.id, "journal"))
	if e != nil {
		return v, e
	}
	key := privacy.ScoreKey{UserID: p.User, ActivityID: w.id, SourceID: w.source, Kind: "review"}
	err = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if e := s.allow(ctx, tx, p.User, in); e != nil {
			return e
		}
		return s.approveReview(ctx, tx, p.User, w.id, w.attempt.Token, func(tx pgx.Tx) error {
			if _, e := tx.Exec(ctx, `update activities set state='complete',content_enc=$2 where id=$1`, w.id, content); e != nil {
				return e
			}
			if e := tx.QueryRow(ctx, `insert into scores(id,activity_id,activity_kind,detail_enc) values($1,$2,'review',$3) returning occurred_at`, w.source, w.id, detail).Scan(&key.OccurredAt); e != nil {
				return e
			}
			if e := gateway.LinkScoreTx(ctx, tx, p.User, call, w.id, w.source); e != nil {
				return e
			}
			_, e := tx.Exec(ctx, `update review_requests set repair_enc=null,generated_enc=null,generated_task=null,generated_call_id=null,generated_at=null,generated_expired=false,score_pending=true where activity_id=$1`, w.id)
			return e
		})
	})
	if err == nil && s.Bus.ScoreCompleted.HasSubscribers() {
		_ = s.deliver(ctx, key)
	}
	return
}

// approveReview makes the checkpoint-expiry decision and the successful result
// share the review request row lock. Whichever transaction gets the lock first
// wins atomically: settlement saves an approved result, or expiry permanently
// fences this worker and rolls back every write made by persist.
func (s *Service) approveReview(ctx context.Context, tx pgx.Tx, user, activity, token uuid.UUID, persist func(pgx.Tx) error) error {
	return s.Rights.SaveApproved(ctx, tx, user, activity, token, func(tx pgx.Tx) error {
		var expired bool
		err := tx.QueryRow(ctx, `select generated_expired from review_requests
where activity_id=$1 and user_id=$2 for update`, activity, user).Scan(&expired)
		if errors.Is(err, pgx.ErrNoRows) {
			return membership.ErrConflict
		}
		if err != nil {
			return err
		}
		if expired {
			return membership.ErrConflict
		}
		return persist(tx)
	})
}

const completeRows = `select a.id,a.source_id,a.created_at,r.mark_id,r.signal_event_id,a.content_enc,s.detail_enc from activities a join review_requests r on a.id=r.activity_id join scores s on s.id=a.source_id where a.state='complete' and a.user_id=$1 `

type stored struct {
	id, source   uuid.UUID
	at           time.Time
	mark, signal *uuid.UUID
	enc, detail  []byte
}

func (r *stored) scan(row pgx.Row) error {
	return row.Scan(&r.id, &r.source, &r.at, &r.mark, &r.signal, &r.enc, &r.detail)
}
func (s *Service) decode(u uuid.UUID, r stored) (app.Review, error) {
	v := app.Review{Id: r.id}
	b, e := s.Fields.Open(r.enc, aad(u, r.id, "journal"))
	if e != nil {
		return v, e
	}
	var j journal
	if e = json.Unmarshal(b, &j); e != nil {
		return v, e
	}
	v.Submitted = j.Submitted
	v.Submitted.MarkId, v.Submitted.SignalEventId = r.mark, r.signal
	v.RepairPhrase = j.Phrase
	b, e = s.Fields.Open(r.detail, aad(u, r.source, "score"))
	if e != nil {
		return v, e
	}
	if e = json.Unmarshal(b, &v.Score); e != nil {
		return v, e
	}
	v.Score.ScoreId = r.source
	return v, nil
}
func (s *Service) Get(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (app.Review, error) {
	var r stored
	if e := r.scan(tx.QueryRow(ctx, completeRows+`and a.id=$2`, u, id)); e != nil {
		return app.Review{}, e
	}
	return s.decode(u, r)
}
func (r stored) cursor() string {
	b := binary.BigEndian.AppendUint64(nil, uint64(r.at.UnixMicro()))
	return base64.RawURLEncoding.EncodeToString(append(b, r.id[:]...))
}
func (s *Service) List(ctx context.Context, tx pgx.Tx, u uuid.UUID, p app.ListReviewsParams) (out app.ListReviewsResult, err error) {
	out.Items = []app.Review{}
	limit := 20
	if p.Limit != nil {
		limit = *p.Limit
	}
	if limit < 1 || limit > 100 {
		return out, accounts.ErrInvalid
	}
	var sc []byte
	if p.Scene != nil {
		if !validScene(string(*p.Scene)) {
			return out, accounts.ErrInvalid
		}
		sc = s.mac(u, "scene", *p.Scene)
	}
	var at *time.Time
	var id uuid.UUID
	if p.Cursor != nil {
		b, e := base64.RawURLEncoding.DecodeString(*p.Cursor)
		if e != nil || len(b) != 24 {
			return out, accounts.ErrInvalid
		}
		t := time.UnixMicro(int64(binary.BigEndian.Uint64(b[:8]))).UTC()
		copy(id[:], b[8:])
		if t.Year() < 1 || t.Year() > 9999 || id == uuid.Nil {
			return out, accounts.ErrInvalid
		}
		at = &t
	}
	rows, e := tx.Query(ctx, completeRows+`and ($2::bytea is null or r.scene_mac=$2) and ($3::uuid is null or a.contact_id=$3) and ($4::timestamptz is null or (a.created_at,a.id)<($4,$5)) order by a.created_at desc,a.id desc limit $6`, u, sc, p.ContactId, at, id, limit+1)
	if e != nil {
		return out, e
	}
	defer rows.Close()
	var prev stored
	for rows.Next() {
		if len(out.Items) == limit {
			cursor := prev.cursor()
			out.NextCursor = &cursor
			break
		}
		if e = prev.scan(rows); e != nil {
			return out, e
		}
		v, e := s.decode(u, prev)
		if e != nil {
			return out, e
		}
		out.Items = append(out.Items, v)
	}
	return out, rows.Err()
}
