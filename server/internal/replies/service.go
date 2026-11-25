package replies

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"strings"
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
)

var ErrGeneration = errors.New("reply generation failed")
var ErrModeration = errors.New("moderation unavailable")
var ErrConsent = errors.New("chat import consent required")
var ErrDifferentInput = errors.New("request ID reused with different input")
var ErrRequestDeleted = errors.New("reply request was deleted")
var ErrMissing = errors.New("reply not found")

type Runner interface {
	Run(context.Context, gateway.Call) (gateway.Reply, error)
}

type ProfileProvider interface {
	ForModel(context.Context, pgx.Tx, uuid.UUID, uuid.UUID) (app.Profile, error)
}

type Service struct {
	accounts  *accounts.Service
	rights    *membership.Service
	data      *privacy.Coordinator
	cipher    *fieldcrypt.Cipher
	db        *pgxpool.Pool
	bus       *events.Bus
	recorder  Recorder
	profiles  ProfileProvider
	key       []byte
	newRunner func(gateway.Stop) (Runner, error)
}

func New(a *accounts.Service, rights *membership.Service, data *privacy.Coordinator, f *fieldcrypt.Cipher, db *pgxpool.Pool, b *events.Bus, master []byte, factory func(gateway.Stop) (Runner, error)) *Service {
	m := hmac.New(sha256.New, master)
	m.Write([]byte("replies/request-mac/v1"))
	return &Service{accounts: a, rights: rights, data: data, cipher: f, db: db, bus: b, key: m.Sum(nil), newRunner: factory}
}
func (s *Service) mac(u uuid.UUID, v any) []byte {
	m := hmac.New(sha256.New, s.key)
	m.Write(u[:])
	_ = json.NewEncoder(m).Encode(v)
	return m.Sum(nil)
}
func aad(u, id uuid.UUID, field string) []byte {
	return []byte("replies/v1/" + u.String() + "/" + id.String() + "/" + field)
}
func (s *Service) AttachProfiles(p ProfileProvider) { s.profiles = p } // composition root, before serving

func (s *Service) profileSummary(ctx context.Context, p accounts.Principal, contact *uuid.UUID, binding consentBinding) (string, error) {
	if contact == nil {
		return "", nil
	}
	if s.profiles == nil {
		return "", errors.New("profile provider unavailable")
	}
	var summary string
	e := s.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if e := s.allow(ctx, tx, p.User, contact, binding); e != nil {
			return e
		}
		v, e := s.profiles.ForModel(ctx, tx, p.User, *contact)
		if e != nil {
			return e
		}
		summary = v.Summary
		return nil
	})
	return summary, e
}

type Response struct {
	Status int
	Body   any
}

func safety() Response {
	return Response{200, gateway.Terminal{Safety: true, Message: gateway.HelpMessage}}
}

