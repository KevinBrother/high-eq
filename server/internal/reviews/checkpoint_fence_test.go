//go:build t23pipe

package reviews

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

func TestCheckpointExpiryFencesHeldWorker(t *testing.T) {
	ctx := t.Context()
	db := openTerminalPipeDB(t)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}

	user, activity, token := uuid.New(), uuid.New(), uuid.New()
	exec(`insert into users(id,age_confirmed_at) values($1,now())`, user)
	exec(`insert into activities(id,user_id,kind,state) values($1,$2,'review','active')`, activity, user)
	exec(`insert into quota_attempts(activity_id,token,state,held_day,valid_until,metered) values($1,$2,'held',current_date,now()+interval '1 hour',true)`, activity, token)
	exec(`insert into review_requests(activity_id,user_id,request_id,input_mac,repair_enc,generated_enc,generated_task,generated_call_id,generated_at) values($1,$2,$3,decode(repeat('23',32),'hex'),'\x726570616972','\x67656e657261746564','scoring',$4,now()-interval '16 minutes')`, activity, user, uuid.New(), uuid.New())

	svc := Service{DB: db}
	if err := svc.purgeExpiredGenerated(ctx); err != nil {
		t.Fatalf("purge expired checkpoint: %v", err)
	}

	var state, attempt string
	var expired, repairCleared bool
	if err := db.QueryRow(ctx, `select a.state,q.state,r.generated_expired,r.repair_enc is null from activities a join quota_attempts q on q.activity_id=a.id join review_requests r on r.activity_id=a.id where a.id=$1`, activity).Scan(&state, &attempt, &expired, &repairCleared); err != nil {
		t.Fatal(err)
	}
	if state != "failed" || attempt != "failed" || !expired || !repairCleared {
		t.Fatalf("expiry did not close held work: activity=%s attempt=%s expired=%v repairCleared=%v", state, attempt, expired, repairCleared)
	}

	cache := redis.NewClient(&redis.Options{})
	defer cache.Close()
	binding := uuid.New()
	exec(`insert into ledger_binding values(true,$1)`, binding)
	cache.AddHook(terminalLedgerHook{binding.String() + ":45"})
	rights, err := membership.New(cache)
	if err != nil {
		t.Fatal(err)
	}
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
	svc.Data = privacy.NewCoordinator(db, ledger, reg)
	if err := svc.persistTerminal(ctx, accounts.Principal{User: user}, activity, token, membership.Failed); !errors.Is(err, membership.ErrConflict) {
		t.Fatalf("stale terminal after expiry: got %v, want membership.ErrConflict", err)
	}
	if err := db.QueryRow(ctx, `select generated_expired from review_requests where activity_id=$1`, activity).Scan(&expired); err != nil {
		t.Fatal(err)
	}
	if !expired {
		t.Fatal("stale terminal cleared the permanent expiry marker")
	}
	wrote := false
	err = pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		return rights.SaveApproved(ctx, tx, user, activity, token, func(tx pgx.Tx) error {
			wrote = true
			_, err := tx.Exec(ctx, `update activities set state='complete',content_enc='\x01' where id=$1`, activity)
			return err
		})
	})
	if !errors.Is(err, membership.ErrConflict) {
		t.Fatalf("stale worker after expiry: got %v, want membership.ErrConflict", err)
	}
	if wrote {
		t.Fatal("stale worker persisted an approved result after expiry")
	}
	var scores, used, charged int
	if err := db.QueryRow(ctx, `select (select count(*) from scores where activity_id=$1),(select coalesce(sum(used),0) from daily_quota_usage where user_id=$2),(select count(*) from quota_ledger where activity_id=$1)`, activity, user).Scan(&scores, &used, &charged); err != nil {
		t.Fatal(err)
	}
	if scores != 0 || used != 0 || charged != 0 {
		t.Fatalf("expiry allowed settlement: scores=%d used=%d charged=%d", scores, used, charged)
	}
}

// This pipe test needs one successful T06 quota lookup before it can reach
// the final record fence. It is not a Redis ledger/durability test.
type oneReviewQuota struct {
	terminalLedgerHook
	key    string
	called bool
}

func (h *oneReviewQuota) ProcessHook(next redis.ProcessHook) redis.ProcessHook {
	return func(ctx context.Context, c redis.Cmder) error {
		if c.Name() != "evalsha" {
			return h.terminalLedgerHook.ProcessHook(next)(ctx, c)
		}
		args := c.Args()
		if h.called || len(args) != 8 || args[3] != h.key || args[4] != 0 || args[5] != 3 || args[6] != 1 {
			return errors.New("unexpected review quota lookup")
		}
		h.called = true
		c.(*redis.Cmd).SetVal(int64(2)) // three free, zero used, one provisional reservation
		return nil
	}
}

