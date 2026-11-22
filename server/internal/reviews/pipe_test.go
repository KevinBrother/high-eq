//go:build t23pipe

package reviews_test

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// One real backend through stdio, not a SQL mock. A real auth_sessions row is provisioned. Only
// the gateway and Redis responses are controlled; see TestReviewLifecycle.
func openPipeDB(t *testing.T) *pgxpool.Pool {
	t.Helper()
	if os.Getenv("PGLITE") == "" {
		t.Fatal("set PGLITE to the absolute directory of @electric-sql/pglite@0.3.2")
	}
	cmd := exec.Command("node", "testdata/pgpipe.mjs")
	cmd.Stderr = os.Stderr
	in, e := cmd.StdinPipe()
	if e != nil {
		t.Fatal(e)
	}
	out, e := cmd.StdoutPipe()
	if e != nil {
		t.Fatal(e)
	}
	if e = cmd.Start(); e != nil {
		t.Fatal(e)
	}
	client, pipe := net.Pipe()
	go func() { _, _ = io.Copy(in, pipe); in.Close() }()
	go func() { _, _ = io.Copy(pipe, out); pipe.Close() }()
	cfg, e := pgxpool.ParseConfig("postgres://fixture@localhost/fixture?sslmode=disable")
	if e != nil {
		t.Fatal(e)
	}
	cfg.MaxConns = 1
	cfg.ConnConfig.DialFunc = func(context.Context, string, string) (net.Conn, error) { return client, nil }
	db, e := pgxpool.NewWithConfig(t.Context(), cfg)
	if e != nil {
		_ = cmd.Process.Kill()
		t.Fatal(e)
	}
	t.Cleanup(func() { db.Close(); cmd.Wait() })
	return db
}

// Model only cache admission and an online, empty deletion ledger. In particular
// these hooks do not pretend to verify WAITAOF, erasure durability or Lua.
type admitFixture struct{ seal string }

func (admitFixture) DialHook(n redis.DialHook) redis.DialHook { return n }
func (admitFixture) ProcessPipelineHook(n redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return n
}
func (h admitFixture) ProcessHook(_ redis.ProcessHook) redis.ProcessHook {
	return func(_ context.Context, c redis.Cmder) error {
		switch c.Name() {
		case "evalsha":
			c.(*redis.Cmd).SetVal(int64(1))
		case "eval":
			c.(*redis.Cmd).SetVal(int64(0))
		case "getdel":
			c.(*redis.StringCmd).SetVal("synthetic:" + c.Args()[1].(string))
		case "get":
			c.(*redis.StringCmd).SetVal(h.seal)
		case "waitaof":
			// T04 waits for one local and zero replica AOF acknowledgements.
			// This fixture models the command shape only; it does not prove
			// Redis AOF durability, which remains a deployment verification.
			c.(*redis.Cmd).SetVal([]interface{}{int64(1), int64(0)})
		case "config":
			c.(*redis.MapStringStringCmd).SetVal(map[string]string{"appendonly": "yes", "appendfsync": "always", "maxmemory-policy": "noeviction", "no-appendfsync-on-rewrite": "no", "aof-load-truncated": "no"})
		default:
			return errors.New("unexpected cache call")
		}
		return nil
	}
}
