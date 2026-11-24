package profile

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"

	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
)

type inferenceAttemptFixture struct {
	pgx.Tx
	contact, consent, contactsConsent uuid.UUID
	activeChat, activeContacts        uuid.UUID
	digest                            []byte
	state                             string
	owner                             uuid.NullUUID
	expired                           bool
	invalidated                       bool
}

func (f *inferenceAttemptFixture) QueryRow(ctx context.Context, q string, args ...any) pgx.Row {
	ctxErr := ctx.Err()
	return scanFn(func(out ...any) error {
		if ctxErr != nil {
			return ctxErr
		}
		switch {
		case strings.Contains(q, "from profile_inference_requests"):
			*out[0].(*uuid.UUID) = f.contact
			*out[1].(*uuid.UUID) = f.consent
			*out[2].(*uuid.UUID) = f.contactsConsent
			*out[3].(*[]byte) = append([]byte(nil), f.digest...)
			*out[4].(*string) = f.state
			*out[5].(*uuid.NullUUID) = f.owner
			*out[6].(*bool) = f.expired
			return nil
		case strings.Contains(q, "select exists(select from consents"):
			active := f.activeChat
			if len(args) > 1 && args[1] == "contacts" {
				active = f.activeContacts
			}
			*out[0].(*bool) = active != uuid.Nil
			return nil
		case strings.Contains(q, "select id from consents"):
			active := f.activeChat
			if len(args) > 1 && args[1] == "contacts" {
				active = f.activeContacts
			}
			if active == uuid.Nil {
				return pgx.ErrNoRows
			}
			*out[0].(*uuid.UUID) = active
			return nil
		case strings.Contains(q, "from users u"):
			*out[0].(*string) = "Asia/Shanghai"
			_ = out[1].(*pgtype.Range[time.Time])
			return nil
		case strings.Contains(q, "select exists(select from (select id from contacts"):
			*out[0].(*bool) = true
			return nil
		default:
			return errors.New("unexpected inference-attempt query")
		}
	})
}

