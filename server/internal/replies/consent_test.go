package replies

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/membership"
)

type scanFn func(...any) error

func (f scanFn) Scan(out ...any) error { return f(out...) }

type consentQueryTx struct {
	pgx.Tx
	active  map[string]uuid.UUID
	queries []consentQuery
}

type consentQuery struct {
	purpose string
	version string
}

func consentKey(purpose, version string) string {
	if version == "" {
		return purpose
	}
	return purpose + "\x00" + version
}

func (q consentQuery) String() string {
	if q.version == "" {
		return q.purpose
	}
	return q.purpose + "/" + q.version
}

func (f *consentQueryTx) QueryRow(_ context.Context, _ string, args ...any) pgx.Row {
	purpose := args[1].(string)
	version := ""
	if len(args) > 2 {
		version = args[2].(string)
	}
	f.queries = append(f.queries, consentQuery{purpose: purpose, version: version})
	id := f.active[consentKey(purpose, version)]
	if id == uuid.Nil {
		return scanFn(func(...any) error { return pgx.ErrNoRows })
	}
	return scanFn(func(out ...any) error {
		*out[0].(*uuid.UUID) = id
		return nil
	})
}

func TestBoundConsentMustRemainTheSameGrant(t *testing.T) {
	chat, contacts := uuid.New(), uuid.New()
	for _, tc := range []struct {
		name             string
		withContact      bool
		binding          consentBinding
		active           map[string]uuid.UUID
		wantErr          error
		wantContactsRead bool
	}{
		{
			name:             "same contact-bound grants",
			withContact:      true,
			binding:          consentBinding{chat: chat, contacts: &contacts},
			active:           map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat, consentKey("contacts", "2026-11"): contacts},
			wantContactsRead: true,
		},
		{
			name:             "contacts regranted",
			withContact:      true,
			binding:          consentBinding{chat: chat, contacts: &contacts},
			active:           map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat, consentKey("contacts", "2026-11"): uuid.New()},
			wantErr:          ErrBoundConsentExpired,
			wantContactsRead: true,
		},
		{
			name:             "contacts withdrawn",
			withContact:      true,
			binding:          consentBinding{chat: chat, contacts: &contacts},
			active:           map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat},
			wantErr:          ErrBoundConsentExpired,
			wantContactsRead: true,
		},
		{
			name:        "chat regranted",
			withContact: true,
			binding:     consentBinding{chat: chat, contacts: &contacts},
			active:      map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): uuid.New(), consentKey("contacts", "2026-11"): contacts},
			wantErr:     ErrBoundConsentExpired,
		},
		{
			name:    "no contact ignores contacts consent",
			binding: consentBinding{chat: chat},
			active:  map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat},
		},
		{
			name:    "no-contact request cannot smuggle a contacts binding",
			binding: consentBinding{chat: chat, contacts: &contacts},
			active:  map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat, consentKey("contacts", "2026-11"): contacts},
			wantErr: membership.ErrForbidden,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var contact *uuid.UUID
			if tc.withContact {
				id := uuid.New()
				contact = &id
			}
			tx := &consentQueryTx{active: tc.active}
			err := (&Service{}).requireBoundConsent(context.Background(), tx, uuid.New(), contact, tc.binding)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err=%v want=%v", err, tc.wantErr)
			}
			gotContactsRead := len(tx.queries) == 2
			if gotContactsRead != tc.wantContactsRead {
				t.Fatalf("contacts query=%v want=%v queries=%v", gotContactsRead, tc.wantContactsRead, tx.queries)
			}
		})
	}
}

func TestActiveConsentBindingOnlyReadsContactsWhenSelected(t *testing.T) {
	chat, contacts := uuid.New(), uuid.New()
	user := uuid.New()
	for _, tc := range []struct {
		name     string
		contact  *uuid.UUID
		active   map[string]uuid.UUID
		wantErr  error
		wantRead []string
	}{
		{name: "no contact", active: map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat}, wantRead: []string{"reply_chat_import/2026-11-reply"}},
		{name: "selected contact", contact: &contacts, active: map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat, consentKey("contacts", "2026-11"): contacts}, wantRead: []string{"reply_chat_import/2026-11-reply", "contacts/2026-11"}},
		{name: "selected contact lacks consent", contact: &contacts, active: map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat}, wantErr: membership.ErrForbidden, wantRead: []string{"reply_chat_import/2026-11-reply", "contacts/2026-11"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx := &consentQueryTx{active: tc.active}
			_, err := (&Service{}).activeConsentBinding(context.Background(), tx, user, tc.contact)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err=%v want=%v", err, tc.wantErr)
			}
			if len(tx.queries) != len(tc.wantRead) {
				t.Fatalf("queries=%v want=%v", tx.queries, tc.wantRead)
			}
			for i := range tc.wantRead {
				if tx.queries[i].String() != tc.wantRead[i] {
					t.Fatalf("queries=%v want=%v", tx.queries, tc.wantRead)
				}
			}
		})
	}
}

