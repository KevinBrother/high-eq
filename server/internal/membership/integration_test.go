//go:build integration

package membership

import (
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/api/app"
)

// Run through server/tests/runtime.sh (disposable, migrated PG + Redis).
// Same user row lock as WithSession; do not serialize goroutines in Go.
type lab struct {
	*testing.T
	ctx   context.Context
	db    *pgxpool.Pool
	s     *Service
	user  uuid.UUID
	clock time.Time
}

func setup(t *testing.T) *lab {
	t.Helper()
	l := &lab{T: t, ctx: context.Background(), user: uuid.New(), clock: time.Date(2026, 11, 21, 15, 59, 0, 0, time.UTC)}
	var e error
	l.db, e = pgxpool.New(l.ctx, os.Getenv("DATABASE_URL"))
	l.must(e)
	o, e := redis.ParseURL(os.Getenv("REDIS_URL"))
	l.must(e)
	cache := redis.NewClient(o)
	l.s, e = New(cache)
	l.must(e)
	l.s.now = func() time.Time { return l.clock }
	_, e = l.db.Exec(l.ctx, `insert into users(id,age_confirmed_at) values($1,now())`, l.user)
	l.must(e)
	t.Cleanup(func() {
		_, e := l.db.Exec(l.ctx, `delete from users where id=$1`, l.user)
		if e != nil {
			t.Error(e)
		}
		for _, f := range features {
			cache.Del(l.ctx, counterKey(l.user, f))
		}
		cache.Close()
		l.db.Close()
	})
	return l
}
func (l *lab) must(e error) {
	l.Helper()
	if e != nil {
		l.Fatal(e)
	}
}
func (l *lab) locked(fn func(pgx.Tx) error) error {
	return pgx.BeginFunc(l.ctx, l.db, func(tx pgx.Tx) error {
		if _, e := tx.Exec(l.ctx, "select id from users where id=$1 for update", l.user); e != nil {
			return e
		}
		return fn(tx)
	})
}
func (l *lab) activity(f string) uuid.UUID {
	l.Helper()
	id := uuid.New()
	_, e := l.db.Exec(l.ctx, `insert into activities(id,user_id,kind) values($1,$2,$3)`, id, l.user, f)
	l.must(e)
	return id
}
func (l *lab) begin(id uuid.UUID) (a Attempt, e error) {
	e = l.locked(func(tx pgx.Tx) error { a, e = l.s.Begin(l.ctx, tx, l.user, id); return e })
	return
}
func (l *lab) start(id uuid.UUID) uuid.UUID {
	l.Helper()
	a, e := l.begin(id)
	l.must(e)
	if !a.Work {
		l.Fatal(a)
	}
	return a.Token
}
func (l *lab) save(tx pgx.Tx, id uuid.UUID, f string) error {
	if f == "practice" {
		_, e := tx.Exec(l.ctx, `insert into practice_messages(activity_id,kind,client_message_id,seq,role,content_enc) values($1,'practice',$2,1,'assistant',$3)`, id, uuid.New(), []byte("approved fixture"))
		return e
	}
	_, e := tx.Exec(l.ctx, `update activities set content_enc=$2 where id=$1`, id, []byte("approved fixture"))
	return e
}
func (l *lab) approve(id, token uuid.UUID, f string) error {
	return l.locked(func(tx pgx.Tx) error {
		return l.s.SaveApproved(l.ctx, tx, l.user, id, token, func(tx pgx.Tx) error { return l.save(tx, id, f) })
	})
}
func (l *lab) finish(id, token uuid.UUID, event Outcome) error {
	return l.locked(func(tx pgx.Tx) error { return l.s.Finish(l.ctx, tx, l.user, id, token, event) })
}
func (l *lab) rights() app.Entitlements {
	l.Helper()
	var v app.Entitlements
	l.must(l.locked(func(tx pgx.Tx) error { var e error; v, e = l.s.Entitlements(l.ctx, tx, l.user); return e }))
	return v
}
func (l *lab) remaining(want ...int) {
	l.Helper()
	v := l.rights()
	for i, n := range want {
		if v.Allowances[i].Remaining == nil || *v.Allowances[i].Remaining != n {
			l.Fatalf("%s: want %d, got %+v", features[i], n, v)
		}
	}
}
func parallel(n int, f func(int) error) []error {
	var wg sync.WaitGroup
	err := make([]error, n)
	for i := range n {
		wg.Go(func() { err[i] = f(i) })
	}
	wg.Wait()
	return err
}

