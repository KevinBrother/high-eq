//go:build integration

package privacy

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// Run only in the disposable T04 compose project; this test changes ledger settings.
func TestPrivacyProtocol(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	db, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	must(t, e)
	defer db.Close()
	opt, e := redis.ParseURL(os.Getenv("LEDGER_URL"))
	must(t, e)
	r := redis.NewClient(opt)
	defer r.Close()
	l, e := BindLedger(ctx, db, r, 45)
	must(t, e)
	var failDel, failExport bool
	var entered, release, deleting, allowDelete chan struct{}
	module := Module{Name: "training", Delete: func(ctx context.Context, tx pgx.Tx, d Deletion) error {
		if deleting != nil {
			close(deleting)
			select {
			case <-allowDelete:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		if failDel {
			return errors.New("injected hook failure")
		}
		return nil
	}, Export: func(ctx context.Context, tx pgx.Tx, q ExportRequest, emit Emit) error {

		rows, e := tx.Query(ctx, `select a.source_id from activities a join growth_scores g on g.score_id=a.source_id where a.user_id=$1`, q.UserID)
		if e != nil {
			return e
		}
		defer rows.Close()
		for rows.Next() {
			var id string
			if e := rows.Scan(&id); e != nil {
				return e
			}
			if e := emit(id); e != nil {
				return e
			}
		}
		if failExport {
			return errors.New("export failed after writing records")
		}
		return rows.Err()
	}}
	reg, e := NewRegistry([]string{"training"}, module)
	must(t, e)
	c := NewCoordinator(db, l, reg)
	var srcCalls int
	consume := func(ctx context.Context, tx pgx.Tx, s ScoreSource) error {
		srcCalls++
		if entered != nil {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		if string(s.Detail) != "source fixture" {
			return errors.New("consumer used untrusted payload")
		}
		_, e := tx.Exec(ctx, `insert into growth_scores values($1,$2,'a','b') on conflict do nothing`, s.SourceID, s.Kind)
		return e
	}
	var user, purge uuid.UUID
	must(t, db.QueryRow(ctx, `insert into users(age_confirmed_at) values(now()) returning id,purge_id`).Scan(&user, &purge))
	add := func(age string) ScoreKey {
		t.Helper()
		s := ScoreKey{UserID: user, Kind: "review"}
		must(t, db.QueryRow(ctx, `insert into activities(user_id,kind,state) values($1,'review','complete') returning id,source_id`, user).Scan(&s.ActivityID, &s.SourceID))
		must(t, db.QueryRow(ctx, `insert into scores values($1,$2,'review','source fixture',now()-$3::interval) returning occurred_at`, s.SourceID, s.ActivityID, age).Scan(&s.OccurredAt))
		return s
	}
	old := add("31 days")
	fresh := add("1 day")
	bad := fresh
	bad.UserID = uuid.New()
	wrong := fresh
	wrong.ActivityID = uuid.New()
	for _, s := range []ScoreKey{old, bad, wrong} {
		if e := c.ConsumeScore(ctx, s, consume); e == nil {
			t.Fatal("invalid replay")
		}
	}
	old.OccurredAt = time.Now()
	if e := c.ConsumeScore(ctx, old, consume); e == nil {
		t.Fatal("redelivery refreshed window")
	}
	if srcCalls != 0 {
		t.Fatal("invalid callback")
	}
	exp := ExportRequest{OperationID: uuid.New(), UserID: user}
	export := func() (string, error) {
		var b bytes.Buffer
		e := c.Export(ctx, exp, &b)
		if e != nil {
			if _, err := zip.NewReader(bytes.NewReader(b.Bytes()), int64(b.Len())); err == nil {
				t.Fatal("completed ZIP on failure")
			}
			return "", e
		}
		z, e := zip.NewReader(bytes.NewReader(b.Bytes()), int64(b.Len()))
		if e != nil {
			return "", e
		}
		if len(z.File) != 1 || z.File[0].Name != "training.json" {
			t.Fatal("wrong partitions")
		}
		f, e := z.File[0].Open()
		if e != nil {
			return "", e
		}
		defer f.Close()
		p, e := io.ReadAll(f)
		return string(p), e
	}
	must(t, c.ConsumeScore(ctx, fresh, consume))
	must(t, c.ConsumeScore(ctx, fresh, consume))
	out, e := export()
	must(t, e)
	if !bytes.Contains([]byte(out), []byte(fresh.SourceID.String())) {
		t.Fatal("missing live projection")
	}
	failExport = true
	if _, e := export(); e == nil {
		t.Fatal("partial archive")
	}
	failExport = false
	// Hold a real consumer transaction open. Wait for the DELETE connection to be blocked by PG, not just a sleeping goroutine.
	entered = make(chan struct{})
	release = make(chan struct{})
	a, b := make(chan error, 1), make(chan error, 1)
	go func() { a <- c.ConsumeScore(ctx, fresh, consume) }()
	select {
	case <-entered:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	d := Deletion{OperationID: uuid.New(), UserID: user, Scope: "reviews", SourceID: fresh.SourceID}
	go func() { b <- c.Delete(ctx, d) }()
	waitLock(t, ctx, db)
	close(release)
	must(t, <-a)
	must(t, <-b)
	entered = nil
	must(t, c.Delete(ctx, d))
	if e := c.ConsumeScore(ctx, fresh, consume); e == nil {
		t.Fatal("refilled deleted score")
	}
	out, e = export()
	must(t, e)
	if out != "[]" {
		t.Fatal(out)
	}
	// Reverse the lock order in time: DELETE owns the account lock first.
	firstDelete := add("1 day")
	d.SourceID = firstDelete.SourceID
	deleting, allowDelete = make(chan struct{}), make(chan struct{})
	go func() { b <- c.Delete(ctx, d) }()
	select {
	case <-deleting:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	go func() { a <- c.ConsumeScore(ctx, firstDelete, consume) }()
	waitLock(t, ctx, db)
	close(allowDelete)
	must(t, <-b)
	if <-a == nil {
		t.Fatal("consumer raced past deletion")
	}
	deleting = nil
	// Intact restored SQL source but only an independent tombstone (no SQL intent).
	restored := add("1 day")
	must(t, l.mark(ctx, []uuid.UUID{restored.SourceID}))
	if e := c.ConsumeScore(ctx, restored, consume); !errors.Is(e, ErrHidden) {
		t.Fatal("missed ledger-only guard", e)
	}
	if _, e := export(); !errors.Is(e, ErrHidden) {
		t.Fatal("restored data exported", e)
	}
	must(t, c.Resume(ctx))
	var remains bool
	must(t, db.QueryRow(ctx, `select exists(select 1 from scores where id=$1)`, restored.SourceID).Scan(&remains))
	if remains {
		t.Fatal("resume skipped restored tombstone")
	}
	// Independent registration survives failed SQL cleanup; retry through a new coordinator.
	f := add("1 day")
	d.SourceID = f.SourceID
	failDel = true
	if e := c.Delete(ctx, d); e == nil {
		t.Fatal("failed hook committed")
	}
	key := "deleted:" + f.SourceID.String()
	v, e := r.Get(ctx, key).Result()
	must(t, e)
	ttl, e := r.TTL(ctx, key).Result()
	must(t, e)
	if v != "" || ttl < 45*24*time.Hour-time.Minute {
		t.Fatal("invalid tombstone")
	}
	if _, e := export(); e == nil {
		t.Fatal("pending source exported")
	}
	if e := c.ConsumeScore(ctx, f, consume); e == nil {
		t.Fatal("pending source consumed")
	}
	if e := c.Access(ctx, user, func(pgx.Tx) error { t.Fatal("pending account read"); return nil }); !errors.Is(e, ErrHidden) {
		t.Fatal(e)
	}
	var exists bool
	must(t, db.QueryRow(ctx, `select exists(select 1 from scores where id=$1)`, f.SourceID).Scan(&exists))
	if !exists {
		t.Fatal("hook failure did not roll back SQL")
	}
	failDel = false
	c = NewCoordinator(db, l, reg)
	must(t, c.Resume(ctx))
	out, e = export()
	must(t, e)
	if out != "[]" {
		t.Fatal(out)
	}
	if _, e := BindLedger(ctx, db, r, 90); e == nil {
		t.Fatal("silently extended backup window")
	}
	// Reachable but unsafe, then a ledger that has lost its identity.
	identity, e := r.GetDel(ctx, sealKey).Result()
	must(t, e)
	if _, e := BindLedger(ctx, db, r, 45); e == nil {
		t.Fatal("re-enrolled a missing ledger")
	}
	if _, e := export(); e == nil {
		t.Fatal("missing identity allowed export")
	}
	must(t, r.Set(ctx, sealKey, identity, 0).Err())
	must(t, r.ConfigSet(ctx, "maxmemory-policy", "allkeys-lru").Err())
	if _, e := export(); e == nil {
		t.Fatal("unsafe registry exported")
	}
	d.SourceID = old.SourceID
	if e := c.Delete(ctx, d); e == nil {
		t.Fatal("unsafe registry allowed delete")
	}
	must(t, r.ConfigSet(ctx, "maxmemory-policy", "noeviction").Err())
	if _, e := export(); !errors.Is(e, ErrHidden) {
		t.Fatal("lost intent on ledger outage", e)
	}
	must(t, c.Resume(ctx))
	pending := uuid.New()
	_, e = db.Exec(ctx, `insert into activities(user_id,source_id,kind) values($1,$2,'practice')`, user, pending)
	must(t, e)
	live := add("1 day")
	must(t, c.Delete(ctx, Deletion{OperationID: uuid.New(), UserID: user, Scope: "account"}))
	for _, id := range []uuid.UUID{pending, purge, old.SourceID, live.SourceID} {
		n, e := r.Exists(ctx, "deleted:"+id.String()).Result()
		must(t, e)
		if n != 1 {
			t.Fatal("missing account tombstone")
		}
	}
	if e := c.ConsumeScore(ctx, live, consume); e == nil {
		t.Fatal("revived account")
	}
	if _, e := export(); e == nil {
		t.Fatal("revived export")
	}
}
func must(t *testing.T, e error) {
	t.Helper()
	if e != nil {
		t.Fatal(e)
	}
}
func waitLock(t *testing.T, ctx context.Context, p *pgxpool.Pool) {
	t.Helper()
	until := time.Now().Add(5 * time.Second)
	for time.Now().Before(until) {
		var blocked bool
		must(t, p.QueryRow(ctx, `select exists(select 1 from pg_stat_activity where datname=current_database() and cardinality(pg_blocking_pids(pid))>0)`).Scan(&blocked))
		if blocked {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("no PG lock contention observed")
}

// Exercised by runtime.sh only after it has actually stopped the ledger container.
func TestOfflineLedger(t *testing.T) {
	if os.Getenv("T04_LEDGER_OFFLINE") != "1" {
		t.Skip("requires stopped test ledger")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	p, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	must(t, e)
	defer p.Close()
	opts, e := redis.ParseURL(os.Getenv("LEDGER_URL"))
	must(t, e)
	opts.MaxRetries = -1
	opts.DialTimeout = 100 * time.Millisecond
	opts.DialerRetries = 1
	r := redis.NewClient(opts)
	defer r.Close()
	if r.Ping(ctx).Err() == nil {
		t.Fatal("test requires offline ledger")
	}
	l := &Ledger{r: r, ttl: 45 * 24 * time.Hour}
	must(t, p.QueryRow(ctx, `select ledger_id from ledger_binding`).Scan(&l.id))
	var u, a, s uuid.UUID
	var at time.Time
	must(t, p.QueryRow(ctx, `insert into users(age_confirmed_at) values(now()) returning id`).Scan(&u))
	must(t, p.QueryRow(ctx, `insert into activities(user_id,kind,state) values($1,'review','complete') returning id,source_id`, u).Scan(&a, &s))
	must(t, p.QueryRow(ctx, `insert into scores values($1,$2,'review','fixture',now()) returning occurred_at`, s, a).Scan(&at))
	reg, e := NewRegistry([]string{"test"}, Module{Name: "test", Delete: func(context.Context, pgx.Tx, Deletion) error { t.Fatal("offline delete callback"); return nil }, Export: func(context.Context, pgx.Tx, ExportRequest, Emit) error {
		t.Fatal("offline export callback")
		return nil
	}})
	must(t, e)
	c := NewCoordinator(p, l, reg)
	if e := c.ConsumeScore(ctx, ScoreKey{u, a, s, "review", at}, func(context.Context, pgx.Tx, ScoreSource) error { t.Fatal("offline consumer"); return nil }); e == nil {
		t.Fatal("offline replay acknowledged")
	}
	if e := c.Export(ctx, ExportRequest{uuid.New(), u}, io.Discard); e == nil {
		t.Fatal("offline export acknowledged")
	}
	if e := c.Delete(ctx, Deletion{uuid.New(), u, s, "reviews"}); e == nil {
		t.Fatal("offline delete acknowledged")
	}
	var pending bool
	must(t, p.QueryRow(ctx, `select exists(select 1 from scores join pending_erasure on root_id=id where id=$1)`, s).Scan(&pending))
	if !pending {
		t.Fatal("expected durable intent and retained SQL source")
	}
}
