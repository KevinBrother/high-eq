//go:build integration

package service

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/golang-migrate/migrate/v4"
	migrator "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
)

const (
	profileRetryMigrationVersion    = 20261124000001
	practiceErasureMigrationVersion = 20261124010027
)

func TestProfileInferenceSurvivesPopulatedRollback(t *testing.T) {
	if os.Getenv("T35_PRIVACY_DISPOSABLE") != "yes" {
		t.Skip("rollback requires the T35 service gate's exclusive disposable database")
	}
	f := newProfilePersistenceFixture(t)
	s := f.s
	subject := uuid.NewString()
	a := f.login(s, subject)
	f.grant(a.AccessToken, "contacts", true)
	f.grant(a.AccessToken, "chat_import", true)
	contact := f.contact(a.AccessToken)
	path := contact + "/infer"
	newInput := func() app.InferProfileInput {
		return app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	}
	complete, revoked, retry, running, erased := newInput(), newInput(), newInput(), newInput(), newInput()
	f.request(a.AccessToken, "POST", path, complete, 200, nil)

	// The real gateway detects a new consent record before dispatch and
	// invalidates the existing reservation. Both old and current consent
	// records remain in the database through the migration.
	entered, resume, hold := holdProfileAttempt(t)
	ai := s.Profiles.AI
	s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
		if err := hold(ctx); err != nil {
			return gateway.Reply{}, err
		}
		return ai.Run(ctx, call)
	})
	done := f.startInference(f.router, a.AccessToken, path, revoked)
	awaitProfileStep(t, entered)
	f.grant(a.AccessToken, "chat_import", false)
	f.grant(a.AccessToken, "chat_import", true)
	resume()
	f.check(awaitProfileStep(t, done), 409, nil)
	s.Profiles.AI = ai

	f.fail.Store(true)
	f.requireUnavailable(a.AccessToken, path, retry)
	erasedSubject := uuid.NewString()
	deleted := f.login(s, erasedSubject)
	f.grant(deleted.AccessToken, "contacts", true)
	f.grant(deleted.AccessToken, "chat_import", true)
	deletedPath := f.contact(deleted.AccessToken) + "/infer"
	f.requireUnavailable(deleted.AccessToken, deletedPath, erased)
	f.fail.Store(false)
	if row := f.reservation(s, deleted.UserId, erased.RequestId); row != (profileReservationState{state: "retryable"}) {
		t.Fatal("account deletion fixture lacked its retryable business row")
	}
	if m := f.metering(s, deleted.UserId, erased.RequestId); m != (profileMetering{calls: 1, failedReview: 1}) {
		t.Fatalf("account deletion fixture lacked its audit row: %+v", m)
	}
	f.request(deleted.AccessToken, "POST", "me/closure", map[string]any{"proof": f.proof(s, erasedSubject)}, 200, nil)
	f.exec(s, `update users set closure_requested_at=clock_timestamp()-interval '361 hours' where id=$1`, deleted.UserId)
	f.must(s.Accounts.PurgeDue(f.ctx))
	requireErased := func(db *sql.DB) {
		t.Helper()
		var survives bool
		f.must(db.QueryRowContext(f.ctx, `select exists(select from users where id=$1)
			or exists(select from profile_inference_requests where user_id=$1)
			or exists(select from ai_calls where user_id=$1 or operation_id=$2)`, deleted.UserId, erased.RequestId).Scan(&survives))
		if survives {
			t.Fatal("account erasure left a user, inference binding or call")
		}
	}

	// Retain a separate ordinary processing row by aborting outside the
	// gateway, so migration must not classify it as a parked retry.
	s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
		_ = authorizeProfileDispatch(ctx, call, func(context.Context, pgx.Tx) error {
			panic("synthetic interruption before provider dispatch")
		})
		return gateway.Reply{}, errors.New("synthetic interruption bypassed authorization")
	})
	f.request(a.AccessToken, "POST", path, running, 500, nil)
	s.Profiles.AI = ai
	if row := f.reservation(s, a.UserId, running.RequestId); row.state != "processing" || !row.owner.Valid || !row.live {
		t.Fatal("ordinary processing fixture did not survive the interruption")
	}
	if f.calls.Load() != 5 {
		t.Fatalf("fixture sent %d provider requests, want 5", f.calls.Load())
	}

	cfg, err := LoadConfig()
	f.must(err)
	db, err := sql.Open("pgx", cfg.DatabaseURL)
	f.must(err)
	defer db.Close()
	requireErased(db)
	rows := []struct {
		input            app.InferProfileInput
		before, previous string
	}{
		{complete, "complete", "complete"},
		{revoked, "invalidated", "invalidated"},
		{retry, "retryable", "processing"},
		{running, "processing", "processing"},
	}
	before := make(map[uuid.UUID]profileMigrationRow, len(rows))
	for _, row := range rows {
		got := f.migrationRow(db, a.UserId, row.input.RequestId)
		if got.state != row.before || got.parked {
			t.Fatalf("before rollback: got state=%q parked=%t, want %q and no marker", got.state, got.parked, row.before)
		}
		before[row.input.RequestId] = got
	}

	// Stop the current instance before the schema changes. Down uses the
	// migration driver/version table. Restart runs the embedded Up used by cmd/api.
	f.stop()
	latestVersion := f.downProfileMigrations(cfg.DatabaseURL)
	for _, row := range rows {
		id := row.input.RequestId
		got := f.migrationRow(db, a.UserId, id)
		want := before[id]
		want.state, want.parked = row.previous, id == retry.RequestId
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("rollback changed the binding or marker for %q: state=%q parked=%t", row.before, got.state, got.parked)
		}
	}
	var columns int
	f.must(db.QueryRowContext(f.ctx, `select count(*) from information_schema.columns
		where table_schema=current_schema() and table_name='profile_inference_requests'
		and column_name in ('owner_id','lease_expires_at')`).Scan(&columns))
	if columns != 0 {
		t.Fatalf("old schema retained %d lease columns", columns)
	}
	requireErased(db)

	next := f.start()
	f.router = next.Router()
	var version uint64
	var dirty bool
	f.must(db.QueryRowContext(f.ctx, `select version,dirty from schema_migrations`).Scan(&version, &dirty))
	if version != latestVersion || dirty {
		t.Fatalf("startup migration version=%d dirty=%t, want latest %d and clean", version, dirty, latestVersion)
	}
	f.t.Logf("profile migration up reached version=%d dirty=%t latest=%d", version, dirty, latestVersion)
	f.requirePracticeErasureSchema(db, true)
	f.requireProfileRetrySchema(db, true)
	for _, row := range rows {
		id := row.input.RequestId
		if got := f.migrationRow(db, a.UserId, id); !reflect.DeepEqual(got, before[id]) {
			t.Fatalf("restart changed the binding for %q: state=%q parked=%t", row.before, got.state, got.parked)
		}
		want := profileReservationState{state: row.before, live: row.before == "processing"}
		if got := f.reservation(next, a.UserId, id); got != want {
			t.Fatalf("startup state=%+v, want %+v", got, want)
		}
	}
	requireErased(db)
	relogged := f.login(next, subject)
	if relogged.UserId != a.UserId {
		t.Fatal("login after upgrade did not retain the account")
	}
	f.request(relogged.AccessToken, "POST", path, complete, 200, nil)
	f.request(relogged.AccessToken, "POST", path, revoked, 409, nil)
	f.pending(relogged.AccessToken, path, running)
	f.grant(relogged.AccessToken, "chat_import", false)
	f.grant(relogged.AccessToken, "chat_import", true)
	f.expire(next, a.UserId, running.RequestId)
	f.request(relogged.AccessToken, "POST", path, running, 409, nil)
	if got := f.reservation(next, a.UserId, running.RequestId); got != (profileReservationState{state: "invalidated"}) {
		t.Fatal("expired previous-schema execution regained authority after renewed consent")
	}
	changed := retry
	changed.ChatText += "-REPLACEMENT"
	f.request(relogged.AccessToken, "POST", path, changed, 409, nil)
	f.request(deleted.AccessToken, "POST", deletedPath, erased, 401, nil)
	failed := profileMetering{calls: 1, failedReview: 1}
	if got := f.metering(next, a.UserId, retry.RequestId); got != failed || f.calls.Load() != 5 {
		t.Fatalf("migration or rejected requests changed old attempts: %+v; dispatches=%d", got, f.calls.Load())
	}
	f.request(relogged.AccessToken, "POST", path, retry, 200, nil)
	f.request(relogged.AccessToken, "POST", path, retry, 200, nil)
	want := profileMetering{calls: 4, failedReview: 1, generated: 1, input: 12, output: 3, cost: 0.018}
	if got := f.metering(next, a.UserId, retry.RequestId); got != want || f.calls.Load() != 8 {
		t.Fatalf("same-material retry after upgrade: %+v; dispatches=%d", got, f.calls.Load())
	}
	requireErased(db)
}