func TestQuotaConcurrency(t *testing.T) {
	l := setup(t)
	ids := make([]uuid.UUID, 12)
	tokens := make([]uuid.UUID, len(ids))
	for i := range ids {
		ids[i] = l.activity("practice")
	}
	errs := parallel(len(ids), func(i int) error { a, e := l.begin(ids[i]); tokens[i] = a.Token; return e })
	winners := 0
	var chosen int
	for i, e := range errs {
		if e == nil {
			winners++
			chosen = i
		} else if !errors.Is(e, ErrLimit) {
			t.Fatal(e)
		}
	}
	if winners != 3 {
		t.Fatalf("admitted %d", winners)
	}
	l.remaining(0, 3, 3)
	id, k := ids[chosen], tokens[chosen]
	for _, e := range parallel(8, func(int) error { return l.approve(id, k, "practice") }) {
		l.must(e)
	}
	var messages, charges int
	l.must(l.db.QueryRow(l.ctx, `select (select count(*) from practice_messages where activity_id=$1),(select count(*) from quota_ledger where activity_id=$1 and refunded_at is null)`, id).Scan(&messages, &charges))
	if messages != 1 || charges != 1 {
		t.Fatal(messages, charges)
	}
	a, e := l.begin(id)
	l.must(e)
	if a.Work || a.Token != k || a.State != "accepted" {
		t.Fatal("reconnect", a)
	}
	for _, e := range parallel(6, func(int) error { return l.finish(id, k, Completed) }) {
		l.must(e)
	}
	l.remaining(0, 3, 3)
}

func TestQuotaOriginalDayAndReplay(t *testing.T) {
	for _, outcome := range []Outcome{Exited, Completed, Failed, Safety, ModerationUnavailable} {
		t.Run(string(outcome), func(t *testing.T) {
			l := setup(t)
			id := l.activity("practice")
			k := l.start(id)
			l.must(l.approve(id, k, "practice"))
			l.remaining(2, 3, 3)
			l.clock = l.clock.Add(2 * time.Minute)
			l.remaining(3, 3, 3)
			today := l.activity("practice")
			l.must(l.approve(today, l.start(today), "practice"))
			for _, e := range parallel(4, func(int) error { return l.finish(id, k, outcome) }) {
				l.must(e)
			}
			l.remaining(2, 3, 3)
			var day string
			var used int
			var refunded bool
			l.must(l.db.QueryRow(l.ctx, `select q.charged_day::text,d.used,q.refunded_at is not null from quota_ledger q join daily_quota_usage d on d.charged_day=q.charged_day and d.user_id=$2 and feature='practice' where q.activity_id=$1`, id, l.user).Scan(&day, &used, &refunded))
			net := 1
			if outcome == Failed || outcome == Safety || outcome == ModerationUnavailable {
				net = 0
			}
			if day != "2026-11-21" || used != net || refunded != (net == 0) {
				t.Fatal(day, used, refunded)
			}
			if outcome == ModerationUnavailable {
				var retry Attempt
				l.must(l.locked(func(tx pgx.Tx) error { var e error; retry, e = l.s.Retry(l.ctx, tx, l.user, id, k); return e }))
				if !retry.Work || retry.Token == k {
					t.Fatal(retry)
				}
				if !errors.Is(l.finish(id, k, Safety), ErrConflict) {
					t.Fatal("stale callback")
				}
				l.must(l.locked(func(tx pgx.Tx) error {
					return l.s.SaveApproved(l.ctx, tx, l.user, id, retry.Token, func(pgx.Tx) error { return nil })
				}))
				l.remaining(1, 3, 3)
			}
		})
	}
}

func TestQuotaPreSaveAndFailures(t *testing.T) {
	l := setup(t)
	for _, f := range features {
		for _, end := range []Outcome{Failed, Safety, ModerationUnavailable, Exited} {
			id := l.activity(f)
			k := l.start(id)
			l.must(l.finish(id, k, end))
			if !errors.Is(l.approve(id, k, f), ErrConflict) {
				t.Fatal("late result", f, end)
			}
			l.remaining(3, 3, 3)
		}
	}
	id := l.activity("practice")
	var owners atomic.Int32
	for _, e := range parallel(8, func(int) error {
		a, e := l.begin(id)
		if a.Work {
			owners.Add(1)
		}
		return e
	}) {
		l.must(e)
	}
	if owners.Load() != 1 {
		t.Fatal("duplicate owner")
	}
	a, e := l.begin(id)
	l.must(e)
	l.clock = l.clock.Add(6 * time.Minute)
	k := l.start(id)
	if k == a.Token || !errors.Is(l.approve(id, a.Token, "practice"), ErrConflict) {
		t.Fatal("expired lease")
	}
	l.must(l.s.cache.Del(l.ctx, counterKey(l.user, "practice")).Err())
	l.remaining(2, 3, 3)
	// A successful Redis increment plus rolled-back PG writes is not a charge.
	fault := errors.New("injected SQL transaction rollback")
	e = l.locked(func(tx pgx.Tx) error {
		if e := l.s.SaveApproved(l.ctx, tx, l.user, id, k, func(tx pgx.Tx) error { return l.save(tx, id, "practice") }); e != nil {
			return e
		}
		return fault
	})
	if !errors.Is(e, fault) {
		t.Fatal(e)
	}
	e = l.locked(func(tx pgx.Tx) error {
		return l.s.SaveApproved(l.ctx, tx, l.user, id, k, func(pgx.Tx) error { return nil })
	})
	if e == nil {
		t.Fatal("missing persisted reply accepted")
	}
	l.must(l.approve(id, k, "practice"))
	l.remaining(2, 3, 3)
	// Closed client: exercise actual Redis error path, not a mocked success.
	online := l.s.cache
	offline := redis.NewClient(online.Options())
	offline.Close()
	l.s.cache = offline
	other := l.activity("reply")
	if _, e = l.begin(other); e == nil || errors.Is(e, ErrLimit) {
		t.Fatal("cache failure admitted / misreported")
	}
	l.must(l.finish(id, k, Safety))
	l.s.cache = online
	l.remaining(3, 3, 3)
	l.must(l.approve(other, l.start(other), "reply"))
	l.remaining(3, 2, 3)
}

