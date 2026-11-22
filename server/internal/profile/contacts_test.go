package profile

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"high-eq/server/internal/fieldcrypt"
)

type contactStoreFixture struct {
	pgx.Tx
	query string
}

func (f *contactStoreFixture) Exec(_ context.Context, q string, _ ...any) (pgconn.CommandTag, error) {
	f.query = q
	return pgconn.NewCommandTag("INSERT 0 1"), nil
}

func TestCreateContactStartsUnused(t *testing.T) {
	fields, e := fieldcrypt.New(1, map[uint32][]byte{1: make([]byte, 32)})
	if e != nil {
		t.Fatal(e)
	}
	s := Service{Fields: fields}
	f := &contactStoreFixture{}
	if e := s.store(context.Background(), f, uuid.New(), uuid.New(), dossier{}, true); e != nil {
		t.Fatal(e)
	}
	if strings.Contains(f.query, "clock_timestamp()") || !strings.Contains(f.query, "last_used_at) values($1,$2,$3,null)") {
		t.Fatalf("new contact was marked used: %s", f.query)
	}
}