type profileMigrationRow struct {
	contact, chatConsent, contactsConsent uuid.UUID
	digest                                []byte
	created                               time.Time
	state                                 string
	parked                                bool
}

func (f *profilePersistenceFixture) migrationRow(db *sql.DB, user, request uuid.UUID) profileMigrationRow {
	f.t.Helper()
	var row profileMigrationRow
	f.must(db.QueryRowContext(f.ctx, `select contact_id,chat_consent_id,contacts_consent_id,input_digest,created_at,
		state,updated_at='infinity' from profile_inference_requests where user_id=$1 and request_id=$2`, user, request).
		Scan(&row.contact, &row.chatConsent, &row.contactsConsent, &row.digest, &row.created, &row.state, &row.parked))
	return row
}

func (f *profilePersistenceFixture) downProfileMigrations(databaseURL string) uint64 {
	f.t.Helper()
	source, err := iofs.New(os.DirFS("../../migrations"), ".")
	f.must(err)
	defer source.Close()
	db, err := sql.Open("pgx", databaseURL)
	f.must(err)
	defer db.Close()
	driver, err := migrator.WithInstance(db, &migrator.Config{StatementTimeout: 10 * time.Second})
	f.must(err)
	defer driver.Close()
	m, err := migrate.NewWithInstance("file", source, "pgx5", driver)
	f.must(err)
	m.LockTimeout = 10 * time.Second

	version, dirty, err := m.Version()
	f.must(err)
	if dirty || version < profileRetryMigrationVersion {
		f.t.Fatalf("cannot roll back migrations from version=%d dirty=%t", version, dirty)
	}
	latest := version
	for version != profileRetryMigrationVersion {
		from := version
		previous, err := source.Prev(from)
		f.must(err)
		before := f.migrationSchemaFingerprint(db)
		f.must(m.Steps(-1))
		version, dirty, err = m.Version()
		f.must(err)
		if version != previous || dirty {
			f.t.Fatalf("down from %d left version=%d dirty=%t, want version=%d clean", from, version, dirty, previous)
		}
		if after := f.migrationSchemaFingerprint(db); after == before {
			f.t.Fatalf("down to version %d did not change the migrated schema", version)
		}
		if from == practiceErasureMigrationVersion {
			f.requirePracticeErasureSchema(db, false)
			f.t.Logf("practice erasure rollback verified from=%d reached=%d dirty=%t", from, version, dirty)
		}
		f.t.Logf("migration down reached version=%d dirty=%t", version, dirty)
	}

	previous, err := source.Prev(profileRetryMigrationVersion)
	f.must(err)
	before := f.migrationSchemaFingerprint(db)
	f.must(m.Steps(-1))
	version, dirty, err = m.Version()
	f.must(err)
	if version != previous || dirty {
		f.t.Fatalf("profile down left version=%d dirty=%t, want version=%d clean", version, dirty, previous)
	}
	if after := f.migrationSchemaFingerprint(db); after == before {
		f.t.Fatalf("profile down to version %d did not change the migrated schema", version)
	}
	f.requireProfileRetrySchema(db, false)
	f.t.Logf("profile migration down reached version=%d dirty=%t", version, dirty)
	return uint64(latest)
}

