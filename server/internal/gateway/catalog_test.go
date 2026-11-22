package gateway

import (
	"context"
	"crypto/rand"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"high-eq/server/internal/fieldcrypt"
)

type versionRow struct{ version uuid.UUID }

func (r versionRow) Scan(dest ...any) error {
	*dest[0].(*uuid.UUID) = r.version
	return nil
}

type snapshotRows struct {
	version                         uuid.UUID
	id                              uuid.UUID
	endpoint, model, protocol, kind string
	envelope                        []byte
	read                            bool
}

func (r *snapshotRows) Close()                                       { r.read = true }
func (r *snapshotRows) Err() error                                   { return nil }
func (r *snapshotRows) CommandTag() pgconn.CommandTag                { return pgconn.CommandTag{} }
func (r *snapshotRows) FieldDescriptions() []pgconn.FieldDescription { return nil }
func (r *snapshotRows) Values() ([]any, error)                       { return nil, nil }
func (r *snapshotRows) RawValues() [][]byte                          { return nil }
func (r *snapshotRows) Conn() *pgx.Conn                              { return nil }
func (r *snapshotRows) Next() bool                                   { return !r.read }
func (r *snapshotRows) Scan(dest ...any) error {
	r.read = true
	*dest[0].(*uuid.UUID) = r.version
	*dest[1].(*uuid.UUID) = r.id
	*dest[2].(*string) = r.endpoint
	*dest[3].(*string) = r.model
	*dest[4].(*string) = r.protocol
	*dest[5].(*string) = r.kind
	*dest[6].(*[]byte) = r.envelope
	return nil
}

type snapshotTx struct {
	pgx.Tx
	version      uuid.UUID
	id           uuid.UUID
	endpoint     string
	model        string
	protocol     string
	kind         string
	envelope     []byte
	entryQueries int
}

func (t *snapshotTx) QueryRow(context.Context, string, ...any) pgx.Row {
	return versionRow{t.version}
}

func (t *snapshotTx) Query(context.Context, string, ...any) (pgx.Rows, error) {
	t.entryQueries++
	return &snapshotRows{version: t.version, id: t.id, endpoint: t.endpoint, model: t.model, protocol: t.protocol, kind: t.kind, envelope: t.envelope}, nil
}

func testCatalog(t *testing.T, id uuid.UUID, version uuid.UUID, model string) *Catalog {
	t.Helper()
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		t.Fatal(err)
	}
	fields, err := fieldcrypt.New(1, map[uint32][]byte{1: key})
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := fields.Seal([]byte("key-only-"+model), keyAAD(id))
	if err != nil {
		t.Fatal(err)
	}
	c := &Catalog{fields: fields, adapters: builtinAdapters()}
	c.state.Store(&snapshot{version: version, entries: map[uuid.UUID]entry{id: {endpoint: "https://provider.invalid", model: model, protocol: "openai_compatible", kind: Model, envelope: envelope}}})
	return c
}

func TestLookupAtRefreshesStaleCacheInsideTransaction(t *testing.T) {
	id := uuid.New()
	oldVersion, newVersion := uuid.New(), uuid.New()
	c := testCatalog(t, id, oldVersion, "one")
	tx := &snapshotTx{version: newVersion, id: id, endpoint: "https://provider.invalid", model: "two", protocol: "openai_compatible", kind: "model", envelope: c.state.Load().entries[id].envelope}

	a, target, err := c.lookupAt(context.Background(), tx, id, Model, newVersion)
	if err != nil || a == nil || target.model != "two" || tx.entryQueries != 1 {
		t.Fatalf("stale cache lookup: adapter=%v target=%+v queries=%d err=%v", a != nil, target, tx.entryQueries, err)
	}
	if c.version() != newVersion {
		t.Fatalf("cache version=%s want %s", c.version(), newVersion)
	}
}

func TestLookupAtRejectsStaleRevisionWithoutLoadingSnapshot(t *testing.T) {
	id := uuid.New()
	oldVersion, newVersion := uuid.New(), uuid.New()
	c := testCatalog(t, id, oldVersion, "one")
	tx := &snapshotTx{version: newVersion, id: id, endpoint: "https://provider.invalid", model: "two", protocol: "openai_compatible", kind: "model", envelope: c.state.Load().entries[id].envelope}

	if a, _, err := c.lookupAt(context.Background(), tx, id, Model, oldVersion); a != nil || !errors.Is(err, ErrConfig) || tx.entryQueries != 0 {
		t.Fatalf("stale revision escaped pin: adapter=%v queries=%d err=%v", a != nil, tx.entryQueries, err)
	}
}
