//go:build integration

package service

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestPrivacyExpiredAccountMaintenanceIsolatesFailure(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)

	seed := func(count int, age string) (users, roots []uuid.UUID) {
		t.Helper()
		rows, err := s.db.Query(ctx, `
			insert into users (age_confirmed_at, closure_requested_at)
			select statement_timestamp(), statement_timestamp()-$2::interval
			from generate_series(1,$1::int) returning id,purge_id`, count, age)
		if err != nil {
			t.Fatal(err)
		}
		var user, root uuid.UUID
		_, err = pgx.ForEachRow(rows, []any{&user, &root}, func() error {
			users = append(users, user)
			roots = append(roots, root)
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		return users, roots
	}
	blocked, blockedRoots := seed(1, "361 hours")
	// Equal timestamps straddle the 100-account page boundary.
	const healthyCount = 101
	healthy, healthyRoots := seed(healthyCount, "360 hours 1 minute")
	future, futureRoots := seed(1, "359 hours")

	exec := func(ctx context.Context, query string) {
		t.Helper()
		if _, err := s.db.Exec(ctx, query); err != nil {
			t.Fatal(err)
		}
	}
	exec(ctx, `create function t35_fail_expired_account_cleanup() returns trigger language plpgsql as $$
		begin raise exception using errcode = 'P3501', message = 'injected expired account cleanup failure'; end;
	$$`)
	const dropTrigger = `drop trigger if exists t35_fail_expired_account_cleanup on pending_erasure`
	t.Cleanup(func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		exec(cleanupCtx, dropTrigger)
		exec(cleanupCtx, `drop function t35_fail_expired_account_cleanup()`)
	})
	// Fail the SQL cleanup commit after the independent ledger has been written.
	exec(ctx, fmt.Sprintf(`create constraint trigger t35_fail_expired_account_cleanup
		after delete on pending_erasure deferrable initially deferred for each row
		when (old.root_id = '%s'::uuid) execute function t35_fail_expired_account_cleanup()`, blockedRoots[0]))

	assertState := func(label string, users, roots []uuid.UUID, wantUsers, wantPending, wantTombstones int) {
		t.Helper()
		var remaining, pending int
		err := s.db.QueryRow(ctx, `select
			(select count(*) from users where id=any($1::uuid[])),
			(select count(*) from pending_erasure where root_id=any($2::uuid[]))`, users, roots).Scan(&remaining, &pending)
		if err != nil {
			t.Fatal(err)
		}
		keys := make([]string, 0, len(roots))
		for _, root := range roots {
			keys = append(keys, "deleted:"+root.String())
		}
		tombstones, err := s.registryRedis.Exists(ctx, keys...).Result()
		if err != nil {
			t.Fatal(err)
		}
		if remaining != wantUsers || pending != wantPending || int(tombstones) != wantTombstones {
			t.Fatalf("%s: accounts/pending/tombstones = %d/%d/%d, want %d/%d/%d",
				label, remaining, pending, tombstones, wantUsers, wantPending, wantTombstones)
		}
	}
	pass := func() {
		t.Helper()
		passCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		s.RunMaintenancePass(passCtx, time.Now())
		if err := passCtx.Err(); err != nil {
			t.Fatalf("maintenance did not finish: %v", err)
		}
	}
	assertCleanupError := func(err error) {
		t.Helper()
		var pgErr *pgconn.PgError
		if !errors.As(err, &pgErr) || pgErr.Code != "P3501" {
			t.Fatalf("expected the injected cleanup error, got %v", err)
		}
	}

	pass()
	assertState("healthy expired accounts after one pass", healthy, healthyRoots, 0, 0, healthyCount)
	assertState("failed expired account", blocked, blockedRoots, 1, 1, 1)
	assertState("unexpired account", future, futureRoots, 1, 0, 0)
	assertCleanupError(s.Accounts.PurgeDue(ctx))
	restarted, err := Start(ctx, cfg)
	if err == nil {
		restarted.Close()
		t.Fatal("startup accepted the unresolved deletion")
	}
	assertCleanupError(err)
	assertState("failed account after startup attempt", blocked, blockedRoots, 1, 1, 1)

	exec(ctx, dropTrigger)
	pass()
	assertState("recovered account", blocked, blockedRoots, 0, 0, 1)
	assertState("unexpired account after recovery", future, futureRoots, 1, 0, 0)
}
