package profile

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
)

type inferenceAttemptFixture struct {
	pgx.Tx
	contact, consent, contactsConsent uuid.UUID
	activeChat, activeContacts        uuid.UUID
	digest                            []byte
	state                             string
	invalidated                       bool
}

func (f *inferenceAttemptFixture) QueryRow(_ context.Context, q string, args ...any) pgx.Row {
	return scanFn(func(out ...any) error {
		switch {
		case strings.Contains(q, "from profile_inference_requests"):
			*out[0].(*uuid.UUID) = f.contact
			*out[1].(*uuid.UUID) = f.consent
			if len(out) == 4 {
				*out[2].(*[]byte) = append([]byte(nil), f.digest...)
				*out[3].(*string) = f.state
				return nil
			}
			*out[2].(*uuid.UUID) = f.contactsConsent
			*out[3].(*[]byte) = append([]byte(nil), f.digest...)
			*out[4].(*string) = f.state
			return nil
		case strings.Contains(q, "from consents"):
			active := f.activeChat
			if len(args) > 1 && args[1] == "contacts" {
				active = f.activeContacts
			}
			if active == uuid.Nil {
				return pgx.ErrNoRows
			}
			*out[0].(*uuid.UUID) = active
			return nil
		default:
			return errors.New("unexpected inference-attempt query")
		}
	})
}

func (f *inferenceAttemptFixture) Exec(_ context.Context, q string, _ ...any) (pgconn.CommandTag, error) {
	if !strings.Contains(q, "state='invalidated'") {
		return pgconn.CommandTag{}, errors.New("unexpected inference-attempt write")
	}
	f.invalidated = true
	return pgconn.NewCommandTag("UPDATE 1"), nil
}

func TestInferenceAttemptRequiresUnchangedConsent(t *testing.T) {
	user, contact, request, consent := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	digest := inputDigest("synthetic material")
	contactsConsent := uuid.New()
	for _, tc := range []struct {
		name             string
		active           uuid.UUID
		withdrawContacts bool
		regrantContacts  bool
		state            string
		digest           []byte
		wantErr          error
		invalidated      bool
	}{
		{name: "active consent", active: consent, state: "processing", digest: digest},
		{name: "withdrawn", active: uuid.Nil, state: "processing", digest: digest, wantErr: membership.ErrConflict, invalidated: true},
		{name: "regranted", active: uuid.New(), state: "processing", digest: digest, wantErr: membership.ErrConflict, invalidated: true},
		{name: "contacts withdrawn", active: consent, withdrawContacts: true, state: "processing", digest: digest, wantErr: membership.ErrConflict, invalidated: true},
		{name: "contacts regranted", active: consent, regrantContacts: true, state: "processing", digest: digest, wantErr: membership.ErrConflict, invalidated: true},
		{name: "already complete", active: consent, state: "complete", digest: digest, wantErr: membership.ErrConflict, invalidated: true},
		{name: "different input", active: consent, state: "processing", digest: inputDigest("different synthetic material"), wantErr: membership.ErrConflict, invalidated: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			activeContacts := contactsConsent
			if tc.withdrawContacts {
				activeContacts = uuid.Nil
			}
			if tc.regrantContacts {
				activeContacts = uuid.New()
			}
			f := &inferenceAttemptFixture{contact: contact, consent: consent, contactsConsent: contactsConsent, activeChat: tc.active, activeContacts: activeContacts, state: tc.state, digest: tc.digest}
			session := func(_ context.Context, fn func(pgx.Tx) error) error { return fn(f) }
			err := checkInferenceAttempt(context.Background(), session, user, contact, request, consent, contactsConsent, digest, func(pgx.Tx) error { return nil })
			if !errors.Is(err, tc.wantErr) || f.invalidated != tc.invalidated {
				t.Fatalf("err=%v invalidated=%v want=%v/%v", err, f.invalidated, tc.wantErr, tc.invalidated)
			}
		})
	}
	if bytes.Equal(inputDigest("a"), inputDigest("b")) {
		t.Fatal("input digests must differ")
	}
}

func TestInferenceAttemptRequiresContactsAndUsableContact(t *testing.T) {
	user, contact, request, consent := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	digest := inputDigest("synthetic material")
	for _, tc := range []struct {
		name        string
		authorize   error
		wantErr     error
		invalidated bool
	}{
		{name: "contacts consent withdrawn", authorize: fmt.Errorf("contacts consent: %w", membership.ErrForbidden), wantErr: membership.ErrConflict, invalidated: true},
		{name: "contact no longer writable", authorize: fmt.Errorf("contact access: %w", membership.ErrForbidden), wantErr: membership.ErrConflict, invalidated: true},
		{name: "transient authorization failure", authorize: errors.New("authorization store unavailable")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			contactsConsent := uuid.New()
			f := &inferenceAttemptFixture{contact: contact, consent: consent, contactsConsent: contactsConsent, activeChat: consent, activeContacts: contactsConsent, state: "processing", digest: digest}
			session := func(_ context.Context, fn func(pgx.Tx) error) error { return fn(f) }
			authorized := 0
			err := checkInferenceAttempt(context.Background(), session, user, contact, request, consent, f.contactsConsent, digest, func(pgx.Tx) error {
				authorized++
				return tc.authorize
			})
			if authorized != 1 {
				t.Fatalf("authorization checks=%d want 1", authorized)
			}
			if tc.invalidated {
				if !errors.Is(err, membership.ErrConflict) || !f.invalidated {
					t.Fatalf("err=%v invalidated=%v want conflict/invalidated", err, f.invalidated)
				}
				return
			}
			if !errors.Is(err, tc.authorize) || f.invalidated {
				t.Fatalf("err=%v invalidated=%v want transient error without invalidation", err, f.invalidated)
			}
		})
	}
}