func TestQuotaEntitlementExpiry(t *testing.T) {
	l := setup(t)
	for i := 0; i < 3; i++ {
		id := l.activity("review")
		k := l.start(id)
		l.must(l.approve(id, k, "review"))
		l.must(l.approve(id, k, "review"))
	}
	l.remaining(3, 3, 0)
	cap := func(c Capability) error {
		return l.locked(func(tx pgx.Tx) error { return l.s.Require(l.ctx, tx, l.user, c) })
	}
	l.must(cap(ManualMark))
	l.must(cap(History))
	requirePremium := func(active bool) {
		for _, c := range []Capability{Collection, AlignedReplay, EmotionSummary, PersonalPlan} {
			e := cap(c)
			if active && e != nil || !active && !errors.Is(e, ErrForbidden) {
				t.Fatalf("%s (member=%v): %v", c, active, e)
			}
		}
	}
	requirePremium(false)
	end := l.clock.Add(time.Hour)
	order := uuid.New()
	_, e := l.db.Exec(l.ctx, `insert into orders(id,user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,$2,'apple',$3,'test',0,'paid')`, order, l.user, []byte(order.String()))
	l.must(e)
	_, e = l.db.Exec(l.ctx, "insert into entitlements values($1,$2,$3,$4)", order, l.user, l.clock, end)
	l.must(e)
	v := l.rights()
	if v.Tier != "member" || v.ExpiresAt == nil || !v.ExpiresAt.Equal(end) || v.MaxActiveContacts != nil || v.AutoWatchAlertAvailable {
		t.Fatal(v)
	}
	for _, a := range v.Allowances {
		if a.Remaining != nil {
			t.Fatal(a)
		}
	}
	requirePremium(true)
	id := l.activity("review")
	l.must(l.approve(id, l.start(id), "review"))
	var count int
	l.must(l.db.QueryRow(l.ctx, "select count(*) from quota_ledger where activity_id=$1", id).Scan(&count))
	if count != 0 {
		t.Fatal("billed member")
	}
	c1, c2 := uuid.New(), uuid.New()
	_, e = l.db.Exec(l.ctx, `insert into contacts(id,user_id,profile_enc,last_used_at) values($1,$3,'x',now()-interval '1 hour'),($2,$3,'x',null)`, c1, c2, l.user)
	l.must(e)
	l.clock = end
	requirePremium(false)
	v = l.rights()
	if v.Tier != "free" || v.ExpiresAt != nil || v.MaxActiveContacts == nil || *v.MaxActiveContacts != 1 {
		t.Fatal(v)
	}
	check := func(id *uuid.UUID) error {
		return l.locked(func(tx pgx.Tx) error { return l.s.RequireContact(l.ctx, tx, l.user, id) })
	}
	l.must(check(&c1))
	if !errors.Is(check(&c2), ErrForbidden) || !errors.Is(check(nil), ErrForbidden) {
		t.Fatal("inactive or new contact allowed")
	}
	l.must(l.locked(func(tx pgx.Tx) error { return l.s.SelectContact(l.ctx, tx, l.user, c2) }))
	l.must(check(&c2))
	if !errors.Is(check(&c1), ErrForbidden) {
		t.Fatal("switch did not replace")
	}
}

func TestQuotaSaveAfterMidnightAndSourceErasure(t *testing.T) {
	l := setup(t)
	id := l.activity("practice")
	k := l.start(id)
	l.clock = l.clock.Add(2 * time.Minute)
	l.remaining(3, 3, 3)
	l.must(l.approve(id, k, "practice"))
	var day string
	l.must(l.db.QueryRow(l.ctx, "select charged_day::text from quota_ledger where activity_id=$1", id).Scan(&day))
	if day != "2026-11-22" {
		t.Fatal(day)
	}
	l.remaining(2, 3, 3)
	_, e := l.db.Exec(l.ctx, "delete from activities where id=$1", id)
	l.must(e)
	l.remaining(2, 3, 3)
	if e = l.finish(id, k, Safety); !errors.Is(e, pgx.ErrNoRows) {
		t.Fatal("erased activity resurrected", e)
	}
}
