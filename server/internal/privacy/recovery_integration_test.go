//go:build integration

package privacy

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

func TestOwnedDeletionJournalSurvivesTombstoneLoss(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	db, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	must(t, err)
	defer db.Close()
	opts, err := redis.ParseURL(os.Getenv("LEDGER_URL"))
	must(t, err)
	ledgerRedis := redis.NewClient(opts)
	defer ledgerRedis.Close()
	ledger, err := BindLedger(ctx, db, ledgerRedis, 45)
	must(t, err)

	var hookCalls int
	var hookSource uuid.UUID
	failHook := true
	module := Module{
		Name: "training",
		Delete: func(_ context.Context, _ pgx.Tx, d Deletion) error {
			hookCalls++
			hookSource = d.SourceID
			if failHook {
				return errors.New("injected deletion hook failure")
			}
			return nil
		},
		Export: func(context.Context, pgx.Tx, ExportRequest, Emit) error { return nil },
	}
	registry, err := NewRegistry([]string{"training"}, module)
	must(t, err)
	coordinator := NewCoordinator(db, ledger, registry)

	var user, activity, source uuid.UUID
	must(t, db.QueryRow(ctx, `insert into users(age_confirmed_at) values(clock_timestamp()) returning id`).Scan(&user))
	must(t, db.QueryRow(ctx, `insert into activities(user_id,kind,state) values($1,'review','complete') returning id,source_id`, user).Scan(&activity, &source))
	must(t, func() error {
		_, err := db.Exec(ctx, `insert into scores values($1,$2,'review','fixture',clock_timestamp())`, source, activity)
		return err
	}())

	var intent DeletionIntent
	journaled := make(chan struct{})
	release := make(chan struct{})
	commitDone := make(chan error, 1)
	go func() {
		commitDone <- pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
			var err error
			intent, err = coordinator.JournalOwnedDeletionTx(ctx, tx, Deletion{
				OperationID: uuid.New(),
				UserID:      user,
				SourceID:    activity,
				Scope:       "reviews",
			})
			close(journaled)
			if err != nil {
				return err
			}
			select {
			case <-release:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	select {
	case <-journaled:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}

	accessDone := make(chan error, 1)
	go func() { accessDone <- coordinator.Access(ctx, user, func(pgx.Tx) error { return nil }) }()
	waitLock(t, ctx, db)
	close(release)
	must(t, <-commitDone)
	if err := <-accessDone; !errors.Is(err, ErrHidden) {
		t.Fatalf("access after intent commit = %v, want %v", err, ErrHidden)
	}

	var pending bool
	must(t, db.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1)`, source).Scan(&pending))
	if !pending {
		t.Fatal("committed journal entry disappeared")
	}
	tombstone, err := ledgerRedis.Exists(ctx, "deleted:"+source.String()).Result()
	must(t, err)
	if tombstone != 0 {
		t.Fatal("tombstone was written before execution")
	}

	if err := coordinator.ExecuteDeletion(ctx, intent); err == nil {
		t.Fatal("injected deletion hook failure was acknowledged")
	}
	if hookCalls != 1 || hookSource != source {
		t.Fatalf("hook calls/source = %d/%s, want 1/%s", hookCalls, hookSource, source)
	}
	var sourceRemains bool
	must(t, db.QueryRow(ctx, `select exists(select from scores where id=$1)`, source).Scan(&sourceRemains))
	if !sourceRemains {
		t.Fatal("failed execution removed source")
	}
	must(t, db.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1)`, source).Scan(&pending))
	if !pending {
		t.Fatal("failed execution removed durable intent")
	}

	// Simulate expiry of the independent tombstone. The SQL journal must keep
	// the source hidden and drive recovery from a fresh process.
	must(t, ledgerRedis.Del(ctx, "deleted:"+source.String()).Err())
	if err := coordinator.Access(ctx, user, func(pgx.Tx) error { return nil }); !errors.Is(err, ErrHidden) {
		t.Fatalf("access after tombstone loss = %v, want %v", err, ErrHidden)
	}

	// A commit failure after the tombstone and cleanup writes must roll back the
	// SQL work while retaining the earlier durable journal entry.
	must(t, func() error {
		_, err := db.Exec(ctx, `drop trigger if exists t35_pending_commit_failure on pending_erasure`)
		return err
	}())
	must(t, func() error {
		_, err := db.Exec(ctx, `drop function if exists t35_pending_commit_failure()`)
		return err
	}())
	must(t, func() error {
		_, err := db.Exec(ctx, `create function t35_pending_commit_failure() returns trigger language plpgsql as $$
			begin
				raise exception 'injected pending commit failure';
			end
		$$`)
		return err
	}())
	must(t, func() error {
		_, err := db.Exec(ctx, `create constraint trigger t35_pending_commit_failure
			after delete on pending_erasure
			deferrable initially deferred
			for each row execute function t35_pending_commit_failure()`)
		return err
	}())
	defer func() {
		_, _ = db.Exec(context.Background(), `drop trigger if exists t35_pending_commit_failure on pending_erasure`)
		_, _ = db.Exec(context.Background(), `drop function if exists t35_pending_commit_failure()`)
	}()
	failHook = false
	if err := coordinator.ExecuteDeletion(ctx, intent); err == nil {
		t.Fatal("injected cleanup commit failure was acknowledged")
	}
	must(t, db.QueryRow(ctx, `select exists(select from scores where id=$1)`, source).Scan(&sourceRemains))
	if !sourceRemains {
		t.Fatal("failed cleanup commit removed source")
	}
	must(t, db.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1)`, source).Scan(&pending))
	if !pending {
		t.Fatal("failed cleanup commit removed durable intent")
	}
	tombstone, err = ledgerRedis.Exists(ctx, "deleted:"+source.String()).Result()
	must(t, err)
	if tombstone != 1 {
		t.Fatal("cleanup attempt did not retain its tombstone")
	}
	must(t, func() error {
		_, err := db.Exec(ctx, `drop trigger t35_pending_commit_failure on pending_erasure`)
		return err
	}())
	restarted := NewCoordinator(db, ledger, registry)
	must(t, restarted.Resume(ctx))
	must(t, db.QueryRow(ctx, `select exists(select from scores where id=$1)`, source).Scan(&sourceRemains))
	if sourceRemains {
		t.Fatal("resume did not finish durable deletion")
	}
	must(t, db.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1)`, source).Scan(&pending))
	if pending {
		t.Fatal("resume retained completed intent")
	}
}

