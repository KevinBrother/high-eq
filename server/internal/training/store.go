package training

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

//go:embed role.txt
var seed string

func Seed() string { return seed }

var ErrMissing = errors.New("practice session not found")
var ErrGeneration = errors.New("practice generation failed")
var ErrCap = errors.New("practice limit reached")
var ErrConsent = errors.New("practice consent required")
var errSettlementPending = errors.New("practice settlement pending")

type Service struct {
	Accounts *accounts.Service
	Rights   *membership.Service
	Fields   *fieldcrypt.Cipher
	Data     *privacy.Coordinator
	DB       *pgxpool.Pool
	Bus      *events.Bus
	Router   func(gateway.Stop) (scoring.Runner, error)
	Summary  func(context.Context, pgx.Tx, uuid.UUID, uuid.UUID) (app.Profile, error)
}
type Input struct {
	ID       uuid.UUID  `json:"request_id"`
	Level    *uuid.UUID `json:"level_id,omitempty"`
	Contact  *uuid.UUID `json:"contact_id,omitempty"`
	Scene    *string    `json:"scene,omitempty"`
	Scenario *string    `json:"scenario,omitempty"`
	Previous *uuid.UUID `json:"previous_id,omitempty"`
}

func (in Input) describe() (scene, mode, kind string, target *string, e error) {
	if in.ID == uuid.Nil || in.Contact != nil && *in.Contact == uuid.Nil ||
		in.Previous != nil && *in.Previous == uuid.Nil {
		return "", "", "", nil, accounts.ErrInvalid
	}
	if in.Level != nil {
		if in.Scene != nil || in.Scenario != nil {
			return "", "", "", nil, accounts.ErrInvalid
		}
		for _, l := range catalog {
			if l.Id == *in.Level {
				k := "practice"
				if l.TargetItem != nil {
					k = "drill"
				}
				return string(l.Scene) + "：" + l.scenario, string(l.Mode), k, l.TargetItem, nil
			}
		}
		return "", "", "", nil, ErrMissing
	}
	if in.Scene == nil || !validScene(*in.Scene) || in.Scenario == nil ||
		!utf8.ValidString(*in.Scenario) || strings.ContainsRune(*in.Scenario, 0) ||
		strings.TrimSpace(*in.Scenario) == "" || len(*in.Scenario) > 6000 {
		return "", "", "", nil, accounts.ErrInvalid
	}
	return *in.Scene + "：" + *in.Scenario, "full_session", "practice", nil, nil
}

type Settlement struct {
	Status string  `json:"status"`
	Net    int     `json:"net_charge"`
	Day    *string `json:"charged_day"`
}
type Score struct {
	ID uuid.UUID `json:"score_id"`
	scoring.Full
}
type Result struct {
	Mode       string            `json:"mode"`
	Score      *Score            `json:"score,omitempty"`
	Progress   *scoring.Progress `json:"progress,omitempty"`
	Settlement Settlement        `json:"settlement"`
}

// SessionSummary is the only shape exposed by history lists. Keeping it
// separate from Session makes a setup/contact projection leak a compile error.
type SessionSummary struct {
	ID          uuid.UUID     `json:"session_id"`
	Status      string        `json:"status"`
	Mode        string        `json:"mode"`
	Target      *string       `json:"target_item"`
	Level       *uuid.UUID    `json:"level_id,omitempty"`
	Messages    []app.Message `json:"messages"`
	Settlement  Settlement    `json:"settlement"`
	CompletedAt *time.Time    `json:"completed_at"`
	Result      *Result       `json:"result,omitempty"`
}

type Session struct {
	SessionSummary
	// Setup is populated only by an authorized session detail read. It is
	// deliberately absent from history list items and create responses.
	Setup *Input `json:"setup,omitempty"`
}

func (r record) summary() SessionSummary {
	return r.Session.SessionSummary
}

func (r record) detail() Session {
	setup := r.input
	return Session{SessionSummary: r.summary(), Setup: &setup}
}

// Pin the lesson at creation: later edits to the catalog cannot reinterpret a stored score.
type setupSnapshot struct {
	Input  Input   `json:"input"`
	Scene  string  `json:"role_scene"`
	Mode   string  `json:"mode"`
	Kind   string  `json:"kind"`
	Target *string `json:"target_item"`
}
type record struct {
	Session
	input                 Input
	source                uuid.UUID
	scene, kind           string
	tokens                int
	worker, client, quota *uuid.UUID
	action                string
	live                  bool
	settlementPending     bool
	settlementOutcome     string
}