func TestSaveApprovedRejectsExpiredCheckpoint(t *testing.T) {
	ctx := t.Context()
	db := openTerminalPipeDB(t)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}

	user, activity, token := uuid.New(), uuid.New(), uuid.New()
	exec(`insert into users(id,age_confirmed_at) values($1,now())`, user)
	exec(`insert into activities(id,user_id,kind,state) values($1,$2,'review','active')`, activity, user)
	exec(`insert into quota_attempts(activity_id,token,state,held_day,valid_until,metered) values($1,$2,'held',current_date,now()+interval '1 hour',true)`, activity, token)
	exec(`insert into review_requests(activity_id,user_id,request_id,input_mac,generated_expired) values($1,$2,$3,decode(repeat('23',32),'hex'),true)`, activity, user, uuid.New())

	cache := redis.NewClient(&redis.Options{})
	defer cache.Close()
	quota := &oneReviewQuota{key: "quota:v1:" + user.String() + ":review"}
	cache.AddHook(quota)
	rights, err := membership.New(cache)
	if err != nil {
		t.Fatal(err)
	}
	svc := Service{Rights: rights}
	wrote := false
	err = pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
		var locked uuid.UUID
		if err := tx.QueryRow(ctx, `select id from users where id=$1 for update`, user).Scan(&locked); err != nil {
			return err
		}
		return svc.approveReview(ctx, tx, user, activity, token, func(tx pgx.Tx) error {
			wrote = true
			_, err := tx.Exec(ctx, `update activities set state='complete',content_enc='\x01' where id=$1`, activity)
			return err
		})
	})
	if !errors.Is(err, membership.ErrConflict) {
		t.Fatalf("expired checkpoint settlement: got %v, want membership.ErrConflict", err)
	}
	if !quota.called {
		t.Fatal("did not reach the metered admission path")
	}
	if wrote {
		t.Fatal("expired checkpoint reached the approved-result writer")
	}
	var state, attempt string
	var scores, used, charged int
	if err := db.QueryRow(ctx, `select a.state,q.state,
(select count(*) from scores where activity_id=a.id),
(select coalesce(sum(used),0) from daily_quota_usage where user_id=a.user_id),
(select count(*) from quota_ledger where activity_id=a.id)
from activities a join quota_attempts q on q.activity_id=a.id where a.id=$1`, activity).Scan(&state, &attempt, &scores, &used, &charged); err != nil {
		t.Fatal(err)
	}
	if state != "active" || attempt != "held" || scores != 0 || used != 0 || charged != 0 {
		t.Fatalf("expiry fence changed state or ledger: state=%s attempt=%s scores=%d used=%d charged=%d", state, attempt, scores, used, charged)
	}
}

func TestPurgeExpiredGeneratedRollsBackClosingFailure(t *testing.T) {
	ctx := t.Context()
	db := openTerminalPipeDB(t)
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.Exec(ctx, q, args...); err != nil {
			t.Fatal(err)
		}
	}

	user, activity, token := uuid.New(), uuid.New(), uuid.New()
	exec(`insert into users(id,age_confirmed_at) values($1,now())`, user)
	exec(`insert into activities(id,user_id,kind,state) values($1,$2,'review','active')`, activity, user)
	exec(`insert into quota_attempts(activity_id,token,state,held_day,valid_until,metered) values($1,$2,'held',current_date,now()+interval '1 hour',true)`, activity, token)
	exec(`insert into review_requests(activity_id,user_id,request_id,input_mac,repair_enc,generated_enc,generated_task,generated_call_id,generated_at) values($1,$2,$3,decode(repeat('23',32),'hex'),'\x726570616972','\x67656e657261746564','scoring',$4,now()-interval '16 minutes')`, activity, user, uuid.New(), uuid.New())
	exec(`create or replace function t23_fail_expiry_close() returns trigger language plpgsql as $$ begin raise exception 'synthetic expiry close failure'; end $$`)
	exec(`create trigger t23_fail_expiry_close before update of state on activities for each row when (new.state='failed') execute function t23_fail_expiry_close()`)
	t.Cleanup(func() {
		_, _ = db.Exec(context.Background(), `drop trigger if exists t23_fail_expiry_close on activities`)
		_, _ = db.Exec(context.Background(), `drop function if exists t23_fail_expiry_close()`)
	})

	svc := Service{DB: db}
	if err := svc.purgeExpiredGenerated(ctx); err == nil {
		t.Fatal("expiry close failure was not reported")
	}
	var state, attempt string
	var generated, expired, repairRetained bool
	if err := db.QueryRow(ctx, `select a.state,q.state,r.generated_enc is not null,r.generated_expired,r.repair_enc is not null
from activities a join quota_attempts q on q.activity_id=a.id join review_requests r on r.activity_id=a.id
where a.id=$1`, activity).Scan(&state, &attempt, &generated, &expired, &repairRetained); err != nil {
		t.Fatal(err)
	}
	if state != "active" || attempt != "held" || !generated || expired || !repairRetained {
		t.Fatalf("failed expiry was not atomic: state=%s attempt=%s generated=%v expired=%v repairRetained=%v", state, attempt, generated, expired, repairRetained)
	}
}