func (f *profilePersistenceFixture) migrationSchemaFingerprint(db *sql.DB) string {
	f.t.Helper()
	var fingerprint string
	f.must(db.QueryRowContext(f.ctx, `
		select md5(
			coalesce((select string_agg(table_name||':'||column_name||':'||data_type, ',' order by table_name,column_name)
				from information_schema.columns where table_schema=current_schema()), '') ||
			coalesce((select string_agg(p.proname||':'||pg_get_function_identity_arguments(p.oid), ',' order by p.proname)
				from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname=current_schema()), '') ||
			coalesce((select string_agg(t.tgname||':'||c.relname, ',' order by t.tgname)
				from pg_trigger t join pg_class c on c.oid=t.tgrelid
				join pg_namespace n on n.oid=c.relnamespace
				where n.nspname=current_schema() and not t.tgisinternal), '')
		)`).Scan(&fingerprint))
	if fingerprint == "" {
		f.t.Fatal("migration schema fingerprint is empty")
	}
	return fingerprint
}

func (f *profilePersistenceFixture) requirePracticeErasureSchema(db *sql.DB, present bool) {
	f.t.Helper()
	var table, function, trigger, column bool
	f.must(db.QueryRowContext(f.ctx, `
		select
			exists(select from pg_class c join pg_namespace n on n.oid=c.relnamespace
				where n.nspname=current_schema() and c.relname='practice_request_tombstones' and c.relkind='r'),
			exists(select from pg_proc p join pg_namespace n on n.oid=p.pronamespace
				where n.nspname=current_schema() and p.proname='record_practice_request_tombstone'),
			exists(select from pg_trigger t join pg_class c on c.oid=t.tgrelid
				join pg_namespace n on n.oid=c.relnamespace
				where n.nspname=current_schema() and t.tgname='practice_request_tombstone' and not t.tgisinternal),
			exists(select from information_schema.columns where table_schema=current_schema()
				and table_name='daily_plans' and column_name='completed_without_timestamp')
	`).Scan(&table, &function, &trigger, &column))
	if present && (!table || !function || !trigger || !column) {
		f.t.Fatalf("practice erasure schema incomplete: table=%t function=%t trigger=%t column=%t", table, function, trigger, column)
	}
	if !present && (table || function || trigger || column) {
		f.t.Fatalf("practice erasure schema survived down: table=%t function=%t trigger=%t column=%t", table, function, trigger, column)
	}
	f.t.Logf("practice erasure schema table_absent=%t function_absent=%t trigger_absent=%t column_absent=%t", !table, !function, !trigger, !column)
}

