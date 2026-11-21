package payments

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/payments/testkit"
)

// The only permitted SQL call on a wrong-account restore is reading the
// authenticated user's token. The embedded nil Tx makes an unexpected write fail.
type tokenTx struct {
	pgx.Tx
	token uuid.UUID
}

func (t tokenTx) QueryRow(_ context.Context, q string, _ ...any) pgx.Row {
	if q != "select app_account_token from users where id=$1" {
		panic("unexpected statement")
	}
	return tokenRow(t.token)
}

type tokenRow uuid.UUID

func (r tokenRow) Scan(dest ...any) error { *dest[0].(*uuid.UUID) = uuid.UUID(r); return nil }
func TestRestoreRejectsOtherAccountBeforeWrite(t *testing.T) {
	now := time.Now()
	p := testkit.Chain(t, now)
	s, e := New(nil, nil, make([]byte, 32), Channels{Apple: &Apple{Roots: p.Pool, Bundle: "test.bundle", Products: Catalog{"monthly": {SKU: "test.month"}}, Environment: "Sandbox"}})
	if e != nil {
		t.Fatal(e)
	}
	jws := p.Sign(t, testkit.Transaction(uuid.NewString(), "1", "1", now, now.Add(time.Hour)))
	if e = s.Restore(context.Background(), tokenTx{token: uuid.New()}, uuid.New(), jws); e != ErrOwner {
		t.Fatal(e)
	}
}
