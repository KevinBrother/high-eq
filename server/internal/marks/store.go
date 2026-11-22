// Package marks stores voluntary timestamps, never sensor data or AI activities.
package marks

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

const retention = 180 * 24 * time.Hour

var (
	ErrConsent = errors.New("manual mark consent required")
	ErrDeleted = errors.New("manual mark request was deleted")
)

type Service struct {
	Fields *fieldcrypt.Cipher
	DB     *pgxpool.Pool
	Data   *privacy.Coordinator
}

func consent(ctx context.Context, tx pgx.Tx, u uuid.UUID) error {
	ok, e := accounts.Granted(ctx, tx, u, "manual_mark")
	if !ok && e == nil {
		return ErrConsent
	}
	return e
}

func aad(u, id uuid.UUID) []byte { return []byte("mark/" + u.String() + "/" + id.String()) }
func (s Service) seal(u uuid.UUID, m app.Mark) ([]byte, error) {
	b, e := json.Marshal(m)
	if e != nil {
		return nil, e
	}
	return s.Fields.Seal(b, aad(u, m.Id))
}

func (s Service) decode(u, id uuid.UUID, contact *uuid.UUID, b []byte) (m app.Mark, e error) {
	b, e = s.Fields.Open(b, aad(u, id))
	if e == nil {
		e = json.Unmarshal(b, &m)
		// Ownership and references come from the authenticated row, not JSON.
		m.Id, m.ContactId = id, contact
	}
	return
}

func validScene(v *string) bool {
	if v == nil {
		return true
	}
	switch *v {
	case "work", "partner", "family", "friends", "social":
		return true
	}
	return false
}

func checkContact(ctx context.Context, tx pgx.Tx, u uuid.UUID, id *uuid.UUID) error {
	if id == nil {
		return nil
	}
	var ok bool
	e := tx.QueryRow(ctx, `select exists(select from contacts where user_id=$1 and id=$2)`, u, *id).Scan(&ok)
	if e == nil && !ok {
		return accounts.ErrInvalid
	}
	return e
}

// Caller owns T05 WithSession's user lock. Sample now only after acquiring it.
func (s Service) Create(ctx context.Context, tx pgx.Tx, u uuid.UUID, in app.CreateMarkInput, now time.Time) (m app.Mark, e error) {
	if in.RequestId == uuid.Nil || !validScene(in.Scene) {
		return m, accounts.ErrInvalid
	}
	if e = consent(ctx, tx, u); e != nil {
		return
	}
	var deleted bool
	if e = tx.QueryRow(ctx, `select exists(select from manual_mark_tombstones where user_id=$1 and request_id=$2)`, u, in.RequestId).Scan(&deleted); e != nil {
		return
	}
	if deleted {
		return m, ErrDeleted
	}
	now = now.UTC().Truncate(time.Microsecond)
	var id uuid.UUID
	var enc []byte
	var contact *uuid.UUID
	var accepted time.Time
	e = tx.QueryRow(ctx, `select m.id,m.contact_id,m.mark_enc,m.accepted_at from mark_requests r join manual_marks m on (r.user_id,r.mark_id)=(m.user_id,m.id) where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&id, &contact, &enc, &accepted)
	if e == nil {
		if accepted.After(now.Add(-retention)) {
			return s.decode(u, id, contact, enc)
		}
		// Keep the expired alias until maintenance removes its mark so the
		// tombstone trigger can preserve replay evidence. It is still a conflict.
		return m, ErrDeleted
	} else if !errors.Is(e, pgx.ErrNoRows) {
		return
	}
	e = tx.QueryRow(ctx, `select id,contact_id,mark_enc from manual_marks where user_id=$1 and accepted_at>$2 order by accepted_at desc limit 1`, u, now.Add(-time.Minute)).Scan(&id, &contact, &enc)
	switch {
	case errors.Is(e, pgx.ErrNoRows):
		if e = checkContact(ctx, tx, u, in.ContactId); e != nil {
			return
		}
		m = app.Mark{Id: uuid.New(), MarkedAt: now, ContactId: in.ContactId, Scene: in.Scene}
		enc, e = s.seal(u, m)
		if e != nil {
			return
		}
		_, e = tx.Exec(ctx, `insert into manual_marks(user_id,id,accepted_at,contact_id,mark_enc) values($1,$2,$3,$4,$5)`, u, m.Id, now, m.ContactId, enc)
	case e == nil:
		m, e = s.decode(u, id, contact, enc)
	}
	if e != nil {
		return
	}
	_, e = tx.Exec(ctx, `insert into mark_requests(user_id,request_id,mark_id) values($1,$2,$3)`, u, in.RequestId, m.Id)
	return
}

// RawMessage preserves omitted vs explicit null without accepting unknown fields.
type Patch struct {
	Contact json.RawMessage `json:"contact_id"`
	Scene   json.RawMessage `json:"scene"`
}

func (p Patch) apply(m *app.Mark) error {
	if p.Contact != nil && json.Unmarshal(p.Contact, &m.ContactId) != nil {
		return accounts.ErrInvalid
	}
	if p.Scene != nil && json.Unmarshal(p.Scene, &m.Scene) != nil {
		return accounts.ErrInvalid
	}
	if !validScene(m.Scene) {
		return accounts.ErrInvalid
	}
	return nil
}

func (s Service) Edit(ctx context.Context, tx pgx.Tx, u, id uuid.UUID, p Patch, now time.Time) (m app.Mark, e error) {
	if e = consent(ctx, tx, u); e != nil {
		return
	}
	var enc []byte
	var contact *uuid.UUID
	e = tx.QueryRow(ctx, `select contact_id,mark_enc from manual_marks where user_id=$1 and id=$2 and accepted_at>$3`, u, id, now.Add(-retention)).Scan(&contact, &enc)
	if e != nil {
		return
	}
	if m, e = s.decode(u, id, contact, enc); e != nil {
		return
	}
	if e = p.apply(&m); e != nil {
		return
	}
	if e = checkContact(ctx, tx, u, m.ContactId); e != nil {
		return
	}
	if enc, e = s.seal(u, m); e != nil {
		return
	}
	_, e = tx.Exec(ctx, `update manual_marks set contact_id=$3,mark_enc=$4 where user_id=$1 and id=$2`, u, id, m.ContactId, enc)
	return
}
