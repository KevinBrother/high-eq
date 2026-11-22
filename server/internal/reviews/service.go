package reviews

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"log/slog"
	"time"

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

type Service struct {
	Accounts *accounts.Service
	Rights   *membership.Service
	Data     *privacy.Coordinator
	Fields   *fieldcrypt.Cipher
	DB       *pgxpool.Pool
	Bus      *events.Bus
	Key      []byte
	Router   func(gateway.Stop) (scoring.Runner, error)
	Profile  interface {
		ForModel(context.Context, pgx.Tx, uuid.UUID, uuid.UUID) (app.Profile, error)
	}
}

// ErrDifferentInput means the caller must allocate a fresh request ID for edited material.
var ErrDifferentInput = errors.New("review request ID already used for different input")

// ErrDeleted means the request ID belongs to a deleted review and must not be
// reused, even if the user has capacity again.
var ErrDeleted = errors.New("review request ID belongs to a deleted review")

// ErrRecoveryExpired permanently closes the original request key once an
// unmoderated checkpoint's replay window has elapsed. A fresh request ID is
// required so a complete model result is never silently regenerated.
var ErrRecoveryExpired = errors.New("review recovery window expired")

type Response struct {
	Status int
	Body   any
}
type work struct {
	id, source      uuid.UUID
	attempt         membership.Attempt
	profile, phrase string
	generated       *gateway.Generated
}

