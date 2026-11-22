package profile

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/membership"
)

var ErrInferencePending = errors.New("profile inference pending")

type inferenceReservation struct {
	chatConsent     uuid.UUID
	contactsConsent uuid.UUID
	digest          []byte
	state           string
}

func activeConsent(ctx context.Context, tx pgx.Tx, u uuid.UUID, purpose string) (uuid.UUID, error) {
	var id uuid.UUID
	e := tx.QueryRow(ctx, `select id from consents where user_id=$1 and purpose=$2 and withdrawn_at is null order by granted_at desc,id desc limit 1 for share`, u, purpose).Scan(&id)
	if errors.Is(e, pgx.ErrNoRows) {
		return uuid.Nil, membership.ErrForbidden
	}
	return id, e
}

func inputDigest(text string) []byte {
	sum := sha256.Sum256([]byte(text))
	return sum[:]
}

// reserveInference creates or classifies the account-scoped idempotency row.
// A completed request is never regenerated; callers return the current profile.
func reserveInference(ctx context.Context, tx pgx.Tx, u, contact, request, chatConsent, contactsConsent uuid.UUID, digest []byte) (inferenceReservation, error) {
	var got inferenceReservation
	var gotContact, gotChatConsent, gotContactsConsent uuid.UUID
	e := tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, request).Scan(&gotContact, &gotChatConsent, &gotContactsConsent, &got.digest, &got.state)
	if errors.Is(e, pgx.ErrNoRows) {
		got = inferenceReservation{chatConsent: chatConsent, contactsConsent: contactsConsent, digest: digest, state: "processing"}
		tag, e := tx.Exec(ctx, `insert into profile_inference_requests(user_id,request_id,contact_id,chat_consent_id,contacts_consent_id,input_digest) values($1,$2,$3,$4,$5,$6) on conflict(user_id,request_id) do nothing`, u, request, contact, chatConsent, contactsConsent, digest)
		if e != nil {
			return inferenceReservation{}, e
		}
		if tag.RowsAffected() == 1 {
			return got, nil
		}
		// A concurrent first attempt won the insert. Re-read its classification.
		e = tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, request).Scan(&gotContact, &gotChatConsent, &gotContactsConsent, &got.digest, &got.state)
		if e != nil {
			return inferenceReservation{}, e
		}
	} else if e != nil {
		return inferenceReservation{}, e
	}
	if gotContact != contact || !bytes.Equal(got.digest, digest) {
		return inferenceReservation{}, membership.ErrConflict
	}
	got.chatConsent = gotChatConsent
	got.contactsConsent = gotContactsConsent
	switch got.state {
	case "processing":
		return inferenceReservation{}, ErrInferencePending
	case "complete":
		return got, nil
	case "invalidated":
		return inferenceReservation{}, membership.ErrConflict
	default:
		return inferenceReservation{}, errors.New("invalid profile inference state")
	}
}

// checkInferenceAttempt revalidates the exact reservation and both consent
// records immediately before material leaves the process. Authorization changes
// are terminal for this request: a later regrant must not revive it.
func checkInferenceAttempt(ctx context.Context, session Session, u, contact, request, chatConsent, contactsConsent uuid.UUID, digest []byte, authorize func(pgx.Tx) error) error {
	changed := false
	e := session(ctx, func(tx pgx.Tx) error {
		var gotContact, gotChatConsent, gotContactsConsent uuid.UUID
		var gotDigest []byte
		var state string
		e := tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, request).Scan(&gotContact, &gotChatConsent, &gotContactsConsent, &gotDigest, &state)
		if errors.Is(e, pgx.ErrNoRows) {
			changed = true
			return nil
		}
		if e != nil {
			return e
		}
		if gotContact != contact || gotChatConsent != chatConsent || gotContactsConsent != contactsConsent || !bytes.Equal(gotDigest, digest) || state != "processing" {
			changed = true
			return invalidateInference(ctx, tx, u, request)
		}
		activeChat, e := activeConsent(ctx, tx, u, "chat_import")
		if errors.Is(e, membership.ErrForbidden) || e == nil && activeChat != gotChatConsent {
			changed = true
			return invalidateInference(ctx, tx, u, request)
		}
		if e != nil {
			return e
		}
		activeContacts, e := activeConsent(ctx, tx, u, "contacts")
		if errors.Is(e, membership.ErrForbidden) || e == nil && activeContacts != gotContactsConsent {
			changed = true
			return invalidateInference(ctx, tx, u, request)
		}
		if e != nil {
			return e
		}
		if e := authorize(tx); e != nil {
			if !errors.Is(e, membership.ErrForbidden) {
				return e
			}
			changed = true
			return invalidateInference(ctx, tx, u, request)
		}
		return nil
	})
	if e != nil {
		return e
	}
	if changed {
		return membership.ErrConflict
	}
	return nil
}

func invalidateInference(ctx context.Context, tx pgx.Tx, u, request uuid.UUID) error {
	_, e := tx.Exec(ctx, `update profile_inference_requests set state='invalidated',updated_at=clock_timestamp() where user_id=$1 and request_id=$2 and state='processing'`, u, request)
	return e
}

func completeInference(ctx context.Context, tx pgx.Tx, u, request uuid.UUID) error {
	tag, e := tx.Exec(ctx, `update profile_inference_requests set state='complete',updated_at=clock_timestamp() where user_id=$1 and request_id=$2 and state='processing'`, u, request)
	if e == nil && tag.RowsAffected() != 1 {
		return membership.ErrConflict
	}
	return e
}

// discardInference releases a transiently failed attempt so the same request ID
// can be retried. Authorization changes use invalidateInference instead.
func discardInference(ctx context.Context, tx pgx.Tx, u, request uuid.UUID) error {
	_, e := tx.Exec(ctx, `delete from profile_inference_requests where user_id=$1 and request_id=$2 and state='processing'`, u, request)
	return e
}
