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
	queries []string
}

func (f *consentQueryTx) QueryRow(_ context.Context, _ string, args ...any) pgx.Row {
	purpose := args[1].(string)
	f.queries = append(f.queries, purpose)
	id := f.active[purpose]
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
			active:           map[string]uuid.UUID{"chat_import": chat, "contacts": contacts},
			wantContactsRead: true,
		},
		{
			name:             "contacts regranted",
			withContact:      true,
			binding:          consentBinding{chat: chat, contacts: &contacts},
			active:           map[string]uuid.UUID{"chat_import": chat, "contacts": uuid.New()},
			wantErr:          membership.ErrForbidden,
			wantContactsRead: true,
		},
		{
			name:             "contacts withdrawn",
			withContact:      true,
			binding:          consentBinding{chat: chat, contacts: &contacts},
			active:           map[string]uuid.UUID{"chat_import": chat},
			wantErr:          membership.ErrForbidden,
			wantContactsRead: true,
		},
		{
			name:        "chat regranted",
			withContact: true,
			binding:     consentBinding{chat: chat, contacts: &contacts},
			active:      map[string]uuid.UUID{"chat_import": uuid.New(), "contacts": contacts},
			wantErr:     ErrConsent,
		},
		{
			name:    "no contact ignores contacts consent",
			binding: consentBinding{chat: chat},
			active:  map[string]uuid.UUID{"chat_import": chat},
		},
		{
			name:    "no-contact request cannot smuggle a contacts binding",
			binding: consentBinding{chat: chat, contacts: &contacts},
			active:  map[string]uuid.UUID{"chat_import": chat, "contacts": contacts},
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
		{name: "no contact", active: map[string]uuid.UUID{"chat_import": chat}, wantRead: []string{"chat_import"}},
		{name: "selected contact", contact: &contacts, active: map[string]uuid.UUID{"chat_import": chat, "contacts": contacts}, wantRead: []string{"chat_import", "contacts"}},
		{name: "selected contact lacks consent", contact: &contacts, active: map[string]uuid.UUID{"chat_import": chat}, wantErr: membership.ErrForbidden, wantRead: []string{"chat_import", "contacts"}},
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
				if tx.queries[i] != tc.wantRead[i] {
					t.Fatalf("queries=%v want=%v", tx.queries, tc.wantRead)
				}
			}
		})
	}
}