func aad(u, id uuid.UUID, field string) []byte {
	return []byte("practice/" + field + "/" + u.String() + "/" + id.String())
}
func (s *Service) seal(u, id uuid.UUID, field string, v any) ([]byte, error) {
	b, e := json.Marshal(v)
	if e != nil {
		return nil, e
	}
	return s.Fields.Seal(b, aad(u, id, field))
}
func (s *Service) open(u, id uuid.UUID, field string, b []byte, v any) error {
	b, e := s.Fields.Open(b, aad(u, id, field))
	if e != nil {
		return e
	}
	return json.Unmarshal(b, v)
}
func (s *Service) load(ctx context.Context, tx pgx.Tx, u, id uuid.UUID) (r record, e error) {
	var setup, detail, progress []byte
	var refunded bool
	r.ID = id
	r.Messages = []app.Message{}
	e = tx.QueryRow(ctx, `select a.state,a.source_id,a.content_enc,w.used_tokens,w.worker,w.client_id,
       coalesce(w.action,''),coalesce(w.valid_until>clock_timestamp(),false),q.token,
       l.charged_day::text,l.refunded_at is not null,s.detail_enc,d.progress_enc,
       w.settlement_pending,coalesce(w.settlement_outcome,''),w.completed_at
 from activities a join practice_work w on w.activity_id=a.id
 left join quota_attempts q on q.activity_id=a.id
 left join quota_ledger l on l.activity_id=a.id
 left join scores s on s.activity_id=a.id
 left join drill_progress d on d.activity_id=a.id
 where a.user_id=$1 and a.id=$2`, u, id).Scan(&r.Status, &r.source, &setup, &r.tokens, &r.worker, &r.client, &r.action, &r.live, &r.quota, &r.Settlement.Day, &refunded, &detail, &progress, &r.settlementPending, &r.settlementOutcome, &r.CompletedAt)
	if errors.Is(e, pgx.ErrNoRows) {
		e = ErrMissing
	}
	if e != nil {
		return
	}
	var snapshot setupSnapshot
	if e = s.open(u, id, "setup", setup, &snapshot); e != nil {
		return
	}
	r.input, r.scene, r.Mode, r.kind, r.Target = snapshot.Input, snapshot.Scene, snapshot.Mode, snapshot.Kind, snapshot.Target
	if r.settlementPending {
		// A committed intent is already a terminal outcome for readers, even if
		// the state/refund transaction still needs maintenance retry.
		r.Status = r.settlementOutcome
	}
	r.Level = r.input.Level
	r.Settlement.Status = "uncharged"
	if refunded {
		r.Settlement.Status = "refunded"
	} else if r.Settlement.Day != nil {
		r.Settlement.Status = "charged"
		r.Settlement.Net = 1
	}
	if r.Status == "complete" {
		v := &Result{Mode: r.Mode, Settlement: r.Settlement}
		if r.Target == nil {
			v.Score = &Score{ID: r.source}
			e = s.open(u, r.source, "score", detail, &v.Score.Full)
		} else {
			v.Progress = &scoring.Progress{}
			e = s.open(u, r.source, "progress", progress, v.Progress)
		}
		if e != nil {
			return
		}
		r.Result = v
	}
	rows, e := tx.Query(ctx, `select id,client_message_id,seq,role,content_enc from practice_messages where activity_id=$1 order by seq`, id)
	if e != nil {
		return
	}
	defer rows.Close()
	for rows.Next() {
		var m app.Message
		var b []byte
		if e = rows.Scan(&m.Id, &m.ClientMessageId, &m.Seq, &m.Role, &b); e != nil {
			return
		}
		if e = s.open(u, m.Id, "message", b, &m.Text); e != nil {
			return
		}
		r.Messages = append(r.Messages, m)
	}
	e = rows.Err()
	return
}
func (s *Service) allowed(ctx context.Context, tx pgx.Tx, u uuid.UUID, in Input) error {
	ok, e := accounts.Granted(ctx, tx, u, "practice")
	if e != nil {
		return e
	}
	if !ok {
		return ErrConsent
	}
	if in.Contact != nil {
		if s.Summary != nil { // T25 adapter reads real profile material: withdrawal also fences the final write.
			ok, e := accounts.Granted(ctx, tx, u, "contacts")
			if e != nil {
				return e
			}
			if !ok {
				return membership.ErrForbidden
			}
		}
		return s.Rights.RequireContact(ctx, tx, u, in.Contact)
	}
	return nil
}

