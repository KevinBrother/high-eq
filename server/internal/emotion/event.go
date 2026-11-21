package emotion

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
)

type record struct {
	app.SignalEvent
	Triggers    []string   `json:"triggers"`
	FeedbackID  uuid.UUID  `json:"feedback_id,omitzero"`
	ConfirmedAt *time.Time `json:"confirmed_at,omitempty"`
}

func (s Service) event(ctx context.Context, tx pgx.Tx, u, id uuid.UUID, now time.Time) (record, error) {
	var r record
	var b []byte
	e := tx.QueryRow(ctx, `select event_enc from signal_events where user_id=$1 and id=$2 and occurred_at>$3`, u, id, now.Add(-retention)).Scan(&b)
	if e == nil {
		e = s.open(u, id, "event", b, &r)
	}
	return r, e
}
func (s Service) walkEvents(ctx context.Context, tx pgx.Tx, u uuid.UUID, from, to time.Time, visit func(record) error) error {
	rows, e := tx.Query(ctx, `select id,event_enc from signal_events where user_id=$1 and occurred_at>$2 and occurred_at<=$3 order by occurred_at,id`, u, from, to)
	if e != nil {
		return e
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		var b []byte
		var r record
		if e = rows.Scan(&id, &b); e != nil {
			return e
		}
		if e = s.open(u, id, "event", b, &r); e != nil {
			return e
		}
		if e = visit(r); e != nil {
			return e
		}
	}
	return rows.Err()
}
func (s Service) Report(ctx context.Context, tx pgx.Tx, u uuid.UUID, in app.ReportSignalEventJSONBody, now time.Time, watch bool) error {
	at := in.StartsAt.UTC()
	kind := string(in.Kind)
	if in.Id == uuid.Nil || !aligned(at) || at.After(now) || !at.After(now.Add(-retention)) || (kind != Self && kind != Rhythm) {
		return Invalid
	}
	if e := consent(ctx, tx, u, "voice", at); e != nil {
		return e
	}
	if kind == Self {
		if !watch {
			return Forbidden
		}
		if e := consent(ctx, tx, u, "health", at); e != nil {
			return e
		}
	}
	old, e := s.event(ctx, tx, u, in.Id, now)
	if e == nil {
		if old.StartsAt.Equal(at) && string(old.Kind) == kind {
			return nil
		}
		return Conflict
	}
	if !errors.Is(e, pgx.ErrNoRows) {
		return e
	}
	var cooling bool
	e = tx.QueryRow(ctx, `select exists(select from signal_events where user_id=$1 and occurred_at>$2 and occurred_at<$3)`, u, at.Add(-10*time.Minute), at.Add(10*time.Minute)).Scan(&cooling)
	if e != nil {
		return e
	}
	if cooling {
		return Conflict
	}
	_, frame, e := s.baseline(ctx, tx, u, now, at, true)
	if e != nil {
		return e
	}
	if watch && kind == Rhythm {
		e := consent(ctx, tx, u, "health", at)
		if errors.Is(e, Forbidden) {
			watch = false
		} else if e != nil {
			return e
		}
	}
	frame.WatchReleased = watch
	d := Decide(frame)
	if d.Kind != kind {
		return Invalid
	}
	r := record{SignalEvent: app.SignalEvent{Id: in.Id, StartsAt: at, Kind: app.SignalEventKind(kind), Confirmation: "pending"}, Triggers: d.Signals}
	enc, e := s.seal(u, in.Id, "event", r)
	if e != nil {
		return e
	}
	tag, e := tx.Exec(ctx, `insert into signal_events(id,user_id,occurred_at,event_enc) values($1,$2,$3,$4) on conflict(id) do nothing`, in.Id, u, at, enc)
	if e != nil {
		return e
	}
	if tag.RowsAffected() != 1 {
		return Conflict
	}
	return s.Data.GuardTx(ctx, tx, u) // also check the newly introduced client UUID against the independent ledger
}

// RawMessage distinguishes an omitted field from an explicit JSON null (clear).
type Annotation struct {
	Confirmation json.RawMessage `json:"confirmation"`
	Scene        json.RawMessage `json:"scene"`
	Contact      json.RawMessage `json:"contact_id"`
}
type ContactCheck func(context.Context, pgx.Tx, uuid.UUID, *uuid.UUID) error

