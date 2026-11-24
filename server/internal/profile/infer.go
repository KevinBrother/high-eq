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
	"github.com/jackc/pgx/v5/pgconn"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
)

var ErrMaterial = errors.New("invalid material inference")

type Session func(context.Context, func(pgx.Tx) error) error

const inferenceCleanupTimeout = 10 * time.Second
const inferenceControlGrace = 15 * time.Second

// inferenceControlTx keeps transaction-backed dispatch work alive after an
// adapter has returned even if the caller cancels. The adapter still receives
// the original attempt context; only database operations on the guarded
// transaction use the bounded control context.
type inferenceControlTx struct {
	pgx.Tx
	ctx context.Context
}

func (tx inferenceControlTx) Exec(_ context.Context, sql string, arguments ...any) (pgconn.CommandTag, error) {
	return tx.Tx.Exec(tx.ctx, sql, arguments...)
}

func (tx inferenceControlTx) Query(_ context.Context, sql string, args ...any) (pgx.Rows, error) {
	return tx.Tx.Query(tx.ctx, sql, args...)
}

func (tx inferenceControlTx) QueryRow(_ context.Context, sql string, args ...any) pgx.Row {
	return tx.Tx.QueryRow(tx.ctx, sql, args...)
}

// InferenceCleanup is deliberately narrower than a guarded data-access
// callback: it can only release one owned processing reservation for a user and
// contact. The owner token fences a late executor from releasing a replacement.
type InferenceCleanup func(ctx context.Context, user, contact, request, owner uuid.UUID) error

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
		if reserved.state == "invalidated" {
			// Commit the invalidation before returning the conflict to HTTP.
			return nil
		}
		before, e = s.read(ctx, tx, u, id)
		return e
	})
	if e != nil {
		return nil, e
	}
	if reserved.state == "invalidated" {
		return nil, membership.ErrConflict
	}
	if reserved.state == "complete" {
		return current, nil
	}

	opts := make([][]string, len(axes))
	for i, a := range axes {
		opts[i] = a.options
	}
	b, _ := json.Marshal(opts)
	call := gateway.Call{
		Scope:        gateway.Scope{User: u, Contact: id, Operation: in.RequestId},
		Task:         gateway.ProfileInference,
		Mode:         gateway.JSONObject,
		ProfileOwner: reserved.owner,
		Variables:    map[string]string{"scene": string(before.Scene), "options": string(b)},
		Messages:     []gateway.Message{{Role: "user", Content: in.ChatText}},
	}
	call.Authorize = s.inferenceAuthorizer(session, u, id, in.RequestId, reserved.chatConsent, reserved.contactsConsent, digest, reserved.owner)
	reply, e := s.AI.Run(ctx, call)
	if reply.Terminal != nil || e != nil {
		v, _, settledErr := s.settleInferenceRun(ctx, cleanup, u, id, in.RequestId, reserved.owner, reply, e)
		return v, settledErr
	}
	choices, e := decodeChoices(reply.Result.Object, before.Scene)
	if e != nil {
		return nil, s.failInference(ctx, cleanup, u, id, in.RequestId, reserved.owner, e)
	}

	var out app.Profile
	var stale bool
	e = session(ctx, func(tx pgx.Tx) error {
		stored, e := scanInferenceRecord(tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state,owner_id,
 coalesce(lease_expires_at<=clock_timestamp(),true)
 from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, in.RequestId))
		if errors.Is(e, pgx.ErrNoRows) {
			stale = true
			return nil
		}
		if e != nil {
			return e
		}
		// A replacement owner or an expired lease wins. A late result must not
		// invalidate or overwrite the replacement's reservation.
		if !stored.owner.Valid || stored.owner.UUID != reserved.owner || stored.expired {
			stale = true
			return nil
		}
		if stored.contact != id || !bytes.Equal(stored.digest, digest) || stored.state != "processing" || stored.chatConsent != reserved.chatConsent || stored.contactsConsent != reserved.contactsConsent {
			if e = invalidateInference(ctx, tx, u, id, in.RequestId, stored.owner); e != nil {
				return e
			}
			stale = true
			return nil
		}
		activeChat, e := activeConsent(ctx, tx, u, "chat_import")
		if errors.Is(e, membership.ErrForbidden) || e == nil && activeChat != reserved.chatConsent {
			if e = invalidateInference(ctx, tx, u, id, in.RequestId, stored.owner); e != nil {
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
			if e = invalidateInference(ctx, tx, u, id, in.RequestId, stored.owner); e != nil {
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
			if e = invalidateInference(ctx, tx, u, id, in.RequestId, stored.owner); e != nil {
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
			if e = invalidateInference(ctx, tx, u, id, in.RequestId, stored.owner); e != nil {
				return e
			}
			stale = true
			return nil
		}
		d.Material = choices
		if e = s.store(ctx, tx, u, id, d, false); e != nil {
			return e
		}
		if e = completeInference(ctx, tx, u, in.RequestId, reserved.owner); e != nil {
			return e
		}
		c, e := s.Contact(ctx, tx, u, id)
		out = c.Profile
		return e
	})
	if e != nil {
		return nil, s.failInference(ctx, cleanup, u, id, in.RequestId, reserved.owner, e)
	}
	if stale {
		return nil, membership.ErrConflict
	}
	return out, nil
}

// inferenceAuthorizer binds one profile request and reservation owner to the
// caller-owned account transaction. It rechecks the reservation, owner, consent
// generations and contact write access immediately before the adapter call.
// The adapter gets the original cancellable attempt context, while the
// transaction that commits a dispatched attempt's cost is detached from caller
// cancellation and bounded by the execution limit plus cleanup grace.
func (s *Service) inferenceAuthorizer(session Session, u, contact, request, chatConsent, contactsConsent uuid.UUID, digest []byte, owner uuid.UUID) func(context.Context, pgx.Tx, func(context.Context, pgx.Tx) error) error {
	return func(attemptCtx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
		if err := attemptCtx.Err(); err != nil {
			return err
		}
		controlCtx, cancel := inferenceControlContext(attemptCtx)
		defer cancel()
		changed := false
		e := session(controlCtx, func(tx pgx.Tx) error {
			var e error
			changed, e = checkInferenceAttemptTx(controlCtx, tx, u, contact, request, chatConsent, contactsConsent, digest, owner, func(tx pgx.Tx) error {
				return s.write(controlCtx, tx, u, &contact)
			}, func(tx pgx.Tx) error {
				return send(attemptCtx, inferenceControlTx{Tx: tx, ctx: controlCtx})
			})
			return e
		})
		if e == nil && changed {
			return membership.ErrConflict
		}
		return e
	}
}

func (s *Service) settleInferenceRun(ctx context.Context, cleanup InferenceCleanup, u, contact, request, owner uuid.UUID, reply gateway.Reply, cause error) (any, bool, error) {
	cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), inferenceCleanupTimeout)
	defer cancel()
	cleanupErr := cleanup(cleanupCtx, u, contact, request, owner)
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

func (s *Service) failInference(ctx context.Context, cleanup InferenceCleanup, u, contact, request, owner uuid.UUID, cause error) error {
	_, _, e := s.settleInferenceRun(ctx, cleanup, u, contact, request, owner, gateway.Reply{}, cause)
	return e
}

func inferenceControlContext(attemptCtx context.Context) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.WithoutCancel(attemptCtx), gateway.ExecutionLimit+inferenceControlGrace)
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