func (f *profilePersistenceFixture) requireProfileRetrySchema(db *sql.DB, present bool) {
	f.t.Helper()
	var leaseColumns int
	var acceptsRetryable, requestIndex bool
	f.must(db.QueryRowContext(f.ctx, `
		select
			(select count(*) from information_schema.columns
				where table_schema=current_schema() and table_name='profile_inference_requests'
				and column_name in ('owner_id','lease_expires_at')),
			exists(select from pg_constraint
				where conrelid='profile_inference_requests'::regclass
				and contype='c' and pg_get_constraintdef(oid) like '%retryable%'),
			exists(select from pg_indexes where schemaname=current_schema()
				and indexname='ai_calls_profile_inference_request')
	`).Scan(&leaseColumns, &acceptsRetryable, &requestIndex))
	if present && (leaseColumns != 2 || !acceptsRetryable || !requestIndex) {
		f.t.Fatalf("profile retry schema incomplete: lease_columns=%d retryable=%t request_index=%t", leaseColumns, acceptsRetryable, requestIndex)
	}
	if !present && (leaseColumns != 0 || acceptsRetryable || requestIndex) {
		f.t.Fatalf("profile retry schema survived down: lease_columns=%d retryable=%t request_index=%t", leaseColumns, acceptsRetryable, requestIndex)
	}
}
