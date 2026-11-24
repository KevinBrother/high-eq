package profile

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// expiredProcessingFixture models one persisted reservation whose execution
// boundary has passed. It deliberately exposes the owner/lease columns only
// when the production query requests them, so the regression proves the
// reservation SQL actually observes the strict execution boundary.
type expiredProcessingFixture struct {
	pgx.Tx
	contact, chatConsent, contactsConsent uuid.UUID
	digest                                []byte
	owner                                 uuid.UUID
	leaseExpired                          bool
	invalidated                           bool
	executed                              int
}

func (f *expiredProcessingFixture) QueryRow(_ context.Context, q string, _ ...any) pgx.Row {
	if !strings.Contains(q, "from profile_inference_requests") {
		return scanFn(func(...any) error { return errors.New("unexpected recovery query") })
	}
	return scanFn(func(out ...any) error {
		*out[0].(*uuid.UUID) = f.contact
		*out[1].(*uuid.UUID) = f.chatConsent
		*out[2].(*uuid.UUID) = f.contactsConsent
		*out[3].(*[]byte) = append([]byte(nil), f.digest...)
		*out[4].(*string) = "processing"
		if len(out) >= 7 {
			*out[5].(*uuid.NullUUID) = uuid.NullUUID{UUID: f.owner, Valid: true}
			*out[6].(*bool) = f.leaseExpired
		}
		return nil
	})
}

func (f *expiredProcessingFixture) Exec(_ context.Context, q string, args ...any) (pgconn.CommandTag, error) {
	if strings.Contains(q, "set state='invalidated'") {
		if args[3] != (uuid.NullUUID{UUID: f.owner, Valid: true}) {
			return pgconn.CommandTag{}, errors.New("invalidating the wrong owner")
		}
		f.invalidated = true
		return pgconn.NewCommandTag("UPDATE 1"), nil
	}
	if !strings.Contains(q, "set state='processing'") ||
		!strings.Contains(q, "lease_expires_at<=clock_timestamp()") ||
		args[6] != "processing" || args[7] != (uuid.NullUUID{UUID: f.owner, Valid: true}) {
		return pgconn.CommandTag{}, errors.New("expired execution must be reclaimed, not appended")
	}
	if !f.leaseExpired {
		return pgconn.NewCommandTag("UPDATE 0"), nil
	}
	f.executed++
	f.owner = args[4].(uuid.UUID)
	return pgconn.NewCommandTag("UPDATE 1"), nil
}

func TestExpiredProcessingReservationCanBeReclaimed(t *testing.T) {
	user, contact, request := uuid.New(), uuid.New(), uuid.New()
	chatConsent, contactsConsent := uuid.New(), uuid.New()
	digest := inputDigest("synthetic recovery material")
	previousOwner := uuid.New()
	f := &expiredProcessingFixture{
		contact: contact, chatConsent: chatConsent, contactsConsent: contactsConsent,
		digest: digest, owner: previousOwner, leaseExpired: true,
	}

	got, err := reserveInference(context.Background(), f, user, contact, request, chatConsent, contactsConsent, digest)
	if errors.Is(err, ErrInferencePending) {
		t.Fatal("expired processing reservation remained permanently pending")
	}
	if err != nil || got.state != "processing" || got.owner == uuid.Nil || got.owner == previousOwner || f.executed != 1 {
		t.Fatalf("reclaimed reservation=%+v err=%v updates=%d previous_owner=%s", got, err, f.executed, previousOwner)
	}
}

func TestExpiredProcessingWithRenewedConsentStaysInvalidated(t *testing.T) {
	user, contact, request := uuid.New(), uuid.New(), uuid.New()
	chatConsent, contactsConsent := uuid.New(), uuid.New()
	digest := inputDigest("synthetic recovery material")
	f := &expiredProcessingFixture{
		contact: contact, chatConsent: chatConsent, contactsConsent: contactsConsent,
		digest: digest, owner: uuid.New(), leaseExpired: true,
	}
	got, err := reserveInference(t.Context(), f, user, contact, request, uuid.New(), contactsConsent, digest)
	if err != nil || got.state != "invalidated" || !f.invalidated || f.executed != 0 {
		t.Fatalf("expired request with replaced grant: state=%q, invalidated=%t, claims=%d, err=%v",
			got.state, f.invalidated, f.executed, err)
	}
}
