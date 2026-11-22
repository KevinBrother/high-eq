//go:build t23pipe

package reviews

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/events"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

func TestPersistTerminalFencesStaleWorker(t *testing.T) {
	ctx := t.Context()
	db := openTerminalPipeDB(t)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}

	user, activity := uuid.New(), uuid.New()
	oldToken, currentToken := uuid.New(), uuid.New()
	exec(`insert into users(id,age_confirmed_at) values($1,now())`, user)
	exec(`insert into activities(id,user_id,kind,state) values($1,$2,'review','active')`, activity, user)
	exec(`insert into quota_attempts(activity_id,token,state,held_day,valid_until,metered) values($1,$2,'held',current_date,now()+interval '1 hour',true)`, activity, oldToken)
	// A retry has already replaced the stale worker's token and left the activity active.
	exec(`update quota_attempts set token=$2 where activity_id=$1`, activity, currentToken)
	call := uuid.New()
	exec(`insert into review_requests(activity_id,user_id,request_id,input_mac,repair_enc,generated_enc,generated_task,generated_call_id,generated_at) values($1,$2,$3,decode(repeat('23',32),'hex'),'\x726570616972','\x67656e657261746564','scoring',$4,now())`, activity, user, uuid.New(), call)

	cache := redis.NewClient(&redis.Options{})
	defer cache.Close()
	binding := uuid.New()
	exec(`insert into ledger_binding values(true,$1)`, binding)
	cache.AddHook(terminalLedgerHook{binding.String() + ":45"})
	ledger, err := privacy.BindLedger(ctx, db, cache, 45)
	if err != nil {
		t.Fatal(err)
	}
	reg, err := privacy.NewRegistry([]string{"reviews"}, privacy.Module{
		Name:   "reviews",
		Delete: func(context.Context, pgx.Tx, privacy.Deletion) error { return nil },
		Export: func(context.Context, pgx.Tx, privacy.ExportRequest, privacy.Emit) error { return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	svc := Service{Data: privacy.NewCoordinator(db, ledger, reg)}
	principal := accounts.Principal{User: user}

	// The stale worker may not turn the newer worker's active activity into a
	// terminal state or clear the newer worker's checkpoint.
	err = svc.persistTerminal(ctx, principal, activity, oldToken, membership.ModerationUnavailable)
	if !errors.Is(err, membership.ErrConflict) {
		t.Fatalf("stale worker terminal write: got %v, want membership.ErrConflict", err)
	}
	var state string
	var token uuid.UUID
	var generated []byte
	if err = db.QueryRow(ctx, `select a.state,q.token,r.generated_enc from activities a join quota_attempts q on q.activity_id=a.id join review_requests r on r.activity_id=a.id where a.id=$1`, activity).Scan(&state, &token, &generated); err != nil {
		t.Fatal(err)
	}
	if state != "active" || token != currentToken || generated == nil {
		t.Fatalf("stale worker changed current state: state=%s token=%s checkpoint=%v", state, token, generated != nil)
	}

	// The current worker can settle and clear the checkpoint. Repeating the same
	// terminal write is idempotent because both the activity state and token match.
	if err = svc.persistTerminal(ctx, principal, activity, currentToken, membership.Failed); err != nil {
		t.Fatalf("current worker terminal write: %v", err)
	}
	if err = db.QueryRow(ctx, `select a.state,q.token,r.generated_enc from activities a join quota_attempts q on q.activity_id=a.id join review_requests r on r.activity_id=a.id where a.id=$1`, activity).Scan(&state, &token, &generated); err != nil {
		t.Fatal(err)
	}
	if state != "failed" || token != currentToken || generated != nil {
		t.Fatalf("current worker settlement: state=%s token=%s checkpoint=%v", state, token, generated != nil)
	}
	if err = svc.persistTerminal(ctx, principal, activity, currentToken, membership.Failed); err != nil {
		t.Fatalf("idempotent terminal replay: %v", err)
	}
}

func TestPurgeExpiredGeneratedCheckpoint(t *testing.T) {
	ctx := t.Context()
	db := openTerminalPipeDB(t)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}

	user, activity := uuid.New(), uuid.New()
	exec(`insert into users(id,age_confirmed_at) values($1,now())`, user)
	exec(`insert into activities(id,user_id,kind,state) values($1,$2,'review','moderation_unavailable')`, activity, user)
	exec(`insert into review_requests(activity_id,user_id,request_id,input_mac,generated_enc,generated_task,generated_call_id,generated_at) values($1,$2,$3,decode(repeat('23',32),'hex'),'\x67656e657261746564','scoring',$4,now())`, activity, user, uuid.New(), uuid.New())

	svc := Service{DB: db, Bus: events.New(nil, nil)}
	assertCheckpoint := func(want bool) {
		t.Helper()
		var enc, task, call, at, expired bool
		if err := db.QueryRow(ctx, `select generated_enc is not null,generated_task is not null,generated_call_id is not null,generated_at is not null,generated_expired from review_requests where activity_id=$1`, activity).Scan(&enc, &task, &call, &at, &expired); err != nil {
			t.Fatal(err)
		}
		if enc != want || task != want || call != want || at != want {
			t.Fatalf("checkpoint fields present: enc=%v task=%v call=%v at=%v, want all %v", enc, task, call, at, want)
		}
		if expired == want {
			t.Fatalf("checkpoint expired=%v, want %v", expired, !want)
		}
	}

	if err := svc.ReplayPending(ctx); err != nil {
		t.Fatal(err)
	}
	assertCheckpoint(true)
	exec(`update review_requests set generated_at=now()-interval '16 minutes' where activity_id=$1`, activity)
	if err := svc.ReplayPending(ctx); err != nil {
		t.Fatal(err)
	}
	assertCheckpoint(false)
}

func openTerminalPipeDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	if os.Getenv("PGLITE") == "" {
		t.Fatal("set PGLITE to the absolute directory of @electric-sql/pglite@0.3.2")
	}
	cmd := exec.Command("node", "testdata/pgpipe.mjs")
	cmd.Stderr = os.Stderr
	in, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	client, pipe := net.Pipe()
	go func() { _, _ = io.Copy(in, pipe); in.Close() }()
	go func() { _, _ = io.Copy(pipe, out); pipe.Close() }()
	cfg, err := pgxpool.ParseConfig("postgres://fixture@localhost/fixture?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	cfg.MaxConns = 1
	cfg.ConnConfig.DialFunc = func(context.Context, string, string) (net.Conn, error) { return client, nil }
	db, err := pgxpool.NewWithConfig(t.Context(), cfg)
	if err != nil {
		_ = cmd.Process.Kill()
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close(); _ = cmd.Wait() })
	return db
}

type terminalLedgerHook struct{ seal string }

func (terminalLedgerHook) DialHook(next redis.DialHook) redis.DialHook { return next }
func (terminalLedgerHook) ProcessPipelineHook(next redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return next
}
func (h terminalLedgerHook) ProcessHook(_ redis.ProcessHook) redis.ProcessHook {
	return func(_ context.Context, c redis.Cmder) error {
		switch c.Name() {
		case "eval":
			c.(*redis.Cmd).SetVal(int64(0))
		case "get":
			c.(*redis.StringCmd).SetVal(h.seal)
		case "config":
			c.(*redis.MapStringStringCmd).SetVal(map[string]string{
				"appendonly": "yes", "appendfsync": "always", "maxmemory-policy": "noeviction",
				"no-appendfsync-on-rewrite": "no", "aof-load-truncated": "no",
			})
		default:
			return errors.New("unexpected cache call")
		}
		return nil
	}
}