func TestContactDeletionRechecksBarrierAfterIntentCommit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	db, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	must(t, err)
	defer db.Close()
	opts, err := redis.ParseURL(os.Getenv("LEDGER_URL"))
	must(t, err)
	ledgerRedis := redis.NewClient(opts)
	defer ledgerRedis.Close()
	ledger, err := BindLedger(ctx, db, ledgerRedis, 45)
	must(t, err)

	for _, pendingChild := range []bool{true, false} {
		name := "independent tombstone"
		if pendingChild {
			name = "independent pending intent"
		}
		t.Run(name, func(t *testing.T) {
			var user, contact, child uuid.UUID
			must(t, db.QueryRow(ctx, `insert into users(age_confirmed_at) values(clock_timestamp()) returning id`).Scan(&user))
			t.Cleanup(func() {
				_, err := db.Exec(context.Background(), `delete from pending_erasure where root_id in ($1,$2)`, contact, child)
				must(t, err)
				_, err = db.Exec(context.Background(), `delete from users where id=$1`, user)
				must(t, err)
			})
			must(t, db.QueryRow(ctx, `insert into contacts(user_id,profile_enc) values($1,'fixture') returning id`, user).Scan(&contact))
			must(t, db.QueryRow(ctx, `insert into activities(user_id,contact_id,kind) values($1,$2,'review') returning source_id`, user, contact).Scan(&child))

			// Only the request under test uses this pool. Its second acquisition
			// is before the cleanup transaction begins and after the first commits.
			cfg := db.Config()
			acquisitions := 0
			injected := false
			cfg.PrepareConn = func(ctx context.Context, conn *pgx.Conn) (bool, error) {
				acquisitions++
				if acquisitions != 2 {
					return true, nil
				}
				err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
					// A competing writer takes the same account lock and proves
					// that the parent intent is already visible and committed.
					if _, err := roots(ctx, tx, user); err != nil {
						return err
					}
					var parentPending bool
					if err := tx.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1)`, contact).Scan(&parentPending); err != nil {
						return err
					}
					if !parentPending {
						return errors.New("test hook ran before the parent journal commit")
					}
					if pendingChild {
						_, err := tx.Exec(ctx, `insert into pending_erasure(root_id) values($1)`, child)
						return err
					}
					return ledger.mark(ctx, []uuid.UUID{child})
				})
				injected = err == nil
				return true, err
			}
			onlineDB, err := pgxpool.NewWithConfig(ctx, cfg)
			must(t, err)
			defer onlineDB.Close()
			cleanupCalls := 0
			registry, err := NewRegistry([]string{"probe"}, Module{
				Name:   "probe",
				Export: func(context.Context, pgx.Tx, ExportRequest, Emit) error { return nil },
				Delete: func(context.Context, pgx.Tx, Deletion) error {
					cleanupCalls++
					return nil
				},
			})
			must(t, err)
			coordinator := NewCoordinator(onlineDB, ledger, registry)
			err = coordinator.DeleteAuthorized(ctx, Deletion{
				OperationID: uuid.New(), UserID: user, SourceID: contact, Scope: "contacts",
			}, func(pgx.Tx) error { return nil })
			if !injected || !errors.Is(err, ErrHidden) {
				t.Errorf("online delete after hook: injected=%v, error=%v, want ErrHidden", injected, err)
			}
			if cleanupCalls != 0 {
				t.Errorf("ran %d cleanup hooks after competing work appeared", cleanupCalls)
			}

			var contactPresent, childPresent, contactPending, childPending bool
			must(t, db.QueryRow(ctx, `select
				exists(select from contacts where id=$1),
				exists(select from activities where source_id=$2 and contact_id=$1),
				exists(select from pending_erasure where root_id=$1),
				exists(select from pending_erasure where root_id=$2)`, contact, child).Scan(&contactPresent, &childPresent, &contactPending, &childPending))
			if !contactPresent || !childPresent || !contactPending || childPending != pendingChild {
				t.Errorf("rows contact/child=%v/%v; pending contact/child=%v/%v (child pending want %v)", contactPresent, childPresent, contactPending, childPending, pendingChild)
			}
			hits, err := ledger.lookup(ctx, []uuid.UUID{contact, child})
			must(t, err)
			wantChildHit := int64(0)
			if !pendingChild {
				wantChildHit = 1
			}
			if len(hits) != 2 || hits[0] != 0 || hits[1] != wantChildHit {
				t.Errorf("tombstones contact/child=%v, want [0 %d]", hits, wantChildHit)
			}
		})
	}
}
