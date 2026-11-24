package profile

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type missingContactTx struct {
	pgx.Tx
	user, contact uuid.UUID
	err           error
	t             *testing.T
}

func (f missingContactTx) QueryRow(_ context.Context, _ string, args ...any) pgx.Row {
	f.t.Helper()
	if len(args) != 2 || args[0] != f.user || args[1] != f.contact {
		f.t.Fatalf("contact lookup did not bind account and contact: %v", args)
	}
	return scanFn(func(...any) error { return f.err })
}

func TestContactLookupDistinguishesAbsenceFromFailure(t *testing.T) {
	user, contact := uuid.New(), uuid.New()
	failed := errors.New("lookup unavailable")
	for _, tc := range []struct{ lookup, want error }{
		{pgx.ErrNoRows, ErrContactNotFound},
		{failed, failed},
	} {
		tx := missingContactTx{t: t, user: user, contact: contact, err: tc.lookup}
		_, err := (&Service{}).Contact(context.Background(), tx, user, contact)
		if !errors.Is(err, tc.want) {
			t.Fatalf("lookup %v returned %v, want %v", tc.lookup, err, tc.want)
		}
	}
}