// A comparison is an explicit repeat of the same exercise or custom scenario,
// not an arbitrary association supplied by the client. Read only the setup, not
// the prior transcript or scores. The caller holds the owner's account lock.
func (s *Service) checkPrior(ctx context.Context, tx pgx.Tx, user uuid.UUID, in Input) error {
	if in.Previous == nil {
		return nil
	}
	var enc []byte
	err := tx.QueryRow(ctx, `select a.content_enc from activities a join practice_work w on w.activity_id=a.id where a.user_id=$1 and a.id=$2 and a.state='complete'`, user, *in.Previous).Scan(&enc)
	if errors.Is(err, pgx.ErrNoRows) {
		return accounts.ErrInvalid
	}
	if err != nil {
		return err
	}
	var prior setupSnapshot
	if err = s.open(user, *in.Previous, "setup", enc, &prior); err != nil {
		return err
	}
	old := prior.Input
	old.ID, old.Previous = in.ID, in.Previous
	if !reflect.DeepEqual(old, in) {
		return accounts.ErrInvalid
	}
	return nil
}

func (s *Service) Create(ctx context.Context, p accounts.Principal, in Input) (out SessionSummary, e error) {
	scene, mode, kind, target, e := in.describe()
	if e != nil {
		return
	}
	e = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if err := s.allowed(ctx, tx, p.User, in); err != nil {
			return err
		}
		var deleted bool
		if err := tx.QueryRow(ctx, `select exists(select 1 from practice_request_tombstones
where user_id=$1 and request_digest=sha256(uuid_send($1) || uuid_send($2)))`, p.User, in.ID).Scan(&deleted); err != nil {
			return err
		}
		if deleted {
			return membership.ErrConflict
		}
		b, err := s.seal(p.User, in.ID, "setup", setupSnapshot{in, scene, mode, kind, target})
		if err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `insert into activities(id,user_id,kind,contact_id,content_enc) values($1,$2,$3,$4,$5) on conflict(id) do nothing`, in.ID, p.User, kind, in.Contact, b)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 1 {
			if err = s.checkPrior(ctx, tx, p.User, in); err != nil {
				return err
			}
			if _, err = tx.Exec(ctx, `insert into practice_work(activity_id)values($1)`, in.ID); err != nil {
				return err
			}
		}
		r, err := s.load(ctx, tx, p.User, in.ID)
		if errors.Is(err, ErrMissing) || err == nil && !reflect.DeepEqual(r.input, in) {
			return membership.ErrConflict
		}
		out = r.summary()
		return err
	})
	return
}
func (s *Service) Get(ctx context.Context, p accounts.Principal, id uuid.UUID) (out Session, e error) {
	e = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		r, e := s.load(ctx, tx, p.User, id)
		if e != nil {
			return e
		}
		out, e = s.publicDetail(ctx, tx, p.User, r)
		return e
	})
	return
}

func (s *Service) publicDetail(ctx context.Context, tx pgx.Tx, user uuid.UUID, r record) (Session, error) {
	out := r.detail()
	if prior := out.Setup.Previous; prior != nil {
		var live bool
		err := tx.QueryRow(ctx, `select exists(
select 1 from activities a join practice_work w on w.activity_id=a.id
where a.user_id=$1 and a.id=$2 and a.state='complete' and a.kind in ('practice','drill'))`, user, *prior).Scan(&live)
		if err != nil {
			return Session{}, err
		}
		if !live {
			out.Setup.Previous = nil
		}
	}
	return out, nil
}

type Page struct {
	Items []SessionSummary `json:"items"`
	Next  *string          `json:"next_cursor"`
}

func (s *Service) List(ctx context.Context, p accounts.Principal, params app.ListSessionsParams) (out Page, e error) {
	out.Items = []SessionSummary{}
	n, e := limit(params.Limit)
	if e != nil {
		return
	}
	var cursor *uuid.UUID
	if params.Cursor != nil {
		id, err := uuid.Parse(*params.Cursor)
		if err != nil {
			return out, accounts.ErrInvalid
		}
		cursor = &id
	}
	e = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var at time.Time
		if cursor != nil {
			if e := tx.QueryRow(ctx, `select created_at from activities join practice_work on activity_id=id where user_id=$1 and id=$2`, p.User, cursor).Scan(&at); errors.Is(e, pgx.ErrNoRows) {
				return accounts.ErrInvalid
			} else if e != nil {
				return e
			}
		}
		rows, e := tx.Query(ctx, `select id from activities join practice_work on activity_id=id where user_id=$1 and ($2::uuid is null or (created_at,id)<($3,$2)) order by created_at desc,id desc limit $4`, p.User, cursor, at, n+1)
		if e != nil {
			return e
		}
		ids, e := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
		if e != nil {
			return e
		}
		if len(ids) > n {
			v := ids[n-1].String()
			out.Next = &v
			ids = ids[:n]
		}
		for _, id := range ids {
			r, e := s.load(ctx, tx, p.User, id)
			if e != nil {
				return e
			}
			out.Items = append(out.Items, r.summary())
		}
		return nil
	})
	return
}
