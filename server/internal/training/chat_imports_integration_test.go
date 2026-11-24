//go:build integration

package training

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/privacy"
	"high-eq/server/migrations"
)

func openChatImportTestPool(t *testing.T, ctx context.Context) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("DATABASE_URL")
	if dsn == "" {
		t.Fatal("DATABASE_URL is required")
	}
	if err := migrations.Up(ctx, dsn); err != nil {
		t.Fatal(err)
	}
	p, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func createChatImportUser(t *testing.T, ctx context.Context, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	var user uuid.UUID
	if err := pool.QueryRow(ctx, `insert into users(age_confirmed_at) values(now()) returning id`).Scan(&user); err != nil {
		t.Fatal(err)
	}
	return user
}

func createChatImport(t *testing.T, ctx context.Context, pool *pgxpool.Pool, user uuid.UUID, receivedAt time.Time, secret string) uuid.UUID {
	t.Helper()
	activity := uuid.New()
	if _, err := pool.Exec(ctx, `insert into activities(id,user_id,kind) values($1,$2,'practice')`, activity, user); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `insert into chat_imports(activity_id,received_at,original_enc) values($1,$2,$3)`, activity, receivedAt, []byte(secret)); err != nil {
		t.Fatal(err)
	}
	return activity
}

func chatImportExists(t *testing.T, ctx context.Context, pool *pgxpool.Pool, activity uuid.UUID) bool {
	t.Helper()
	var exists bool
	if err := pool.QueryRow(ctx, `select exists(select from chat_imports where activity_id=$1)`, activity).Scan(&exists); err != nil {
		t.Fatal(err)
	}
	return exists
}

func TestChatImportsExpireAtBoundaryAndRetryAcrossPoolRestart(t *testing.T) {
	ctx := context.Background()
	pool := openChatImportTestPool(t, ctx)
	var livePool *pgxpool.Pool = pool
	t.Cleanup(func() {
		if livePool != nil {
			livePool.Close()
		}
	})
	now := time.Now().UTC().Truncate(time.Microsecond)
	user := createChatImportUser(t, ctx, pool)
	t.Cleanup(func() {
		if livePool != nil {
			_, _ = livePool.Exec(context.Background(), `delete from users where id=$1`, user)
		}
	})

	tooOld := createChatImport(t, ctx, pool, user, now.Add(-24*time.Hour-time.Minute), "synthetic-old-ciphertext")
	atBoundary := createChatImport(t, ctx, pool, user, now.Add(-24*time.Hour), "synthetic-boundary-ciphertext")
	stillLive := createChatImport(t, ctx, pool, user, now.Add(-24*time.Hour+time.Microsecond), "synthetic-live-ciphertext")

	s := &Service{DB: pool}
	if err := s.PurgeChatImports(ctx, now); err != nil {
		t.Fatal(err)
	}
	if chatImportExists(t, ctx, pool, tooOld) || chatImportExists(t, ctx, pool, atBoundary) {
		t.Fatal("expired chat import survived cleanup")
	}
	if !chatImportExists(t, ctx, pool, stillLive) {
		t.Fatal("live chat import was deleted")
	}
	var activityRemains, boundaryRemains bool
	if err := pool.QueryRow(ctx, `select exists(select from activities where id=$1),exists(select from activities where id=$2)`, tooOld, atBoundary).Scan(&activityRemains, &boundaryRemains); err != nil {
		t.Fatal(err)
	}
	if !activityRemains || !boundaryRemains {
		t.Fatal("cleanup removed activity idempotency roots")
	}

	// A failed SQL delete must leave the row intact for the next attempt.
	failed := createChatImport(t, ctx, pool, user, now.Add(-25*time.Hour), "synthetic-retry-ciphertext")
	suffix := strings.ReplaceAll(uuid.NewString(), "-", "")
	fn, trigger := "chat_import_reject_"+suffix, "chat_import_reject_"+suffix
	if _, err := pool.Exec(ctx, fmt.Sprintf(`create function %s() returns trigger language plpgsql as $$begin raise exception 'synthetic purge failure'; end;$$`, fn)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if livePool != nil {
			_, _ = livePool.Exec(context.Background(), fmt.Sprintf(`drop trigger if exists %s on chat_imports`, trigger))
			_, _ = livePool.Exec(context.Background(), fmt.Sprintf(`drop function if exists %s()`, fn))
		}
	})
	if _, err := pool.Exec(ctx, fmt.Sprintf(`create trigger %s before delete on chat_imports for each row execute function %s()`, trigger, fn)); err != nil {
		t.Fatal(err)
	}
	if err := s.PurgeChatImports(ctx, now); err == nil {
		t.Fatal("purge reported success during an injected storage failure")
	}
	if !chatImportExists(t, ctx, pool, failed) {
		t.Fatal("failed cleanup did not leave a retryable row")
	}
	if _, err := pool.Exec(ctx, fmt.Sprintf(`drop trigger %s on chat_imports`, trigger)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, fmt.Sprintf(`drop function %s()`, fn)); err != nil {
		t.Fatal(err)
	}
	if err := s.PurgeChatImports(ctx, now); err != nil {
		t.Fatal(err)
	}
	if chatImportExists(t, ctx, pool, failed) {
		t.Fatal("retry did not remove the expired row")
	}

	// Recreate the service over a fresh pool, as after a process restart.
	pool.Close()
	livePool = nil
	livePool = openChatImportTestPool(t, ctx)
	restartUser := createChatImportUser(t, ctx, livePool)
	t.Cleanup(func() {
		_, _ = livePool.Exec(context.Background(), `delete from users where id=$1`, restartUser)
	})
	restart := createChatImport(t, ctx, livePool, restartUser, now.Add(-25*time.Hour), "synthetic-restart-ciphertext")
	if err := (&Service{DB: livePool}).PurgeChatImports(ctx, now); err != nil {
		t.Fatal(err)
	}
	if chatImportExists(t, ctx, livePool, restart) {
		t.Fatal("fresh pool/service did not clean the expired row")
	}
}

