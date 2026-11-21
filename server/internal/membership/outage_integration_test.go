//go:build integration

package membership

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

// The runtime.sh driver keeps SQL online and STOPS the ordinary Redis between
// two separate test processes. No real account IDs or shared development DB.
func TestQuotaCacheOutage(t *testing.T) {
	phase := os.Getenv("T06_CACHE_PHASE")
	if phase == "" {
		t.Skip("driven across cache stop/start by runtime.sh")
	}
	user, e := uuid.Parse(os.Getenv("T06_TEST_USER"))
	if e != nil {
		t.Fatal(e)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	db, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	options, e := redis.ParseURL(os.Getenv("REDIS_URL"))
	if e != nil {
		t.Fatal(e)
	}
	options.MaxRetries = -1
	options.DialTimeout = time.Second
	cache := redis.NewClient(options)
	defer cache.Close()
	s, e := New(cache)
	if e != nil {
		t.Fatal(e)
	}
	l := &lab{T: t, ctx: ctx, db: db, s: s, user: user}
	id := user // disposable fixture uses the same UUID in two independent tables
	switch phase {
	case "prime":
		_, e := db.Exec(ctx, `insert into users(id,age_confirmed_at) values($1,now())`, user)
		l.must(e)
		_, e = db.Exec(ctx, `insert into activities(id,user_id,kind) values($1,$1,'practice')`, id)
		l.must(e)
		l.must(l.approve(id, l.start(id), "practice"))
		l.remaining(2, 3, 3)
	case "down":
		if cache.Ping(ctx).Err() == nil {
			t.Fatal("cache is still serving")
		}
		other := l.activity("reply")
		if _, e := l.begin(other); e == nil || errors.Is(e, ErrLimit) {
			t.Fatal("outage admitted work or returned 429")
		}
		var k uuid.UUID
		l.must(db.QueryRow(ctx, `select token from quota_attempts where activity_id=$1`, id).Scan(&k))
		l.must(l.finish(id, k, ModerationUnavailable))
		l.must(l.finish(id, k, ModerationUnavailable))
		l.must(l.locked(func(tx pgx.Tx) error { return s.Require(ctx, tx, user, ManualMark) }))
	case "restored":
		l.remaining(3, 3, 3)
		var used int
		l.must(db.QueryRow(ctx, `select sum(used) from daily_quota_usage where user_id=$1`, user).Scan(&used))
		if used != 0 {
			t.Fatal("refund was lost", used)
		}
		_, e := db.Exec(ctx, `delete from users where id=$1`, user)
		l.must(e)
	default:
		t.Fatal("unexpected cache phase")
	}
}