func (s Service) Annotate(ctx context.Context, tx pgx.Tx, u, id uuid.UUID, in Annotation, now time.Time, check ContactCheck) (app.SignalEvent, error) {
	r, e := s.event(ctx, tx, u, id, now)
	if e != nil {
		return r.SignalEvent, e
	}
	if in.Scene == nil && in.Contact == nil && in.Confirmation == nil {
		return r.SignalEvent, Invalid
	}
	if in.Scene != nil {
		if json.Unmarshal(in.Scene, &r.Scene) != nil || (r.Scene != nil && !slices.Contains([]string{"work", "partner", "family", "friends", "social"}, *r.Scene)) {
			return r.SignalEvent, Invalid
		}
	}
	if in.Contact != nil {
		if json.Unmarshal(in.Contact, &r.ContactId) != nil {
			return r.SignalEvent, Invalid
		}
	}
	if r.ContactId != nil {
		if e = check(ctx, tx, u, r.ContactId); e != nil {
			return r.SignalEvent, e
		}
	}
	pending := false
	if in.Confirmation != nil {
		var v app.SignalEventConfirmation
		if json.Unmarshal(in.Confirmation, &v) != nil || r.Kind != Self || (v != "yes" && v != "no") {
			return r.SignalEvent, Invalid
		}
		if r.Confirmation != "pending" && r.Confirmation != v {
			return r.SignalEvent, Conflict
		}
		if r.Confirmation == "pending" {
			r.Confirmation = v
			r.ConfirmedAt = &now
			r.FeedbackID = uuid.New()
			pending = true
		}
	}
	enc, e := s.seal(u, id, "event", r)
	if e == nil {
		_, e = tx.Exec(ctx, `update signal_events set event_enc=$3,contact_id=$4,feedback_pending=feedback_pending or $5 where user_id=$1 and id=$2`, u, id, enc, r.ContactId, pending)
	}
	return r.SignalEvent, e
}

// Confirmed is T25's transaction-scoped source reader; the bus carries no voice features.
func (s Service) Confirmed(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (app.SignalEvent, error) {
	r, e := s.event(ctx, tx, u, id, time.Now())
	if e == nil && (r.Kind != Self || r.ConfirmedAt == nil) {
		e = Invalid
	}
	return r.SignalEvent, e
}

type Page struct {
	Items []app.SignalEvent `json:"items"`
	Next  *string           `json:"next_cursor"`
}
type cursor struct {
	At time.Time
	ID uuid.UUID
}

func (s Service) List(ctx context.Context, tx pgx.Tx, u uuid.UUID, p app.ListSignalEventsParams, now time.Time) (Page, error) {
	out := Page{Items: []app.SignalEvent{}}
	limit := 20
	if p.Limit != nil {
		limit = *p.Limit
	}
	var after cursor
	if limit < 1 || limit > 100 {
		return out, Invalid
	}
	if p.Cursor != nil {
		if len(*p.Cursor) > 200 {
			return out, Invalid
		}
		b, e := base64.RawURLEncoding.DecodeString(*p.Cursor)
		if e != nil || json.Unmarshal(b, &after) != nil || after.ID == uuid.Nil || !aligned(after.At) {
			return out, Invalid
		}
	}
	rows, e := tx.Query(ctx, `select id,event_enc from signal_events where user_id=$1 and occurred_at>$2 and ($3 or (occurred_at,id)<($4,$5)) order by occurred_at desc,id desc limit $6`, u, now.Add(-retention), p.Cursor == nil, after.At, after.ID, limit+1)
	if e != nil {
		return out, e
	}
	defer rows.Close()
	for rows.Next() {
		if len(out.Items) == limit {
			last := out.Items[limit-1]
			b, _ := json.Marshal(cursor{last.StartsAt, last.Id})
			v := base64.RawURLEncoding.EncodeToString(b)
			out.Next = &v
			break
		}
		var id uuid.UUID
		var b []byte
		var r record
		if e = rows.Scan(&id, &b); e != nil {
			return out, e
		}
		if e = s.open(u, id, "event", b, &r); e != nil {
			return out, e
		}
		out.Items = append(out.Items, r.SignalEvent)
	}
	return out, rows.Err()
}
