package profile

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
)

var ErrInferencePending = errors.New("profile inference pending")

// A reservation remains owned for the gateway's outer execution limit plus the
// bounded best-effort cleanup window. The lease is longer than the provider
// boundary, so a healthy executor cannot overlap a retry; after a crash or lost
// cleanup it still becomes reclaimable without operator intervention.
const inferenceLeaseSeconds = int(gateway.ExecutionLimit/time.Second) + 10

type inferenceReservation struct {
	owner           uuid.UUID
	chatConsent     uuid.UUID
	contactsConsent uuid.UUID
	digest          []byte
	state           string
}

type inferenceRecord struct {
	contact, chatConsent, contactsConsent uuid.UUID
	digest                                []byte
	state                                 string
	owner                                 uuid.NullUUID
	expired                               bool
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

func scanInferenceRecord(row pgx.Row) (inferenceRecord, error) {
	var got inferenceRecord
	e := row.Scan(&got.contact, &got.chatConsent, &got.contactsConsent, &got.digest, &got.state, &got.owner, &got.expired)
	return got, e
}

func claimInference(ctx context.Context, tx pgx.Tx, u, request, chatConsent, contactsConsent uuid.UUID, fromState string, expectedOwner uuid.NullUUID) (uuid.UUID, error) {
	owner := uuid.New()
	tag, e := tx.Exec(ctx, `update profile_inference_requests
		set state='processing',chat_consent_id=$3,contacts_consent_id=$4,owner_id=$5,
		    lease_expires_at=clock_timestamp()+make_interval(secs => $6),updated_at=clock_timestamp()
		where user_id=$1 and request_id=$2 and state=$7 and owner_id is not distinct from $8::uuid
		  and ($7<>'processing' or lease_expires_at is null or lease_expires_at<=clock_timestamp())`,
		u, request, chatConsent, contactsConsent, owner, inferenceLeaseSeconds, fromState, expectedOwner)
	if e != nil {
		return uuid.Nil, e
	}
	if tag.RowsAffected() != 1 {
		return uuid.Nil, membership.ErrConflict
	}
	return owner, nil
}

// reserveInference creates or classifies the account-scoped idempotency row.
// A completed request is never regenerated; callers return the current profile.
// Processing rows remain pending until their persisted execution lease expires,
// then the same bound material and current consents can atomically replace the
// previous owner.
func reserveInference(ctx context.Context, tx pgx.Tx, u, contact, request, chatConsent, contactsConsent uuid.UUID, digest []byte) (inferenceReservation, error) {
	gotRecord, e := scanInferenceRecord(tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state,owner_id,
 coalesce(lease_expires_at<=clock_timestamp(),true)
 from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, request))
	if errors.Is(e, pgx.ErrNoRows) {
		owner := uuid.New()
		// Historical attempts without a binding have no verifiable input.
		// Keep those keys read-only so a new operation cannot join their group.
		tag, e := tx.Exec(ctx, `insert into profile_inference_requests(user_id,request_id,contact_id,chat_consent_id,contacts_consent_id,input_digest,owner_id,lease_expires_at)
			select $1::uuid,$2::uuid,$3::uuid,$4::uuid,$5::uuid,$6::bytea,$7::uuid,
			       clock_timestamp()+make_interval(secs => $8)
			where not exists(select 1 from ai_calls where user_id=$1 and operation_id=$2 and task='profile_inference')
			on conflict(user_id,request_id) do nothing`, u, request, contact, chatConsent, contactsConsent, digest, owner, inferenceLeaseSeconds)
		if e != nil {
			return inferenceReservation{}, e
		}
		if tag.RowsAffected() == 1 {
			return inferenceReservation{owner: owner, chatConsent: chatConsent, contactsConsent: contactsConsent, digest: digest, state: "processing"}, nil
		}
		// Re-read a concurrent first attempt, if any.
		gotRecord, e = scanInferenceRecord(tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state,owner_id,
 coalesce(lease_expires_at<=clock_timestamp(),true)
 from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, request))
		if errors.Is(e, pgx.ErrNoRows) {
			return inferenceReservation{}, membership.ErrConflict
		}
		if e != nil {
			return inferenceReservation{}, e
		}
	} else if e != nil {
		return inferenceReservation{}, e
	}
	if gotRecord.contact != contact || !bytes.Equal(gotRecord.digest, digest) {
		return inferenceReservation{}, membership.ErrConflict
	}
	got := inferenceReservation{
		owner: gotRecord.owner.UUID, chatConsent: gotRecord.chatConsent,
		contactsConsent: gotRecord.contactsConsent, digest: gotRecord.digest, state: gotRecord.state,
	}
	switch gotRecord.state {
	case "processing":
		if !gotRecord.expired {
			return inferenceReservation{}, ErrInferencePending
		}
		if gotRecord.chatConsent != chatConsent || gotRecord.contactsConsent != contactsConsent {
			e := invalidateInference(ctx, tx, u, contact, request, gotRecord.owner)
			return inferenceReservation{state: "invalidated"}, e
		}
		owner, e := claimInference(ctx, tx, u, request, chatConsent, contactsConsent, "processing", gotRecord.owner)
		if e != nil {
			return inferenceReservation{}, e
		}
		got.owner, got.chatConsent, got.contactsConsent = owner, chatConsent, contactsConsent
		return got, nil
	case "retryable":
		owner, e := claimInference(ctx, tx, u, request, chatConsent, contactsConsent, "retryable", uuid.NullUUID{})
		if e != nil {
			return inferenceReservation{}, e
		}
		got.owner, got.chatConsent, got.contactsConsent = owner, chatConsent, contactsConsent
		got.state = "processing"
		return got, nil
	case "complete":
		return got, nil
	case "invalidated":
		return inferenceReservation{}, membership.ErrConflict
	default:
		return inferenceReservation{}, errors.New("invalid profile inference state")
	}
}