func aad(u, id uuid.UUID, field string) []byte {
	return []byte("review/v1/" + u.String() + "/" + id.String() + "/" + field)
}
func (s *Service) mac(user uuid.UUID, field string, value any) []byte {
	m := hmac.New(sha256.New, s.Key)
	m.Write(aad(user, uuid.Nil, field))
	_ = json.NewEncoder(m).Encode(value)
	return m.Sum(nil)
}
func safety() Response {
	return Response{200, gateway.Terminal{Safety: true, Message: gateway.HelpMessage}}
}
func (s *Service) allow(ctx context.Context, tx pgx.Tx, u uuid.UUID, in app.ReviewInput) error {
	for _, p := range []string{"review", "contacts"} {
		if p == "contacts" && in.ContactId == nil {
			continue
		}
		ok, e := accounts.Granted(ctx, tx, u, p)
		if e != nil {
			return e
		}
		if !ok {
			return ErrConsent
		}
	}
	if in.ContactId != nil {
		if e := s.Rights.RequireContact(ctx, tx, u, in.ContactId); e != nil {
			return e
		}
	}
	if in.MarkId != nil || in.SignalEventId != nil {
		var ok bool
		e := tx.QueryRow(ctx, `select ($2::uuid is null or exists(select from manual_marks where user_id=$1 and id=$2 and accepted_at>now()-interval '4320 hours')) and ($3::uuid is null or exists(select from signal_events where user_id=$1 and id=$3 and occurred_at>now()-interval '4320 hours'))`, u, in.MarkId, in.SignalEventId).Scan(&ok)
		if e != nil {
			return e
		}
		if !ok {
			return accounts.ErrInvalid
		}
	}
	return nil
}
func (s *Service) deletedRequest(ctx context.Context, tx pgx.Tx, user, request uuid.UUID, fingerprint []byte) (error, bool) {
	var mac []byte
	e := tx.QueryRow(ctx, `select input_mac from review_tombstones where user_id=$1 and request_id=$2`, user, request).Scan(&mac)
	if errors.Is(e, pgx.ErrNoRows) {
		return nil, false
	}
	if e != nil {
		return e, false
	}
	if hmac.Equal(mac, fingerprint) {
		return ErrDeleted, true
	}
	return ErrDifferentInput, true
}
func (s *Service) begin(ctx context.Context, p accounts.Principal, in app.ReviewInput, w *work) (res Response, err error) {
	fingerprint := s.mac(p.User, "input", in)
	expired := false
	err = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var mac, checkpoint, generatedRaw []byte
		var generatedTask *string
		var generatedCall *uuid.UUID
		var generatedFresh, generatedExpired bool
		var state string
		e := tx.QueryRow(ctx, `select a.id,a.source_id,a.state,r.input_mac,r.repair_enc,
r.generated_enc,r.generated_task,r.generated_call_id,
coalesce(r.generated_at>now()-make_interval(secs=>$3),false),r.generated_expired
from review_requests r join activities a on a.id=r.activity_id where r.user_id=$1 and r.request_id=$2
for update of r`, p.User, in.RequestId, int(generatedCheckpointTTL.Seconds())).Scan(&w.id, &w.source, &state, &mac, &checkpoint, &generatedRaw, &generatedTask, &generatedCall, &generatedFresh, &generatedExpired)
		if e == nil {
			if !hmac.Equal(mac, fingerprint) {
				return ErrDifferentInput
			}
			// Expiry is a permanent property of the original request key and must be
			// checked before the activity's derived failed state. Sanitization and the
			// held-worker fence are committed with this lock, then reported as 409.
			if generatedExpired || generatedTask != nil && !generatedFresh {
				expired, e = s.expireGeneratedCheckpoint(ctx, tx, w.id, p.User)
				return e
			}
			switch state {
			case "safety":
				res = safety()
				return nil
			case "complete":
				v, e := s.Get(ctx, tx, p.User, w.id)
				res = Response{200, v}
				return e
			case "failed":
				return ErrGeneration
			}
		} else if !errors.Is(e, pgx.ErrNoRows) {
			return e
		} else if de, found := s.deletedRequest(ctx, tx, p.User, in.RequestId, fingerprint); found {
			return de
		}
		if e = s.allow(ctx, tx, p.User, in); e != nil {
			return e
		}
		if w.id == uuid.Nil {
			e = tx.QueryRow(ctx, `insert into activities(user_id,kind,contact_id) values($1,'review',$2) returning id,source_id`, p.User, in.ContactId).Scan(&w.id, &w.source)
			if e != nil {
				return e
			}
			var sc []byte
			if in.Scene != nil {
				sc = s.mac(p.User, "scene", *in.Scene)
			}
			tag, e := tx.Exec(ctx, `insert into review_requests(activity_id,user_id,request_id,input_mac,scene_mac,mark_id,signal_event_id) values($1,$2,$3,$4,$5,$6,$7)`, w.id, p.User, in.RequestId, fingerprint, sc, in.MarkId, in.SignalEventId)
			if e != nil {
				return e
			}
			if tag.RowsAffected() != 1 {
				if de, found := s.deletedRequest(ctx, tx, p.User, in.RequestId, fingerprint); found {
					return de
				}
				return ErrDeleted
			}
		}
		w.attempt, e = s.Rights.Begin(ctx, tx, p.User, w.id)
		if e != nil {
			return e
		}
		// A persisted moderation failure may still have a held quota attempt if
		// its best-effort settlement failed. Settle that old token, then issue a
		// fresh token before retrying the already checkpointed scoring step.
		if state == "moderation_unavailable" {
			if w.attempt.State == "held" {
				if e = s.Rights.Finish(ctx, tx, p.User, w.id, w.attempt.Token, membership.ModerationUnavailable); e != nil {
					return e
				}
			}
			w.attempt, e = s.Rights.Retry(ctx, tx, p.User, w.id, w.attempt.Token)
			if e != nil {
				return e
			}
		} else if w.attempt.State == string(membership.ModerationUnavailable) {
			w.attempt, e = s.Rights.Retry(ctx, tx, p.User, w.id, w.attempt.Token)
			if e != nil {
				return e
			}
		}
		if !w.attempt.Work {
			res = Response{202, map[string]any{"request_id": in.RequestId, "status": "in_progress"}}
			return nil
		}
		if checkpoint != nil {
			b, e := s.Fields.Open(checkpoint, aad(p.User, w.id, "repair"))
			if e != nil {
				return e
			}
			w.phrase = string(b)
		}
		if generatedTask != nil && generatedCall != nil {
			task := gateway.Task(*generatedTask)
			g, e := s.loadGenerated(ctx, tx, p.User, w.id, task, generatedRaw, *generatedCall, generatedFresh)
			if e != nil {
				return e
			}
			// A repair checkpoint supersedes an unmoderated analysis output; a
			// score output without its approved repair is not a valid replay.
			if g != nil && ((g.Task == gateway.ReviewAnalysis && w.phrase != "") || (g.Task == gateway.Scoring && w.phrase == "")) {
				_, e = tx.Exec(ctx, `update review_requests set generated_enc=null,generated_task=null,generated_call_id=null,generated_at=null,generated_expired=false where activity_id=$1 and user_id=$2`, w.id, p.User)
				g = nil
			}
			if e != nil {
				return e
			}
			w.generated = g
		}
		if in.ContactId != nil && s.Profile != nil {
			v, e := s.Profile.ForModel(ctx, tx, p.User, *in.ContactId)
			if e != nil {
				return e
			}
			b, e := json.Marshal(v)
			if e != nil {
				return e
			}
			w.profile = string(b)
		}
		_, e = tx.Exec(ctx, `update activities set state='active' where id=$1`, w.id)
		return e
	})
	if err == nil && expired {
		return Response{}, ErrRecoveryExpired
	}
	return
}