func (s *Service) Create(ctx context.Context, p accounts.Principal, in app.CreateReplyInput) (Response, error) {
	if in.RequestId == uuid.Nil || strings.TrimSpace(in.ChatText) == "" || in.Goal != nil && strings.TrimSpace(*in.Goal) == "" || in.ContactId != nil && *in.ContactId == uuid.Nil {
		return Response{}, accounts.ErrInvalid
	}
	var id uuid.UUID
	var attempt membership.Attempt
	var binding consentBinding
	var result Response
	// Only material participates in idempotency. Keep the original wire
	// encoding (including field order) for all existing persisted MACs.
	material := in
	material.ReplyConsentId, material.ContactsConsentId = nil, nil
	fingerprint := s.mac(p.User, material)
	e := s.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var mac, enc []byte
		var state string
		var keyActivity *uuid.UUID
		e := tx.QueryRow(ctx, `select activity_id,input_mac from reply_request_keys where user_id=$1 and request_id=$2`, p.User, in.RequestId).Scan(&keyActivity, &mac)
		switch {
		case e == nil:
			if !hmac.Equal(mac, fingerprint) {
				return ErrDifferentInput
			}
			if keyActivity == nil {
				return ErrRequestDeleted
			}
			id = *keyActivity
			if e = tx.QueryRow(ctx, `select a.state,a.content_enc,r.chat_consent_id,r.contacts_consent_id from reply_requests r join activities a on a.id=r.activity_id where r.user_id=$1 and r.request_id=$2`, p.User, in.RequestId).Scan(&state, &enc, &binding.chat, &binding.contacts); e != nil {
				return e
			}
			switch state {
			case "complete":
				b, e := s.cipher.Open(enc, aad(p.User, id, "result"))
				if e != nil {
					return e
				}
				result = Response{200, json.RawMessage(b)}
				return nil
			case "safety":
				result = safety()
				return nil
			case "failed":
				if e = s.requireBoundConsent(ctx, tx, p.User, in.ContactId, binding); e != nil {
					return e
				}
				return ErrGeneration
			}
		case errors.Is(e, pgx.ErrNoRows):
			binding, e = s.bindNewConsent(ctx, tx, p.User, in.ContactId, in.ReplyConsentId, in.ContactsConsentId)
			if e != nil {
				return e
			}
			if e = s.requireSelectedContact(ctx, tx, p.User, in.ContactId); e != nil {
				return e
			}
			id = uuid.New()
			if _, e = tx.Exec(ctx, `insert into activities(id,user_id,kind,contact_id) values($1,$2,'reply',$3)`, id, p.User, in.ContactId); e != nil {
				return e
			}
			if _, e = tx.Exec(ctx, `insert into reply_requests(activity_id,user_id,request_id,input_mac,chat_consent_id,contacts_consent_id) values($1,$2,$3,$4,$5,$6)`, id, p.User, in.RequestId, fingerprint, binding.chat, binding.contacts); e != nil {
				return e
			}
			if _, e = tx.Exec(ctx, `insert into reply_request_keys(user_id,request_id,input_mac,activity_id) values($1,$2,$3,$4)`, p.User, in.RequestId, fingerprint, id); e != nil {
				return e
			}
		default:
			return e
		}
		if state != "" {
			// A concurrent request may already have won this key. Never
			// authorize work under a different binding than the caller saw.
			if in.ReplyConsentId != nil || in.ContactsConsentId != nil {
				if e = matchExpectedConsent(in.ReplyConsentId, in.ContactsConsentId, binding); e != nil {
					return e
				}
			}
			if e = s.allow(ctx, tx, p.User, in.ContactId, binding); e != nil {
				return e
			}
		}
		attempt, e = s.rights.Begin(ctx, tx, p.User, id)
		if e != nil {
			return e
		}
		if attempt.State == string(membership.ModerationUnavailable) {
			attempt, e = s.rights.Retry(ctx, tx, p.User, id, attempt.Token)
			if e != nil {
				return e
			}
		}
		if !attempt.Work {
			result = Response{202, map[string]any{"request_id": in.RequestId, "status": "in_progress"}}
		}
		return nil
	})
	if e != nil || !attempt.Work {
		return result, e
	}
	// A disconnected HTTP client does not cancel the winning attempt. Request
	// retries see the hold or the committed result. The lease fences process loss.
	run, cancel := context.WithTimeout(context.WithoutCancel(ctx), 80*time.Second)
	defer cancel()
	finish := func(c context.Context, out membership.Outcome) error {
		return s.data.Access(c, p.User, func(tx pgx.Tx) error {
			if e := s.rights.Finish(c, tx, p.User, id, attempt.Token, out); e != nil {
				return e
			}
			_, e := tx.Exec(c, `update activities set state=$2 where id=$1 and state not in ('safety','complete','failed')`, id, string(out))
			return e
		})
	}
	v, e := s.generate(run, p, in, id, attempt.Token, binding, finish)
	if errors.Is(e, ErrModeration) || e == nil {
		return v, e
	}
	// If the gateway already stopped, never overwrite its durable terminal state.
	if errors.Is(e, errStopped) {
		return Response{}, e
	}
	clean, done := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
	defer done()
	settleErr := finish(clean, membership.Failed)
	if settleErr == nil && (errors.Is(e, gateway.ErrProvider) || errors.Is(e, gateway.ErrConfig) || errors.Is(e, errShape) || errors.Is(e, context.DeadlineExceeded)) {
		return Response{}, ErrGeneration
	}
	return Response{}, errors.Join(e, settleErr)
}