func TestSettleInferenceRunDetachesCleanupFromCancellation(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	cancel()
	user, request := uuid.New(), uuid.New()
	cleanups := 0
	detached := false
	var gotUser, gotRequest uuid.UUID
	cleanup := func(ctx context.Context, u, r uuid.UUID) error {
		cleanups++
		detached = ctx.Err() == nil
		if _, ok := ctx.Deadline(); !ok {
			return errors.New("cleanup context has no deadline")
		}
		gotUser, gotRequest = u, r
		return nil
	}
	cause := context.Canceled
	got, done, err := (&Service{}).settleInferenceRun(parent, cleanup, user, request, gateway.Reply{}, cause)
	if got != nil || !done || !errors.Is(err, cause) || !detached || cleanups != 1 || gotUser != user || gotRequest != request {
		t.Fatalf("got=%v done=%v err=%v detached=%v cleanups=%d ids=%s/%s", got, done, err, detached, cleanups, gotUser, gotRequest)
	}
}

func TestSettleInferenceRunJoinsCleanupFailureForRetryableCause(t *testing.T) {
	cause := errors.New("audit unavailable")
	cleanupErr := errors.New("cleanup unavailable")
	cleanup := func(context.Context, uuid.UUID, uuid.UUID) error { return cleanupErr }
	got, done, err := (&Service{}).settleInferenceRun(context.Background(), cleanup, uuid.New(), uuid.New(), gateway.Reply{}, cause)
	if got != nil || !done || !errors.Is(err, cause) || !errors.Is(err, cleanupErr) {
		t.Fatalf("got=%v done=%v err=%v want joined retryable causes", got, done, err)
	}
}

func TestSettleInferenceRunKeepsTerminalSemantics(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	cancel()
	for _, tc := range []struct {
		name        string
		terminal    *gateway.Terminal
		cleanupFail bool
	}{
		{name: "crisis with audit failure", terminal: &gateway.Terminal{Safety: true, Message: gateway.HelpMessage}},
		{name: "moderation unavailable with audit failure", terminal: &gateway.Terminal{Code: "moderation_unavailable", Retryable: true}},
		{name: "crisis with cleanup failure", terminal: &gateway.Terminal{Safety: true, Message: gateway.HelpMessage}, cleanupFail: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cleanups := 0
			cleanup := func(ctx context.Context, _ uuid.UUID, _ uuid.UUID) error {
				cleanups++
				if ctx.Err() != nil {
					return ctx.Err()
				}
				if tc.cleanupFail {
					return errors.New("cleanup unavailable")
				}
				return nil
			}
			got, done, err := (&Service{}).settleInferenceRun(parent, cleanup, uuid.New(), uuid.New(), gateway.Reply{Terminal: tc.terminal}, errors.New("synthetic audit failure"))
			if !done || err != nil || got != tc.terminal || cleanups != 1 {
				t.Fatalf("got=%v done=%v err=%v cleanups=%d want terminal=%v", got, done, err, cleanups, tc.terminal)
			}
		})
	}
}

type inferenceReservationFixture struct {
	pgx.Tx
	contact, chatConsent, contactsConsent uuid.UUID
	digest                                []byte
	state                                 string
}

func (f *inferenceReservationFixture) QueryRow(_ context.Context, q string, _ ...any) pgx.Row {
	if !strings.Contains(q, "from profile_inference_requests") {
		return scanFn(func(...any) error { return errors.New("unexpected inference-reservation query") })
	}
	return scanFn(func(out ...any) error {
		*out[0].(*uuid.UUID) = f.contact
		*out[1].(*uuid.UUID) = f.chatConsent
		*out[2].(*uuid.UUID) = f.contactsConsent
		*out[3].(*[]byte) = append([]byte(nil), f.digest...)
		*out[4].(*string) = f.state
		return nil
	})
}

func (f *inferenceReservationFixture) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, errors.New("existing request must not be inserted again")
}

func TestReserveInferenceTerminalStates(t *testing.T) {
	ctx := context.Background()
	user, contact, request := uuid.New(), uuid.New(), uuid.New()
	chatConsent, contactsConsent := uuid.New(), uuid.New()
	digest := inputDigest("same synthetic material")
	for _, tc := range []struct {
		name      string
		contact   uuid.UUID
		digest    []byte
		state     string
		wantState string
		wantErr   error
	}{
		{name: "complete", contact: contact, digest: digest, state: "complete", wantState: "complete"},
		{name: "processing", contact: contact, digest: digest, state: "processing", wantErr: ErrInferencePending},
		{name: "invalidated", contact: contact, digest: digest, state: "invalidated", wantErr: membership.ErrConflict},
		{name: "different input", contact: contact, digest: inputDigest("different synthetic material"), state: "complete", wantErr: membership.ErrConflict},
		{name: "different contact", contact: uuid.New(), digest: digest, state: "complete", wantErr: membership.ErrConflict},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &inferenceReservationFixture{contact: tc.contact, chatConsent: chatConsent, contactsConsent: contactsConsent, digest: tc.digest, state: tc.state}
			got, err := reserveInference(ctx, f, user, contact, request, chatConsent, contactsConsent, digest)
			if !errors.Is(err, tc.wantErr) || got.state != tc.wantState || tc.wantErr == nil && (got.chatConsent != chatConsent || got.contactsConsent != contactsConsent) {
				t.Fatalf("reservation=%+v err=%v want state=%q consent=%s/%s err=%v", got, err, tc.wantState, chatConsent, contactsConsent, tc.wantErr)
			}
		})
	}
}