// checkInferenceAttemptTx revalidates the exact reservation, owner and both
// consent records inside the caller-owned authorization transaction. The send
// callback must dispatch while this transaction still holds the account lock;
// consequently account withdrawal, freeze, erasure registration and owner
// replacement cannot commit between these checks and the provider request.
// A superseded or expired owner is fenced without touching the replacement.
func checkInferenceAttemptTx(ctx context.Context, tx pgx.Tx, u, contact, request, chatConsent, contactsConsent uuid.UUID, digest []byte, owner uuid.UUID, authorize func(pgx.Tx) error, send func(pgx.Tx) error) (bool, error) {
	got, e := scanInferenceRecord(tx.QueryRow(ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,state,owner_id,
 coalesce(lease_expires_at<=clock_timestamp(),true)
 from profile_inference_requests where user_id=$1 and request_id=$2 for update`, u, request))
	if errors.Is(e, pgx.ErrNoRows) {
		return true, nil
	}
	if e != nil {
		return false, e
	}
	if !got.owner.Valid || got.owner.UUID != owner || got.expired {
		return true, nil
	}
	if got.contact != contact || got.chatConsent != chatConsent || got.contactsConsent != contactsConsent || !bytes.Equal(got.digest, digest) || got.state != "processing" {
		return true, invalidateInference(ctx, tx, u, contact, request, got.owner)
	}
	activeChat, e := activeConsent(ctx, tx, u, "chat_import")
	if errors.Is(e, membership.ErrForbidden) || e == nil && activeChat != got.chatConsent {
		return true, invalidateInference(ctx, tx, u, contact, request, got.owner)
	}
	if e != nil {
		return false, e
	}
	activeContacts, e := activeConsent(ctx, tx, u, "contacts")
	if errors.Is(e, membership.ErrForbidden) || e == nil && activeContacts != got.contactsConsent {
		return true, invalidateInference(ctx, tx, u, contact, request, got.owner)
	}
	if e != nil {
		return false, e
	}
	if e := authorize(tx); e != nil {
		if !errors.Is(e, membership.ErrForbidden) {
			return false, e
		}
		return true, invalidateInference(ctx, tx, u, contact, request, got.owner)
	}
	if e := send(tx); e != nil {
		return false, e
	}
	return false, nil
}

func invalidateInference(ctx context.Context, tx pgx.Tx, u, contact, request uuid.UUID, owner uuid.NullUUID) error {
	_, e := tx.Exec(ctx, `update profile_inference_requests
		set state='invalidated',owner_id=null,lease_expires_at=null,updated_at=clock_timestamp()
		where user_id=$1 and request_id=$2 and contact_id=$3 and state='processing'
		  and owner_id is not distinct from $4::uuid`, u, request, contact, owner)
	return e
}

func completeInference(ctx context.Context, tx pgx.Tx, u, request, owner uuid.UUID) error {
	tag, e := tx.Exec(ctx, `update profile_inference_requests
		set state='complete',owner_id=null,lease_expires_at=null,updated_at=clock_timestamp()
		where user_id=$1 and request_id=$2 and state='processing' and owner_id=$3
		  and lease_expires_at>clock_timestamp()`, u, request, owner)
	if e == nil && tag.RowsAffected() != 1 {
		return membership.ErrConflict
	}
	return e
}
