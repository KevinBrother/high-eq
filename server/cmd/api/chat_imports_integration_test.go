//go:build integration

package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestChatImportCleanupProcess(t *testing.T) {
	dsn := os.Getenv("D13_DATABASE_URL")
	cache := os.Getenv("D13_REDIS_URL")
	ledger := os.Getenv("D13_LEDGER_URL")
	if dsn == "" && cache == "" && ledger == "" {
		t.Skip("requires disposable D13 PostgreSQL and Redis instances")
	}
	if dsn == "" || cache == "" || ledger == "" {
		t.Fatal("set all three D13 connection URLs")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	binary := filepath.Join(t.TempDir(), "api")
	if out, err := exec.CommandContext(ctx, "go", "build", "-o", binary, ".").CombinedOutput(); err != nil {
		t.Fatalf("build cmd/api: %v\n%s", err, out)
	}
	env := []string{
		"APP_ENV=development", "GIN_MODE=release", "PAYMENT_MODE=disabled",
		"DATABASE_URL=" + dsn, "REDIS_URL=" + cache, "LEDGER_URL=" + ledger,
		"BACKUP_RETENTION_DAYS=30",
		"FIELD_KEY_BASE64=" + base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x42}, 32)),
	}

	// The first real startup migrates the empty database and binds the ledger.
	startD13API(t, ctx, binary, env, nil)()
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal("open disposable database")
	}
	defer db.Close()
	var user uuid.UUID
	if err := db.QueryRow(ctx, `insert into users(age_confirmed_at) values(now()) returning id`).Scan(&user); err != nil {
		t.Fatal("create synthetic user:", err)
	}

	seed := func(age time.Duration) (uuid.UUID, uuid.UUID) {
		t.Helper()
		id, source := uuid.New(), uuid.New()
		if _, err := db.Exec(ctx, `insert into activities(id,source_id,user_id,kind,state)
values($1,$2,$3,'practice','active')`, id, source, user); err != nil {
			t.Fatal(err)
		}
		if _, err := db.Exec(ctx, `insert into chat_imports(activity_id,received_at,original_enc)
values($1,$2,$3)`, id, time.Now().Add(-age), []byte("synthetic D13 source")); err != nil {
			t.Fatal(err)
		}
		return id, source
	}
	importExists := func(ctx context.Context, id uuid.UUID) bool {
		t.Helper()
		var exists bool
		if err := db.QueryRow(ctx, `select exists(select from chat_imports where activity_id=$1)`, id).Scan(&exists); err != nil {
			t.Fatal(err)
		}
		return exists
	}
	expectActivity := func(id, source uuid.UUID, wantImport bool) {
		t.Helper()
		var gotSource uuid.UUID
		var state string
		err := db.QueryRow(ctx, `select source_id,state from activities where id=$1 and user_id=$2`, id, user).Scan(&gotSource, &state)
		if err != nil || gotSource != source || state != "active" {
			t.Fatalf("activity root %s changed: source=%s, state=%q, err=%v", id, gotSource, state, err)
		}
		if got := importExists(ctx, id); got != wantImport {
			t.Fatalf("chat import %s exists=%t, want %t", id, got, wantImport)
		}
	}
	expired, expiredSource := seed(25 * time.Hour)
	live, liveSource := seed(time.Hour)
	stop := startD13API(t, ctx, binary, env, nil)
	expectActivity(expired, expiredSource, false)
	expectActivity(live, liveSource, true)
	stop()

	retry, retrySource := seed(25 * time.Hour)
	lock, err := db.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Rollback(ctx)
	// SHARE conflicts with DELETE while still allowing fixture reads.
	if _, err := lock.Exec(ctx, `lock table chat_imports in share mode`); err != nil {
		t.Fatal(err)
	}
	startupLog := new(bytes.Buffer)
	stop = startD13API(t, ctx, binary, env, startupLog)
	expectActivity(retry, retrySource, true)
	var waiting int
	err = db.QueryRow(ctx, `select count(*) from pg_locks
where locktype='relation' and relation='chat_imports'::regclass and not granted
and database=(select oid from pg_database where datname=current_database())`).Scan(&waiting)
	if err != nil || waiting != 0 {
		t.Fatalf("startup DELETE still waiting for the table lock: waiters=%d, err=%v", waiting, err)
	}
	if err := lock.Rollback(ctx); err != nil {
		t.Fatal(err)
	}

	// Keep the same process running and let the real minute worker own the retry.
	waitForD13(t, ctx, 80*time.Second, "maintenance did not delete the expired chat import", func(ctx context.Context) bool {
		return !importExists(ctx, retry)
	})
	expectActivity(retry, retrySource, false)
	expectActivity(live, liveSource, true)
	stop()
	if !bytes.Contains(startupLog.Bytes(), []byte(`"msg":"startup cleanup pending","module":"chat_imports","result":"retry"`)) {
		t.Fatal("process did not record a failed chat import startup sweep")
	}
}

func startD13API(t *testing.T, ctx context.Context, binary string, env []string, log *bytes.Buffer) func() {
	t.Helper()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(ctx, binary)
	cmd.Env = append(append([]string(nil), env...), "LISTEN_ADDR="+addr)
	if log != nil {
		cmd.Stdout = log
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	var exitErr error
	go func() {
		exitErr = cmd.Wait()
		close(done)
	}()
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		<-done
	})
	stop := func() {
		t.Helper()
		if err := cmd.Process.Signal(syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		select {
		case <-done:
			if exitErr != nil {
				t.Fatal("cmd/api exited:", exitErr)
			}
		case <-time.After(12 * time.Second):
			t.Fatal("cmd/api did not shut down")
		}
	}
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{}}
	defer client.CloseIdleConnections()
	waitForD13(t, ctx, 30*time.Second, "cmd/api did not become healthy", func(ctx context.Context) bool {
		select {
		case <-done:
			t.Fatalf("cmd/api exited before readiness: %v", exitErr)
		default:
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+addr+"/v1/health", nil)
		if err != nil {
			t.Fatal(err)
		}
		resp, err := client.Do(req)
		if err != nil {
			return false
		}
		resp.Body.Close()
		return resp.StatusCode == http.StatusOK
	})
	return stop
}

func waitForD13(t *testing.T, ctx context.Context, timeout time.Duration, failure string, check func(context.Context) bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for !check(ctx) {
		select {
		case <-ctx.Done():
			t.Fatal(failure)
		case <-ticker.C:
		}
	}
}
