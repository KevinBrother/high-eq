package assessment

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
)

const interval = 28 * 24 * time.Hour

var ErrConsent = errors.New("assessment consent required")

type TooSoon struct{ RetryAt time.Time }

func (e *TooSoon) Error() string { return "assessment not yet eligible" }

func retest(last, now time.Time) *TooSoon {
	next := last.UTC().Add(interval)
	if now.Before(next) {
		return &TooSoon{next}
	}
	return nil
}

type Result struct {
	ID             uuid.UUID `json:"id"`
	CompletedAt    time.Time `json:"completed_at"`
	NextEligibleAt time.Time `json:"next_eligible_at"`
	Scores
}

type Service struct {
	Bank     *Instrument
	sessions *accounts.Service
	fields   *fieldcrypt.Cipher
	bus      *events.Bus
	db       *pgxpool.Pool
}

func New(b *Instrument, s *accounts.Service, f *fieldcrypt.Cipher, bus *events.Bus, db *pgxpool.Pool) *Service {
	return &Service{b, s, f, bus, db}
}

type record struct {
	ID      uuid.UUID
	Version string
	At      time.Time
}

func (r record) aad(user uuid.UUID, field string) []byte {
	return []byte("assessments:" + field + ":" + user.String() + ":" + r.ID.String() + ":" + r.Version)
}

func (r record) result(s Scores) Result { return Result{r.ID, r.At.UTC(), r.At.UTC().Add(interval), s} }
func (r record) seal(f *fieldcrypt.Cipher, user uuid.UUID, field string, v any) ([]byte, error) {
	plain, e := json.Marshal(v)
	if e != nil {
		return nil, e
	}
	return f.Seal(plain, r.aad(user, field))
}

func (r record) open(f *fieldcrypt.Cipher, user uuid.UUID, field string, enc []byte, v any) error {
	plain, e := f.Open(enc, r.aad(user, field))
	if e != nil {
		return e
	}
	return json.Unmarshal(plain, v)
}

func (s *Service) Submit(ctx context.Context, p accounts.Principal, version string, answers []int) (Result, error) {
	var out Result
	err := s.sessions.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		granted, e := accounts.Granted(ctx, tx, p.User, "assessment")
		if e != nil {
			return e
		}
		if !granted {
			return ErrConsent
		}
		scores, e := s.Bank.Score(version, answers)
		if e != nil {
			return e
		}
		// WithSession holds the user row lock through commit. Use the database clock
		// AFTER obtaining the lock, not transaction start time or a client timestamp.
		r := record{ID: uuid.New(), Version: version}
		var last *time.Time
		e = tx.QueryRow(ctx, `select clock_timestamp(),(select max(completed_at) from assessments where user_id=$1)`, p.User).Scan(&r.At, &last)
		if e != nil {
			return e
		}
		if last != nil {
			if wait := retest(*last, r.At); wait != nil {
				return wait
			}
		}
		a, e := r.seal(s.fields, p.User, "answers_enc", answers)
		if e != nil {
			return e
		}
		v, e := r.seal(s.fields, p.User, "scores_enc", scores)
		if e != nil {
			return e
		}
		_, e = tx.Exec(ctx, `insert into assessments(id,user_id,instrument_version,answers_enc,scores_enc,completed_at,completion_pending) values($1,$2,$3,$4,$5,$6,true)`, r.ID, p.User, r.Version, a, v, r.At)
		out = r.result(scores)
		return e
	})
	if err != nil {
		return Result{}, err
	}
	// Source and pending bit are durable. A subscriber failure does not turn an
	// accepted answer sheet into a failed submission; ReplayPending retries it.
	if s.bus.AssessmentCompleted.HasSubscribers() {
		_ = s.bus.PublishAssessment(ctx, events.Assessment{UserID: p.User, AssessmentID: out.ID, OccurredAt: out.CompletedAt})
	}
	return out, nil
}

// ReadResult lets a T26 subscriber read the canonical scores under its guarded transaction.
func (s *Service) ReadResult(ctx context.Context, tx pgx.Tx, user, id uuid.UUID) (Result, error) {
	var r record
	var enc []byte
	var scores Scores
	e := tx.QueryRow(ctx, `select id,instrument_version,completed_at,scores_enc from assessments where user_id=$1 and id=$2`, user, id).Scan(&r.ID, &r.Version, &r.At, &enc)
	if e != nil {
		return Result{}, e
	}
	e = r.open(s.fields, user, "scores_enc", enc, &scores)
	return r.result(scores), e
}