func (f *inferenceAttemptFixture) Exec(ctx context.Context, q string, _ ...any) (pgconn.CommandTag, error) {
	if err := ctx.Err(); err != nil {
		return pgconn.CommandTag{}, err
	}
	if strings.Contains(q, "state='invalidated'") {
		f.invalidated = true
		return pgconn.NewCommandTag("UPDATE 1"), nil
	}
	if strings.Contains(q, "insert into ai_calls synthetic") {
		return pgconn.NewCommandTag("INSERT 0 1"), nil
	}
	return pgconn.CommandTag{}, errors.New("unexpected inference-attempt write")
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
			owner := uuid.New()
			activeContacts := contactsConsent
			if tc.withdrawContacts {
				activeContacts = uuid.Nil
			}
			if tc.regrantContacts {
				activeContacts = uuid.New()
			}
			f := &inferenceAttemptFixture{contact: contact, consent: consent, contactsConsent: contactsConsent, activeChat: tc.active, activeContacts: activeContacts, state: tc.state, digest: tc.digest, owner: uuid.NullUUID{UUID: owner, Valid: true}}
			sent := 0
			changed, err := checkInferenceAttemptTx(context.Background(), f, user, contact, request, consent, contactsConsent, digest, owner, func(pgx.Tx) error { return nil }, func(pgx.Tx) error {
				sent++
				return nil
			})
			if changed && err == nil {
				err = membership.ErrConflict
			}
			wantSent := 0
			if tc.wantErr == nil {
				wantSent = 1
			}
			if !errors.Is(err, tc.wantErr) || f.invalidated != tc.invalidated || sent != wantSent {
				t.Fatalf("err=%v invalidated=%v sent=%d want=%v/%v/%d", err, f.invalidated, sent, tc.wantErr, tc.invalidated, wantSent)
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
			owner := uuid.New()
			f := &inferenceAttemptFixture{contact: contact, consent: consent, contactsConsent: contactsConsent, activeChat: consent, activeContacts: contactsConsent, state: "processing", digest: digest, owner: uuid.NullUUID{UUID: owner, Valid: true}}
			authorized := 0
			sent := 0
			changed, err := checkInferenceAttemptTx(context.Background(), f, user, contact, request, consent, f.contactsConsent, digest, owner, func(pgx.Tx) error {
				authorized++
				return tc.authorize
			}, func(pgx.Tx) error {
				sent++
				return nil
			})
			if changed && err == nil {
				err = membership.ErrConflict
			}
			if authorized != 1 || sent != 0 {
				t.Fatalf("authorization checks=%d sends=%d want 1/0", authorized, sent)
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

func TestSupersededInferenceOwnerCannotInvalidateReplacement(t *testing.T) {
	user, contact, request, consent := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	contactsConsent := uuid.New()
	digest := inputDigest("synthetic material")
	for _, tc := range []struct {
		name    string
		owner   uuid.NullUUID
		expired bool
	}{
		{name: "new owner", owner: uuid.NullUUID{UUID: uuid.New(), Valid: true}},
		{name: "expired owner", owner: uuid.NullUUID{UUID: uuid.New(), Valid: true}, expired: true},
		{name: "released owner", owner: uuid.NullUUID{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := &inferenceAttemptFixture{contact: contact, consent: consent, contactsConsent: contactsConsent, activeChat: consent, activeContacts: contactsConsent, state: "processing", digest: digest, owner: tc.owner, expired: tc.expired}
			sent := 0
			changed, err := checkInferenceAttemptTx(context.Background(), f, user, contact, request, consent, contactsConsent, digest, uuid.New(), func(pgx.Tx) error { return nil }, func(pgx.Tx) error {
				sent++
				return nil
			})
			if changed && err == nil {
				err = membership.ErrConflict
			}
			if sent != 0 {
				t.Fatalf("sent=%d want no provider dispatch", sent)
			}
			if !errors.Is(err, membership.ErrConflict) || f.invalidated {
				t.Fatalf("err=%v invalidated=%v want stale conflict without replacement write", err, f.invalidated)
			}
		})
	}
}

func TestInferenceAttemptSendsOnlyAfterAuthorizationInTheSameTransaction(t *testing.T) {
	user, contact, request, consent := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	contactsConsent := uuid.New()
	digest := inputDigest("synthetic material")
	owner := uuid.New()
	f := &inferenceAttemptFixture{
		contact: contact, consent: consent, contactsConsent: contactsConsent,
		activeChat: consent, activeContacts: contactsConsent, state: "processing", digest: digest,
		owner: uuid.NullUUID{UUID: owner, Valid: true},
	}
	var order []string
	changed, err := checkInferenceAttemptTx(context.Background(), f, user, contact, request, consent, contactsConsent, digest, owner, func(tx pgx.Tx) error {
		if tx != f {
			t.Fatal("authorization did not receive the guarded transaction")
		}
		order = append(order, "authorize")
		return nil
	}, func(tx pgx.Tx) error {
		if tx != f {
			t.Fatal("provider send did not receive the guarded transaction")
		}
		order = append(order, "send")
		return nil
	})
	if err != nil || changed || !reflect.DeepEqual(order, []string{"authorize", "send"}) {
		t.Fatalf("changed=%v err=%v order=%v", changed, err, order)
	}
}

func TestInferenceAuthorizerRejectsCanceledEntryWithoutSessionOrDispatch(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	sessions, sends := 0, 0
	s := &Service{}
	auth := s.inferenceAuthorizer(func(context.Context, func(pgx.Tx) error) error {
		sessions++
		return nil
	}, uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New(), inputDigest("synthetic material"), uuid.New())
	err := auth(ctx, nil, func(context.Context, pgx.Tx) error {
		sends++
		return nil
	})
	if !errors.Is(err, context.Canceled) || sessions != 0 || sends != 0 {
		t.Fatalf("err=%v sessions=%d sends=%d, want canceled/0/0", err, sessions, sends)
	}
}

func TestInferenceAuthorizerKeepsOriginalAttemptContextAndDetachedCommitScope(t *testing.T) {
	user, contact, request := uuid.New(), uuid.New(), uuid.New()
	chatConsent, contactsConsent := uuid.New(), uuid.New()
	digest := inputDigest("synthetic material")
	owner := uuid.New()
	tx := &inferenceAttemptFixture{
		contact: contact, consent: chatConsent, contactsConsent: contactsConsent,
		activeChat: chatConsent, activeContacts: contactsConsent, state: "processing", digest: digest,
		owner: uuid.NullUUID{UUID: owner, Valid: true},
	}
	rights, err := membership.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	s := &Service{Rights: rights}
	attemptCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sessions, sends, auditWrites := 0, 0, 0
	var sessionErr, providerErr error
	auth := s.inferenceAuthorizer(func(sessionCtx context.Context, fn func(pgx.Tx) error) error {
		sessions++
		if _, ok := sessionCtx.Deadline(); !ok {
			t.Fatal("authorization session has no deadline")
		}
		sessionErr = sessionCtx.Err()
		return fn(tx)
	}, user, contact, request, chatConsent, contactsConsent, digest, owner)
	err = auth(attemptCtx, nil, func(sendCtx context.Context, guarded pgx.Tx) error {
		sends++
		providerErr = sendCtx.Err()
		if sendCtx != attemptCtx {
			t.Fatalf("provider context was replaced: got %p want %p", sendCtx, attemptCtx)
		}
		// The adapter has returned. Cancel the caller immediately before the
		// transaction-backed audit write, matching the late-cancel boundary.
		cancel()
		if _, err := guarded.Exec(sendCtx, `insert into ai_calls synthetic`); err != nil {
			return err
		}
		auditWrites++
		return nil
	})
	if err != nil || sessionErr != nil || providerErr != nil || sessions != 1 || sends != 1 || auditWrites != 1 {
		t.Fatalf("err=%v sessionErr=%v providerErr=%v sessions=%d sends=%d audits=%d", err, sessionErr, providerErr, sessions, sends, auditWrites)
	}
}

func TestInferenceControlContextSurvivesCancellationWithDeadline(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	cancel()
	ctx, done := inferenceControlContext(parent)
	defer done()
	deadline, ok := ctx.Deadline()
	if ctx.Err() != nil || !ok {
		t.Fatalf("control context err=%v deadline=%v, want detached bounded context", ctx.Err(), ok)
	}
	remaining := time.Until(deadline)
	if remaining <= gateway.ExecutionLimit || remaining > gateway.ExecutionLimit+inferenceControlGrace {
		t.Fatalf("control deadline remaining=%s, want (%s,%s]", remaining, gateway.ExecutionLimit, gateway.ExecutionLimit+inferenceControlGrace)
	}
}

func TestSettleInferenceRunDetachesCleanupFromCancellation(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	cancel()
	user, contact, request, owner := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	cleanups := 0
	detached := false
	var gotUser, gotContact, gotRequest, gotOwner uuid.UUID
	cleanup := func(ctx context.Context, u, c, r, o uuid.UUID) error {
		cleanups++
		detached = ctx.Err() == nil
		if _, ok := ctx.Deadline(); !ok {
			return errors.New("cleanup context has no deadline")
		}
		gotUser, gotContact, gotRequest, gotOwner = u, c, r, o
		return nil
	}
	cause := context.Canceled
	got, done, err := (&Service{}).settleInferenceRun(parent, cleanup, user, contact, request, owner, gateway.Reply{}, cause)
	if got != nil || !done || !errors.Is(err, cause) || !detached || cleanups != 1 || gotUser != user || gotContact != contact || gotRequest != request || gotOwner != owner {
		t.Fatalf("got=%v done=%v err=%v detached=%v cleanups=%d ids=%s/%s/%s/%s", got, done, err, detached, cleanups, gotUser, gotContact, gotRequest, gotOwner)
	}
}

func TestSettleInferenceRunJoinsCleanupFailureForRetryableCause(t *testing.T) {
	cause := errors.New("audit unavailable")
	cleanupErr := errors.New("cleanup unavailable")
	cleanup := func(context.Context, uuid.UUID, uuid.UUID, uuid.UUID, uuid.UUID) error { return cleanupErr }
	got, done, err := (&Service{}).settleInferenceRun(context.Background(), cleanup, uuid.New(), uuid.New(), uuid.New(), uuid.New(), gateway.Reply{}, cause)
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
			cleanup := func(ctx context.Context, _, _, _, _ uuid.UUID) error {
				cleanups++
				if ctx.Err() != nil {
					return ctx.Err()
				}
				if tc.cleanupFail {
					return errors.New("cleanup unavailable")
				}
				return nil
			}
			got, done, err := (&Service{}).settleInferenceRun(parent, cleanup, uuid.New(), uuid.New(), uuid.New(), uuid.New(), gateway.Reply{Terminal: tc.terminal}, errors.New("synthetic audit failure"))
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
	owner                                 uuid.NullUUID
	expired                               bool
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
		*out[5].(*uuid.NullUUID) = f.owner
		*out[6].(*bool) = f.expired
		return nil
	})
}

func (f *inferenceReservationFixture) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	return pgconn.CommandTag{}, errors.New("existing request must not be inserted again")
}

