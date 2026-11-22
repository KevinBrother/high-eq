package profile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
)

var ErrMaterial = errors.New("invalid material inference")

type Session func(context.Context, func(pgx.Tx) error) error

// InferenceCleanup is deliberately narrower than a guarded data-access
// callback: it can only discard one processing reservation owned by one user.
type InferenceCleanup func(context.Context, uuid.UUID, uuid.UUID) error

func (s *Service) Infer(ctx context.Context, session Session, cleanup InferenceCleanup, u, id uuid.UUID, in app.InferProfileInput) (any, error) {
	if !text(in.ChatText, 8000) || in.RequestId == uuid.Nil {
		return nil, accounts.ErrInvalid
	}
	digest := inputDigest(in.ChatText)
	var before dossier
	var reserved inferenceReservation
	var current app.Profile
	e := session(ctx, func(tx pgx.Tx) error {
		if e := s.write(ctx, tx, u, &id); e != nil {
			return e
		}
		chatConsent, e := activeConsent(ctx, tx, u, "chat_import")
		if e != nil {
			return e
		}
		contactsConsent, e := activeConsent(ctx, tx, u, "contacts")
		if e != nil {
			return e
		}
		reserved, e = reserveInference(ctx, tx, u, id, in.RequestId, chatConsent, contactsConsent, digest)
		if e != nil {
			return e
		}
		if reserved.state == "complete" {
			c, e := s.Contact(ctx, tx, u, id)
			current = c.Profile
			return e
		}
		before, e = s.read(ctx, tx, u, id)
		return e
	})
	if e != nil {
		return nil, e
	}
	if reserved.state == "complete" {
		return current, nil
	}

	opts := make([][]string, len(axes))
	for i, a := range axes {
		opts[i] = a.options
	}
	b, _ := json.Marshal(opts)
	// T10 opens its own guarded transactions. Do not hold the account lock across a network call.
	call := gateway.Call{Scope: gateway.Scope{User: u, Contact: id, Operation: in.RequestId}, Task: gateway.ProfileInference, Mode: gateway.JSONObject, Variables: map[string]string{"scene": string(before.Scene), "options": string(b)}, Messages: []gateway.Message{{Role: "user", Content: in.ChatText}}}
	call.BeforeAttempt = func(attemptCtx context.Context) error {
		return checkInferenceAttempt(attemptCtx, session, u, id, in.RequestId, reserved.chatConsent, reserved.contactsConsent, digest, func(tx pgx.Tx) error {
			return s.write(attemptCtx, tx, u, &id)
		})
	}
	reply, e := s.AI.Run(ctx, call)
	if reply.Terminal != nil || e != nil {
		v, _, settledErr := s.settleInferenceRun(ctx, cleanup, u, in.RequestId, reply, e)
		return v, settledErr
	}
	choices, e := decodeChoices(reply.Result.Object, before.Scene)
	if e != nil {
		return nil, s.failInference(ctx, cleanup, u, in.RequestId, e)
	}

	var out app.Profile
	var stale bool
	e = session(ctx, func(tx pgx.Tx) error {
		var stored inferenceReservation
		var contact, chatConsent, contactsConsent uuid.UUID
		e := tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, in.RequestId).Scan(&contact, &chatConsent, &contactsConsent, &stored.digest, &stored.state)
		if errors.Is(e, pgx.ErrNoRows) {
			stale = true
			return nil
		}
		if e != nil {
			return e
		}
		stored.chatConsent = chatConsent
		stored.contactsConsent = contactsConsent
		if contact != id || !bytes.Equal(stored.digest, digest) || stored.state != "processing" || chatConsent != reserved.chatConsent || contactsConsent != reserved.contactsConsent {
			if e = invalidateInference(ctx, tx, u, in.RequestId); e != nil {
				return e
			}
			stale = true
			return nil
		}
		activeChat, e := activeConsent(ctx, tx, u, "chat_import")
		if errors.Is(e, membership.ErrForbidden) || e == nil && activeChat != reserved.chatConsent {
			if e = invalidateInference(ctx, tx, u, in.RequestId); e != nil {
				return e
			}
			stale = true
			return nil
		}
		if e != nil {
			return e
		}
		activeContacts, e := activeConsent(ctx, tx, u, "contacts")
		if errors.Is(e, membership.ErrForbidden) || e == nil && activeContacts != reserved.contactsConsent {
			if e = invalidateInference(ctx, tx, u, in.RequestId); e != nil {
				return e
			}
			stale = true
			return nil
		}
		if e != nil {
			return e
		}
		if e = s.write(ctx, tx, u, &id); e != nil {
			if !errors.Is(e, membership.ErrForbidden) {
				return e
			}
			if e = invalidateInference(ctx, tx, u, in.RequestId); e != nil {
				return e
			}
			stale = true
			return nil
		}
		d, e := s.readLocked(ctx, tx, u, id)
		if e != nil {
			return e
		}
		if d != before {
			if e = invalidateInference(ctx, tx, u, in.RequestId); e != nil {
				return e
			}
			stale = true
			return nil
		}
		d.Material = choices
		if e = s.store(ctx, tx, u, id, d, false); e != nil {
			return e
		}
		if e = completeInference(ctx, tx, u, in.RequestId); e != nil {
			return e
		}
		c, e := s.Contact(ctx, tx, u, id)
		out = c.Profile
		return e
	})
	if e != nil {
		return nil, s.failInference(ctx, cleanup, u, in.RequestId, e)
	}
	if stale {
		return nil, membership.ErrConflict
	}
	return out, nil
}

func (s *Service) settleInferenceRun(ctx context.Context, cleanup InferenceCleanup, u, request uuid.UUID, reply gateway.Reply, cause error) (any, bool, error) {
	cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
	defer cancel()
	cleanupErr := cleanup(cleanupCtx, u, request)
	if reply.Terminal != nil {
		// A safety or moderation terminal is the user-visible outcome. Cleanup
		// is best effort and must not turn that outcome into a generic 500.
		return reply.Terminal, true, nil
	}
	if cause == nil {
		return nil, true, cleanupErr
	}
	if cleanupErr != nil {
		return nil, true, errors.Join(cause, cleanupErr)
	}
	return nil, true, cause
}

func (s *Service) failInference(ctx context.Context, cleanup InferenceCleanup, u, request uuid.UUID, cause error) error {
	_, _, e := s.settleInferenceRun(ctx, cleanup, u, request, gateway.Reply{}, cause)
	return e
}

func decodeChoices(b []byte, sc app.ContactScene) (out [len(axes)]int, e error) {
	var x struct {
		Choices []*int `json:"choices"`
	}
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if d.Decode(&x) != nil || d.Decode(new(any)) != io.EOF || len(x.Choices) != len(axes) {
		return out, ErrMaterial
	}
	for i, v := range x.Choices {
		if v == nil || *v < 0 || *v > len(axes[i].options) || (i == 6 && sc != "partner" && *v != 0) {
			return out, ErrMaterial
		}
		out[i] = *v
	}
	return
}
