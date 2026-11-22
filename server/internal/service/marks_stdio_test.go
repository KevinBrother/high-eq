//go:build marks_stdio

package service

import (
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"sync"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/marks"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

// These responses stand in ONLY for isolated Redis. Do not use this driver
// to claim multi-backend row contention, Redis durability or TCP coverage.
type markCache struct {
	seal    string
	tickets sync.Map
}

func (*markCache) DialHook(h redis.DialHook) redis.DialHook { return h }
func (*markCache) ProcessPipelineHook(h redis.ProcessPipelineHook) redis.ProcessPipelineHook {
	return h
}
func (h *markCache) ProcessHook(_ redis.ProcessHook) redis.ProcessHook {
	return func(_ context.Context, c redis.Cmder) error {
		args := c.Args()
		switch c.Name() {
		case "set":
			h.tickets.Store(args[1], args[2])
			c.(*redis.StatusCmd).SetVal("OK")
		case "getdel":
			v, ok := h.tickets.LoadAndDelete(args[1])
			if !ok {
				return redis.Nil
			}
			c.(*redis.StringCmd).SetVal(v.(string))
		case "config":
			c.(*redis.MapStringStringCmd).SetVal(map[string]string{"appendonly": "yes", "appendfsync": "always", "maxmemory-policy": "noeviction", "no-appendfsync-on-rewrite": "no", "aof-load-truncated": "no"})
		case "get":
			c.(*redis.StringCmd).SetVal(h.seal)
		case "eval":
			c.(*redis.Cmd).SetVal(int64(0))
		case "waitaof":
			c.(*redis.Cmd).SetVal([]any{int64(1), int64(0)})
		case "evalsha":
			c.(*redis.Cmd).SetVal(int64(args[5].(int) - args[4].(int))) // T06 reconciled PG total
		default:
			return fmt.Errorf("unexpected Redis command: %s", c.Name())
		}
		return nil
	}
}

func TestT32APostgresStdio(t *testing.T) {
	if os.Getenv("PGLITE") == "" {
		t.Fatal("set PGLITE to an installed @electric-sql/pglite@0.3.2 directory")
	}
	ctx := t.Context()
	must := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	cmd := exec.CommandContext(ctx, "node", "testdata/marks-pg.mjs")
	cmd.Stderr = os.Stderr
	in, e := cmd.StdinPipe()
	must(e)
	out, e := cmd.StdoutPipe()
	must(e)
	must(cmd.Start())
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	client, pipe := net.Pipe()
	defer pipe.Close()
	go func() { _, _ = io.Copy(in, pipe); _ = in.Close() }()
	go func() { _, _ = io.Copy(pipe, out); _ = pipe.Close() }()
	cfg, e := pgxpool.ParseConfig("postgres://fixture@127.0.0.1/fixture?sslmode=disable")
	must(e)
	cfg.MaxConns = 1
	cfg.ConnConfig.DialFunc = func(context.Context, string, string) (net.Conn, error) { return client, nil }
	db, e := pgxpool.NewWithConfig(ctx, cfg)
	must(e)
	defer db.Close()
	var version string
	must(db.QueryRow(ctx, `select version()`).Scan(&version))
	t.Log(version)
	id := uuid.New()
	_, e = db.Exec(ctx, `insert into ledger_binding values(true,$1)`, id)
	must(e)
	cache := redis.NewClient(&redis.Options{})
	defer cache.Close()
	cache.AddHook(&markCache{seal: id.String() + ":45"})
	ledger, e := privacy.BindLedger(ctx, db, cache, 45)
	must(e)
	key := make([]byte, 32)
	_, e = rand.Read(key)
	must(e)
	fields, e := fieldcrypt.New(1, map[uint32][]byte{1: key})
	must(e)
	reg, e := privacy.NewRegistry([]string{"manual_marks", "accounts"}, marks.Hooks(fields), accounts.Hooks(fields))
	must(e)
	data := privacy.NewCoordinator(db, ledger, reg)
	sms, exchange, e := accounts.DevelopmentProviders("development", cache)
	must(e)
	auth, e := accounts.New(db, data, fields, key, sms, exchange)
	must(e)
	rights, e := membership.New(cache)
	must(e)
	rt := &Runtime{Accounts: auth, cache: cache, db: db, Membership: rights, Fields: fields, Data: data, Marks: &marks.Service{DB: db, Fields: fields, Data: data}}
	router := rt.Router()
	exerciseMarks(t, rt, "http://fixture.invalid", func(r *http.Request) (*http.Response, error) {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w.Result(), nil
	})
}