func TestChatImportsExportIsLiveOwnedMetadataOnly(t *testing.T) {
	ctx := context.Background()
	pool := openChatImportTestPool(t, ctx)
	t.Cleanup(pool.Close)
	now := time.Now().UTC().Truncate(time.Microsecond)
	owner := createChatImportUser(t, ctx, pool)
	other := createChatImportUser(t, ctx, pool)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), `delete from users where id=any($1::uuid[])`, []uuid.UUID{owner, other})
	})

	old := createChatImport(t, ctx, pool, owner, now.Add(-24*time.Hour), "owner-expired-ciphertext")
	freshAt := now.Add(-time.Hour)
	fresh := createChatImport(t, ctx, pool, owner, freshAt, "owner-live-ciphertext")
	foreign := createChatImport(t, ctx, pool, other, now.Add(-time.Hour), "other-live-ciphertext")

	module := ChatImportHooks()
	if module.Export == nil {
		t.Fatal("chat import hook has no export")
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())

	tests := []struct {
		name   string
		export func(privacy.Emit) error
	}{
		{"exact cutoff", func(emit privacy.Emit) error {
			return exportChatImports(ctx, tx, owner, now, emit)
		}},
		{"registered hook", func(emit privacy.Emit) error {
			return module.Export(ctx, tx, privacy.ExportRequest{OperationID: uuid.New(), UserID: owner}, emit)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var records []json.RawMessage
			if err := test.export(func(v any) error {
				raw, err := json.Marshal(v)
				if err != nil {
					return err
				}
				records = append(records, raw)
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			if len(records) != 1 {
				t.Fatalf("export returned %d rows; want only owner's live row", len(records))
			}
			raw := records[0]
			for _, forbidden := range []string{
				old.String(), foreign.String(), "original_enc", "owner-live-ciphertext",
				base64.StdEncoding.EncodeToString([]byte("owner-live-ciphertext")),
			} {
				if strings.Contains(string(raw), forbidden) {
					t.Fatalf("export leaked %q: %s", forbidden, raw)
				}
			}
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(raw, &fields); err != nil {
				t.Fatal(err)
			}
			if len(fields) != 3 || fields["activity_id"] == nil ||
				fields["received_at"] == nil || fields["content_unavailable"] == nil {
				t.Fatalf("unexpected export fields: %s", raw)
			}
			var record chatImportExport
			if err := json.Unmarshal(raw, &record); err != nil {
				t.Fatal(err)
			}
			if record.ActivityID != fresh || !record.ReceivedAt.Equal(freshAt) || !record.ContentUnavailable {
				t.Fatalf("exported record = %+v; want only owner's live metadata", record)
			}
		})
	}
}