func (s *Service) Create(ctx context.Context, p accounts.Principal, in app.ReviewInput) (Response, error) {
	if !valid(in) {
		return Response{}, accounts.ErrInvalid
	}
	var w work
	res, e := s.begin(ctx, p, in, &w)
	if e != nil || !w.attempt.Work {
		return res, e
	}
	// A disconnected mobile client may retrieve this committed operation later.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 150*time.Second)
	defer cancel()
	// Persist the terminal activity state independently from quota settlement.
	// A quota-side failure must not leave a crisis or moderation terminal result
	// replayable as a fresh generation.
	persistTerminal := func(out membership.Outcome) error {
		return s.persistTerminal(ctx, p, w.id, w.attempt.Token, out)
	}
	settleQuota := func(out membership.Outcome) error {
		c, done := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer done()
		return s.Data.Access(c, p.User, func(tx pgx.Tx) error {
			return s.Rights.Finish(c, tx, p.User, w.id, w.attempt.Token, out)
		})
	}
	finish := func(out membership.Outcome) error {
		if e := persistTerminal(out); e != nil {
			return e
		}
		e := settleQuota(out)
		if e != nil && out == membership.Safety {
			// The crisis answer is authoritative. The persisted state prevents a
			// retry from generating again; the old hold can expire or be settled
			// by a later maintenance/recovery path.
			slog.Error("review settlement unavailable", "module", "reviews", "result", "safety_stop_failed")
			return nil
		}
		return e
	}
	// T10 invokes Stop synchronously. A parser-detected T12 terminal may not
	// invoke it at all; a gateway Stop error must be retried under the same token.
	var settled membership.Outcome
	stopOnce := func(out membership.Outcome) error {
		if settled == out {
			return nil
		}
		err := finish(out)
		if err == nil {
			settled = out
		}
		return err
	}
	r, e := s.Router(func(_ context.Context, _ gateway.Scope, t gateway.Terminal) error {
		if t.Safety {
			return stopOnce(membership.Safety)
		}
		return stopOnce(membership.ModerationUnavailable)
	})
	scope := gateway.Scope{User: p.User, Operation: in.RequestId, Activity: w.id}
	if in.ContactId != nil {
		scope.Contact = *in.ContactId
	}
	var phrase string
	var full *scoring.Full
	var call uuid.UUID
	var term *gateway.Terminal
	if e == nil {
		beforeGenerate := func(context.Context) error {
			return s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
				return s.allow(ctx, tx, p.User, in)
			})
		}
		generatedHook := func(task gateway.Task) func(context.Context, uuid.UUID, string) error {
			return func(callCtx context.Context, callID uuid.UUID, raw string) error {
				return s.saveGenerated(callCtx, p, w.id, w.attempt.Token, in, task, callID, raw)
			}
		}
		hooks := func(task gateway.Task, generated *gateway.Generated) scoring.Hooks {
			h := scoring.Hooks{BeforeGenerate: beforeGenerate, OnGenerated: generatedHook(task), Generated: generated}
			if generated != nil {
				h.OnGenerated = nil
			}
			return h
		}
		analysisGenerated, scoringGenerated := (*gateway.Generated)(nil), (*gateway.Generated)(nil)
		if w.generated != nil {
			switch w.generated.Task {
			case gateway.ReviewAnalysis:
				analysisGenerated = w.generated
			case gateway.Scoring:
				scoringGenerated = w.generated
			}
		}
		phrase, full, call, term, e = analyze(ctx, r, scope, in, w.profile, w.phrase, func(phrase string) error {
			return s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
				if e := s.allow(ctx, tx, p.User, in); e != nil {
					return e
				}
				b, e := s.Fields.Seal([]byte(phrase), aad(p.User, w.id, "repair"))
				if e != nil {
					return e
				}
				tag, e := tx.Exec(ctx, `update review_requests r set repair_enc=$3,generated_enc=null,generated_task=null,generated_call_id=null,generated_at=null,generated_expired=false from quota_attempts q where r.activity_id=$1 and r.generated_expired=false and q.activity_id=r.activity_id and q.token=$2 and q.state='held'`, w.id, w.attempt.Token, b)
				if e == nil && tag.RowsAffected() != 1 {
					return membership.ErrConflict
				}
				return e
			})
		}, analyzeHooks{BeforeScore: func() error { return beforeGenerate(ctx) }, Analysis: hooks(gateway.ReviewAnalysis, analysisGenerated), Scoring: hooks(gateway.Scoring, scoringGenerated)})
	}
	if term != nil {
		if term.Safety { // Never relabel a crisis, including a failed gateway Stop. Retry settlement with the same token.
			if err := stopOnce(membership.Safety); err != nil {
				// A safety response is a durable terminal promise. Returning 200 while
				// the activity remains active would let an expired lease regenerate a
				// normal score and charge. Surface the retryable storage failure instead.
				slog.Error("review settlement unavailable", "module", "reviews", "result", "safety_stop_failed")
				return Response{}, err
			}
			return safety(), nil
		}
		if term.Code == "moderation_unavailable" {
			return Response{}, errors.Join(ErrModeration, stopOnce(membership.ModerationUnavailable))
		}
		e = ErrGeneration
	}
	if e == nil && full != nil {
		var v app.Review
		v, e = s.save(ctx, p, in, w, phrase, *full, call)
		if e == nil {
			return Response{200, v}, nil
		}
	}
	if e == nil {
		e = ErrGeneration
	}
	settle := finish(membership.Failed)
	return Response{}, errors.Join(e, settle)
}