var errStopped = errors.New("terminal settlement unavailable")

func (s *Service) generate(ctx context.Context, p accounts.Principal, in app.CreateReplyInput, id, token uuid.UUID, binding consentBinding, finish func(context.Context, membership.Outcome) error) (Response, error) {
	var settlementErr error
	outcome := func(t gateway.Terminal) membership.Outcome {
		if t.Safety {
			return membership.Safety
		}
		return membership.ModerationUnavailable
	}
	runner, e := s.newRunner(func(c context.Context, _ gateway.Scope, t gateway.Terminal) error {
		settlementErr = finish(c, outcome(t))
		return settlementErr
	})
	if e != nil {
		return Response{}, e
	}
	summary, e := s.profileSummary(ctx, p, in.ContactId, binding)
	if e != nil {
		return Response{}, e
	}
	msg, _ := json.Marshal(struct {
		Chat    string  `json:"chat_text"`
		Goal    *string `json:"goal,omitempty"`
		Profile string  `json:"profile_summary"`
	}{in.ChatText, in.Goal, summary})
	scope := gateway.Scope{User: p.User, Operation: in.RequestId, Activity: id}
	if in.ContactId != nil {
		scope.Contact = *in.ContactId
	}
	r, e := runner.Run(ctx, gateway.Call{
		Scope: scope, Task: gateway.ReplySuggestion, Mode: gateway.JSONObject,
		Messages: []gateway.Message{{Role: "user", Content: string(msg)}},
		Authorize: func(attemptCtx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			if err := attemptCtx.Err(); err != nil {
				return err
			}
			// The adapter remains cancelable. The same guarded transaction must
			// have time to commit the receipt for an attempt that reached it.
			controlCtx, cancel := context.WithTimeout(context.WithoutCancel(attemptCtx), gateway.ExecutionLimit+15*time.Second)
			defer cancel()
			return s.accounts.WithSession(controlCtx, p, false, func(tx pgx.Tx) error {
				if e := s.allow(controlCtx, tx, p.User, in.ContactId, binding); e != nil {
					return e
				}
				return send(attemptCtx, tx)
			})
		},
	})
	if r.Terminal != nil {
		if settlementErr != nil {
			clean, done := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
			settlementErr = finish(clean, outcome(*r.Terminal))
			done()
		}
		if settlementErr != nil {
			return Response{}, errors.Join(errStopped, settlementErr)
		}
		if !r.Terminal.Safety {
			return Response{}, ErrModeration
		}
		// Audit/send errors after a durable safety settlement do not hide the
		// crisis response. Settlement failures were retried above.
		return safety(), nil
	}
	if e != nil {
		return Response{}, e
	}
	v, e := decodeResult(id, r.Result.Object, in.ChatText, in.Goal)
	if e != nil {
		return Response{}, e
	}
	b, e := json.Marshal(v)
	if e != nil {
		return Response{}, e
	}
	enc, e := s.cipher.Seal(b, aad(p.User, id, "result"))
	if e != nil {
		return Response{}, e
	}
	e = s.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if e := s.allow(ctx, tx, p.User, in.ContactId, binding); e != nil {
			return e
		}
		return s.rights.SaveApproved(ctx, tx, p.User, id, token, func(tx pgx.Tx) error {
			_, e := tx.Exec(ctx, `update activities set content_enc=$2,state='complete' where id=$1`, id, enc)
			return e
		})
	})
	if e != nil {
		return Response{}, e
	}
	return Response{200, v}, nil
}