func TestNewReplyKeyRequiresCurrentExpectedDecisions(t *testing.T) {
	chat, contacts, replaced, selected := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	user := uuid.New()
	for _, tc := range []struct {
		name              string
		person, wantReply *uuid.UUID
		wantContacts      *uuid.UUID
		activeReply       uuid.UUID
		activeContacts    uuid.UUID
		wantErr           error
	}{
		{"current reply without contact", nil, &chat, nil, chat, contacts, nil},
		{"both current", &selected, &chat, &contacts, chat, contacts, nil},
		{"same version reply regranted", &selected, &chat, &contacts, replaced, contacts, ErrBoundConsentExpired},
		{"same version contacts regranted", &selected, &chat, &contacts, chat, replaced, ErrBoundConsentExpired},
		{"missing reply expectation", nil, nil, nil, chat, contacts, ErrConsent},
		{"missing contacts expectation", &selected, &chat, nil, chat, contacts, membership.ErrForbidden},
		{"unexpected contacts expectation", nil, &chat, &contacts, chat, contacts, membership.ErrForbidden},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// The transaction double only implements the two authoritative
			// consent reads; any writes here would fail the test.
			tx := &consentQueryTx{active: map[string]uuid.UUID{
				consentKey("reply_chat_import", "2026-11-reply"): tc.activeReply,
				consentKey("contacts", "2026-11"):                tc.activeContacts,
			}}
			got, err := (&Service{}).bindNewConsent(context.Background(), tx, user, tc.person, tc.wantReply, tc.wantContacts)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("err=%v want=%v", err, tc.wantErr)
			}
			if tc.wantErr != nil {
				if got != (consentBinding{}) {
					t.Fatal("denied request returned a usable binding")
				}
				return
			}
			if err = matchExpectedConsent(tc.wantReply, tc.wantContacts, got); err != nil {
				t.Fatal("bound decisions differ from explicit expectation", err)
			}
		})
	}
}

func TestPersistedReplyGrantExpiryDiffersFromInitialDenial(t *testing.T) {
	ctx := context.Background()
	svc := &Service{}
	user, chat, contact := uuid.New(), uuid.New(), uuid.New()
	for _, tc := range []struct {
		name    string
		binding consentBinding
		active  map[string]uuid.UUID
		person  *uuid.UUID
	}{
		{"chat withdrawn", consentBinding{chat: chat}, nil, nil},
		{"chat regranted", consentBinding{chat: chat}, map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): uuid.New()}, nil},
		{"legacy chat grant only", consentBinding{chat: chat}, map[string]uuid.UUID{consentKey("chat_import", "2026-11"): chat}, nil},
		{"reply grant with legacy version", consentBinding{chat: chat}, map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11"): chat}, nil},
		{"contacts withdrawn", consentBinding{chat: chat, contacts: &contact}, map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat}, &contact},
		{"contacts regranted", consentBinding{chat: chat, contacts: &contact}, map[string]uuid.UUID{consentKey("reply_chat_import", "2026-11-reply"): chat, consentKey("contacts", "2026-11"): uuid.New()}, &contact},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := svc.requireBoundConsent(ctx, &consentQueryTx{active: tc.active}, user, tc.person, tc.binding)
			if !errors.Is(err, ErrBoundConsentExpired) {
				t.Fatalf("expected expired persisted authorization, got %v", err)
			}
		})
	}
}

func TestContactChatGrantCannotAuthorizeReply(t *testing.T) {
	tx := &consentQueryTx{active: map[string]uuid.UUID{consentKey("chat_import", "2026-11"): uuid.New()}}
	_, err := (&Service{}).activeConsentBinding(context.Background(), tx, uuid.New(), nil)
	if !errors.Is(err, ErrConsent) {
		t.Fatalf("contact import grant authorized reply: %v", err)
	}
}