type retryableInferenceFixture struct {
	*inferenceReservationFixture
}

func (f retryableInferenceFixture) Exec(_ context.Context, q string, args ...any) (pgconn.CommandTag, error) {
	if !strings.Contains(q, "set state='processing'") || !strings.Contains(q, "and state=$7") ||
		args[6] != "retryable" || args[7] != (uuid.NullUUID{}) {
		return pgconn.CommandTag{}, errors.New("retry must reclaim the existing request")
	}
	if f.state != "retryable" {
		return pgconn.NewCommandTag("UPDATE 0"), nil
	}
	f.state = "processing"
	f.chatConsent = args[2].(uuid.UUID)
	f.contactsConsent = args[3].(uuid.UUID)
	f.owner = uuid.NullUUID{UUID: args[4].(uuid.UUID), Valid: true}
	f.expired = false
	return pgconn.NewCommandTag("UPDATE 1"), nil
}

func TestFailedInferenceKeepsItsMaterialBinding(t *testing.T) {
	ctx := context.Background()
	user, contact, request := uuid.New(), uuid.New(), uuid.New()
	chatConsent, contactsConsent := uuid.New(), uuid.New()
	original := inputDigest("original synthetic material")
	tx := retryableInferenceFixture{&inferenceReservationFixture{
		contact: contact, digest: original, state: "retryable",
		chatConsent: uuid.New(), contactsConsent: uuid.New(),
	}}
	reserve := func(id uuid.UUID, digest []byte) (inferenceReservation, error) {
		return reserveInference(ctx, tx, user, id, request, chatConsent, contactsConsent, digest)
	}
	if _, err := reserve(contact, inputDigest("replacement synthetic material")); !errors.Is(err, membership.ErrConflict) {
		t.Fatalf("replacement material: got %v, want conflict", err)
	}
	if _, err := reserve(uuid.New(), original); !errors.Is(err, membership.ErrConflict) {
		t.Fatalf("replacement contact: got %v, want conflict", err)
	}
	got, err := reserve(contact, original)
	if err != nil || got.state != "processing" || got.chatConsent != chatConsent || got.contactsConsent != contactsConsent {
		t.Fatalf("original material did not reclaim the attempt with current consent: %+v, %v", got, err)
	}
	if _, err := reserve(contact, original); !errors.Is(err, ErrInferencePending) {
		t.Fatalf("in-flight retry: got %v, want pending", err)
	}
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
