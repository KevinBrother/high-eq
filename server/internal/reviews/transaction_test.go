//go:build t23pipe

package reviews_test

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"high-eq/server/internal/reviews"
	"high-eq/server/internal/service"
	"io"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

type runFunc func(context.Context, gateway.Call) (gateway.Reply, error)

func (f runFunc) Run(ctx context.Context, c gateway.Call) (gateway.Reply, error) { return f(ctx, c) }

func TestReviewSQLTransactions(t *testing.T) {
	ctx := t.Context()
	db := openPipeDB(t)
	must := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	exec := func(q string, args ...any) { t.Helper(); _, e := db.Exec(ctx, q, args...); must(e) }
	var u uuid.UUID
	model := uuid.New()
	exec(`insert into model_configs(id,name,endpoint,api_key_enc) values($1,'fixture','https://invalid.test','synthetic')`, model)
	cache := redis.NewClient(&redis.Options{})
	defer cache.Close()
	binding := uuid.New()
	exec(`insert into ledger_binding values(true,$1)`, binding)
	cache.AddHook(admitFixture{binding.String() + ":45"})
	rights, e := membership.New(cache)
	must(e)
	f, e := fieldcrypt.New(1, map[uint32][]byte{1: bytes.Repeat([]byte{23}, 32)})
	must(e)
	ledger, e := privacy.BindLedger(ctx, db, cache, 45)
	must(e)
	reg, e := privacy.NewRegistry([]string{"reviews"}, reviews.Hooks(f))
	must(e)
	dbs := privacy.NewCoordinator(db, ledger, reg)
	sms, exchange, e := accounts.DevelopmentProviders("development", cache)
	must(e)
	auth, e := accounts.New(db, dbs, f, bytes.Repeat([]byte{23}, 32), sms, exchange)
	must(e)
	s := reviews.Service{Accounts: auth, Data: dbs, DB: db, Fields: f, Rights: rights, Bus: events.New(dbs, reviews.Decoder(f)), Key: []byte("synthetic")}
	const good = `{"safety_flag":false,"mode":"express","nvc":{"observation":{"score":15,"reason":"合成原因"},"feeling":{"score":0,"reason":"未表达"},"need":{"score":0,"reason":"未说明"},"request":{"score":5,"reason":"未明确"},"total":20},"emotion":{"read_others":{"level":2,"reason":"未确认"},"self_management":{"level":3,"reason":"平静"},"relationship":{"level":2,"reason":"可能误会"}},"better_version":"可以说说吗？","why_better":"具体","target_turn":1}`
	var stages []gateway.Task
	var analysisModels, scoringModels, analysisReplays, scoringReplays int
	mode := "normal"
	recordCall := func(call gateway.Call, id uuid.UUID, outcome string) {
		exec(`insert into ai_calls(id,user_id,activity_id,operation_id,task,model_id,outcome) values($1,$2,$3,$4,$5,$6,$7)`, id, u, call.Activity, call.Operation, call.Task, model, outcome)
	}
	s.Router = func(stop gateway.Stop) (scoring.Runner, error) {
		return runFunc(func(c context.Context, call gateway.Call) (gateway.Reply, error) {
			stages = append(stages, call.Task)
			raw := `{"repair_phrase":"我刚才打断了你，可以继续说吗？"}`
			id := uuid.New()
			if call.Task == gateway.ReviewAnalysis {
				if mode == "analysis-output-outage" {
					if call.Generated != nil {
						analysisReplays++
						if call.Generated.Task != gateway.ReviewAnalysis || call.OnGenerated != nil {
							t.Fatalf("invalid analysis replay hooks: %+v", call)
						}
						return gateway.Reply{Result: gateway.Result{Object: []byte(raw)}, CallID: call.Generated.CallID}, nil
					}
					analysisModels++
					recordCall(call, id, "moderation_unavailable")
					if call.OnGenerated == nil {
						t.Fatal("analysis output hook missing")
					}
					if e := call.OnGenerated(c, id, raw); e != nil {
						return gateway.Reply{}, e
					}
					term := gateway.Terminal{Code: "moderation_unavailable"}
					return gateway.Reply{Terminal: &term}, nil
				}
				analysisModels++
				recordCall(call, id, "ok")
				return gateway.Reply{Result: gateway.Result{Object: []byte(raw)}, CallID: id}, nil
			}
			raw = good
			if mode == "scoring-output-outage" {
				if call.Generated != nil {
					scoringReplays++
					if call.Generated.Task != gateway.Scoring || call.OnGenerated != nil {
						t.Fatalf("invalid scoring replay hooks: %+v", call)
					}
					return gateway.Reply{Result: gateway.Result{Object: []byte(raw)}, CallID: call.Generated.CallID}, nil
				}
				scoringModels++
				recordCall(call, id, "moderation_unavailable")
				if call.OnGenerated == nil {
					t.Fatal("scoring output hook missing")
				}
				if e := call.OnGenerated(c, id, raw); e != nil {
					return gateway.Reply{}, e
				}
				term := gateway.Terminal{Code: "moderation_unavailable"}
				return gateway.Reply{Terminal: &term}, nil
			}
			if mode == "withdraw-before-checkpoint" {
				// The model has returned a complete object, but consent is revoked
				// before the gateway can save the unmoderated checkpoint.
				exec(`update consents set withdrawn_at=clock_timestamp() where user_id=$1 and purpose='review' and withdrawn_at is null`, u)
			}
			if mode == "withdraw-before-scoring" {
				exec(`update consents set withdrawn_at=clock_timestamp() where user_id=$1 and purpose='review' and withdrawn_at is null`, u)
				if call.BeforeGenerate == nil {
					t.Fatal("pre-generation authorization hook missing")
				}
				if e := call.BeforeGenerate(c); e != nil {
					return gateway.Reply{}, e
				}
			}
			scoringModels++
			if mode == "withdraw-before-checkpoint" {
				if call.OnGenerated == nil {
					t.Fatal("pre-checkpoint save hook missing")
				}
				return gateway.Reply{}, call.OnGenerated(c, id, raw)
			}
			switch mode {
			case "outage", "crisis":
				term := gateway.Terminal{Safety: mode == "crisis"}
				if !term.Safety {
					term.Code = "moderation_unavailable"
				}
				return gateway.Reply{Terminal: &term}, errors.Join(stop(c, call.Scope, term), errors.New("simulated telemetry error"))
			case "bad-link":
				// Return a call ID that was never inserted so score association fails.
				return gateway.Reply{Result: gateway.Result{Object: []byte(raw)}, CallID: id}, nil
			}
			recordCall(call, id, "ok")
			return gateway.Reply{Result: gateway.Result{Object: []byte(raw)}, CallID: id}, nil
		}), nil
	}
	rt := service.Runtime{Accounts: auth, Membership: rights, Reviews: &s, Fields: f, Bus: s.Bus, Data: dbs}
	router := rt.Router()
	var token string
	httpJSON := func(method, path string, in any, code int) []byte {
		t.Helper()
		b, _ := json.Marshal(in)
		req := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		if w.Code != code {
			t.Fatalf("%s %s: expected %d, got %d %s", method, path, code, w.Code, w.Body.Bytes())
		}
		return w.Body.Bytes()
	}
	login := func(proof string) app.Tokens {
		var tok app.Tokens
		must(json.Unmarshal(httpJSON("POST", "auth/login", map[string]any{"credential": map[string]string{"provider": "apple", "proof": proof}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"}, 200), &tok))
		return tok
	}
	owner := login("t23-a")
	other := login("t23-b")
	token = owner.AccessToken
	u = owner.UserId
	in := app.ReviewInput{RequestId: uuid.New(), Happened: "SYNTHETIC-T23", MyFeeling: "着急", TheirPossibleFeeling: "可能委屈", MyAction: "打断发言", NextAction: "等对方说完"}
	originalInput := in
	create := func(code int) []byte { return httpJSON("POST", "reviews", in, code) }
	create(403)
	httpJSON("PUT", "me/consents/review", map[string]any{"version": "v1", "granted": true}, 200)
	assertRows := func(scores, used, links, pending int) {
		t.Helper()
		var a, b, c, d int
		must(db.QueryRow(ctx, `select (select count(*) from scores),(select coalesce(sum(used),0) from daily_quota_usage),(select count(*) from ai_calls where score_id is not null),(select count(*) from review_requests where score_pending)`).Scan(&a, &b, &c, &d))
		if a != scores || b != used || c != links || d != pending {
			t.Fatalf("score/usage/links/pending %v", []int{a, b, c, d})
		}
	}
	counts := func() (scores, used int) {
		t.Helper()
		must(db.QueryRow(ctx, `select (select count(*) from scores),(select coalesce(sum(used),0) from daily_quota_usage)`).Scan(&scores, &used))
		return scores, used
	}
	reviewAttemptCounts := func(id uuid.UUID) (requests, attempts int) {
		t.Helper()
		must(db.QueryRow(ctx, `select (select count(*) from review_requests where activity_id=$1),(select count(*) from quota_attempts where activity_id=$1)`, id).Scan(&requests, &attempts))
		return requests, attempts
	}
	mode = "bad-link"
	create(500)
	assertRows(0, 0, 0, 0)
	mode = "crisis"
	in.RequestId = uuid.New()
	var term gateway.Terminal
	must(json.Unmarshal(create(200), &term))
	if !term.Safety || term.Message != gateway.HelpMessage {
		t.Fatal("crisis was not preserved")
	}
	before := len(stages)
	create(200)
	if len(stages) != before {
		t.Fatal("regenerated crisis")
	}
	assertRows(0, 0, 0, 0)
	mode = "outage"
	in.RequestId = uuid.New()
	if !bytes.Contains(create(503), []byte(`"code":"moderation_unavailable"`)) {
		t.Fatal("wrong outage response")
	}
	assertRows(0, 0, 0, 0)
	before = len(stages)
	mode = "normal"
	var r app.Review
	must(json.Unmarshal(create(200), &r))
	if len(stages) != before+1 || stages[before] != gateway.Scoring || r.Score.Nvc.Total != 20 {
		t.Fatal("did not resume checkpoint")
	}
	assertRows(1, 1, 1, 1)
	deletedRequestID := in.RequestId
	create(200)
	if len(stages) != before+1 {
		t.Fatal("duplicate model call")
	}
	in.NextAction = "新内容"
	create(409)
	assertRows(1, 1, 1, 1)
	var event events.Score
	var votes int
	fail := true
	growthSvc := &growth.Service{Fields: f}
	s.Bus.ScoreCompleted.Subscribe(growthSvc.Consume)
	s.Bus.ScoreCompleted.Subscribe(func(c context.Context, tx pgx.Tx, v events.Score) error {
		event = v
		if v.NVC.Total != 20 || v.ActivityID != r.Id || v.SourceID != r.Score.ScoreId {
			return errors.New("wrong canonical event")
		}
		if fail {
			return errors.New("subscriber failure")
		}
		votes++
		return nil
	})
	if s.ReplayPending(ctx) == nil {
		t.Fatal("subscriber failure swallowed")
	}
	assertRows(1, 1, 1, 1)
	var projected int
	must(db.QueryRow(ctx, `select count(*) from growth_scores where score_id=$1`, r.Score.ScoreId).Scan(&projected))
	if projected != 0 {
		t.Fatal("failed subscriber did not roll back growth projection")
	}
	fail = false
	must(s.ReplayPending(ctx))
	must(s.ReplayPending(ctx))
	if votes != 1 {
		t.Fatal("duplicate delivery")
	}
	assertRows(1, 1, 1, 0)
	var nvcEnc, emotionEnc []byte
	must(db.QueryRow(ctx, `select nvc_enc,emotion_enc from growth_scores where score_id=$1 and kind='review'`, r.Score.ScoreId).Scan(&nvcEnc, &emotionEnc))
	raw, e := f.Open(nvcEnc, []byte("growth_scores.nvc_enc/"+r.Score.ScoreId.String()))
	must(e)
	var projectedNVC growth.NVCValues
	must(json.Unmarshal(raw, &projectedNVC))
	if projectedNVC != (growth.NVCValues{Observation: 15, Request: 5, Total: 20}) {
		t.Fatalf("invalid encrypted NVC projection: %+v", projectedNVC)
	}
	raw, e = f.Open(emotionEnc, []byte("growth_scores.emotion_enc/"+r.Score.ScoreId.String()))
	must(e)
	var projectedEmotion growth.EmotionValues
	must(json.Unmarshal(raw, &projectedEmotion))
	if projectedEmotion != (growth.EmotionValues{ReadOthers: 2, SelfManagement: 3, Relationship: 2}) {
		t.Fatalf("invalid encrypted emotion projection: %+v", projectedEmotion)
	}
	duplicate := event
	duplicate.NVC.Observation, duplicate.NVC.Feeling, duplicate.NVC.Need, duplicate.NVC.Request, duplicate.NVC.Total = 25, 25, 25, 25, 100
	duplicate.Emotion.ReadOthers, duplicate.Emotion.SelfManagement, duplicate.Emotion.Relationship = 5, 5, 5
	must(pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error { return growthSvc.Consume(ctx, tx, duplicate) }))
	var replayedNVC, replayedEmotion []byte
	must(db.QueryRow(ctx, `select nvc_enc,emotion_enc from growth_scores where score_id=$1`, r.Score.ScoreId).Scan(&replayedNVC, &replayedEmotion))
	if !bytes.Equal(nvcEnc, replayedNVC) || !bytes.Equal(emotionEnc, replayedEmotion) {
		t.Fatal("duplicate event overwrote encrypted growth projection")
	}
	readExport := func(user uuid.UUID) []byte {
		var buf bytes.Buffer
		must(dbs.Export(ctx, privacy.ExportRequest{UserID: user, OperationID: uuid.New()}, &buf))
		z, e := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
		must(e)
		entry, e := z.Open("reviews.json")
		must(e)
		defer entry.Close()
		data, e := io.ReadAll(entry)
		must(e)
		return data
	}
	if !bytes.Contains(readExport(u), []byte(in.Happened)) || string(readExport(other.UserId)) != "[]" {
		t.Fatal("source export boundary")
	}
	path := "reviews/" + r.Id.String()
	httpJSON("GET", path, nil, 200)
	var page app.ListReviewsResult
	must(json.Unmarshal(httpJSON("GET", "reviews", nil, 200), &page))
	if len(page.Items) != 1 || page.Items[0].Score.ScoreId != r.Score.ScoreId {
		t.Fatal("missing history")
	}
	token = other.AccessToken
	httpJSON("GET", path, nil, 404)
	httpJSON("DELETE", path, nil, 404)
	token = owner.AccessToken
	must(dbs.Access(ctx, u, func(tx pgx.Tx) error {
		var content, detail []byte
		if e = tx.QueryRow(ctx, `select a.content_enc,s.detail_enc from activities a join scores s on s.activity_id=a.id where a.id=$1`, r.Id).Scan(&content, &detail); e != nil {
			return e
		}
		if bytes.Contains(content, []byte(in.Happened)) || bytes.Contains(detail, []byte("合成原因")) {
			t.Fatal("cleartext storage")
		}
		vals, e := reviews.Decoder(f)(privacy.ScoreSource{ScoreKey: privacy.ScoreKey{UserID: u, SourceID: r.Score.ScoreId, Kind: "review"}, Detail: detail})
		if e != nil || vals.NVC.Total != 20 {
			t.Fatal("invalid canonical event", e)
		}
		return nil
	}))
	httpJSON("DELETE", path, nil, 200)
	assertRows(0, 1, 0, 0)
	if e := s.Bus.PublishScore(ctx, event); e == nil {
		t.Fatal("replayed erased source")
	}
	httpJSON("GET", path, nil, 404)
	if bytes.Contains(readExport(u), []byte(in.Happened)) {
		t.Fatal("erasure incomplete")
	}

	// A deleted request key must remain a tombstone. Replaying the original body or
	// reusing the key with edits may not create a new activity, model call or debit.
	in = originalInput
	in.RequestId = deletedRequestID
	var tombstones int
	must(db.QueryRow(ctx, `select count(*) from review_tombstones where user_id=$1 and request_id=$2`, u, in.RequestId).Scan(&tombstones))
	if tombstones != 1 {
		t.Fatalf("deleted request was not tombstoned: %d", tombstones)
	}
	before = len(stages)
	if body := httpJSON("POST", "reviews", in, 409); !bytes.Contains(body, []byte("删除")) {
		t.Fatalf("same deleted input did not report deletion: %s", body)
	}
	if len(stages) != before {
		t.Fatal("deleted request reached upstream")
	}
	in.NextAction = "删除后修改"
	httpJSON("POST", "reviews", in, 409)
	if len(stages) != before {
		t.Fatal("edited deleted request reached upstream")
	}
	assertRows(0, 1, 0, 0)
	var orphan uuid.UUID
	must(db.QueryRow(ctx, `insert into activities(user_id,kind) values($1,'review') returning id`, u).Scan(&orphan))
	tag, e := db.Exec(ctx, `insert into review_requests(activity_id,user_id,request_id,input_mac) values($1,$2,$3,decode(repeat('23',32),'hex'))`, orphan, u, in.RequestId)
	must(e)
	if tag.RowsAffected() != 0 {
		t.Fatal("review request insert bypassed tombstone")
	}
	exec(`delete from activities where id=$1`, orphan)

	// Recheck linked sources after the approved checkpoint and immediately before
	// scoring. Expiring a mark at checkpoint commit must stop the score call.
	var mark uuid.UUID
	must(db.QueryRow(ctx, `insert into manual_marks(user_id,mark_enc) values($1,'\x73796e'::bytea) returning id`, u).Scan(&mark))
	in = originalInput
	in.RequestId = uuid.New()
	in.MarkId = &mark
	exec(`create or replace function t23_expire_checkpoint_mark() returns trigger language plpgsql as $$ begin update manual_marks set accepted_at=now()-interval '181 days' where user_id=new.user_id and id=new.mark_id; return new; end $$`)
	exec(`create trigger t23_expire_checkpoint_mark before update of repair_enc on review_requests for each row when (old.repair_enc is null and new.repair_enc is not null) execute function t23_expire_checkpoint_mark()`)
	before = len(stages)
	create(400)
	if len(stages) != before+1 || stages[before] != gateway.ReviewAnalysis {
		t.Fatalf("scored after linked source vanished: %v", stages[before:])
	}
	assertRows(0, 1, 0, 0)
	exec(`drop trigger t23_expire_checkpoint_mark on review_requests`)
	exec(`drop function t23_expire_checkpoint_mark()`)

	// Save rechecks the original source IDs after the journal copy has stripped
	// those IDs from its ciphertext. A mark deleted after scoring must abort.
	must(db.QueryRow(ctx, `insert into manual_marks(user_id,mark_enc) values($1,'\x73617665'::bytea) returning id`, u).Scan(&mark))
	in = originalInput
	in.RequestId = uuid.New()
	in.MarkId = &mark
	baseRouter := s.Router
	s.Router = func(stop gateway.Stop) (scoring.Runner, error) {
		r, e := baseRouter(stop)
		return runFunc(func(c context.Context, call gateway.Call) (gateway.Reply, error) {
			reply, e := r.Run(c, call)
			if call.Task == gateway.Scoring {
				exec(`delete from manual_marks where id=$1`, mark)
			}
			return reply, e
		}), e
	}
	before = len(stages)
	create(400)
	if len(stages) != before+2 || stages[before+1] != gateway.Scoring {
		t.Fatalf("unexpected save recheck path: %v", stages[before:])
	}
	s.Router = baseRouter
	assertRows(0, 1, 0, 0)

	// Withdrawing review consent after the approved repair is checkpointed must
	// stop the second external call. The checkpoint transaction commits the
	// revocation, then the pre-score recheck must reject scoring without a debit.
	exec(`create or replace function t23_withdraw_after_checkpoint() returns trigger language plpgsql as $$ begin update consents set withdrawn_at=clock_timestamp() where user_id=new.user_id and purpose='review' and withdrawn_at is null; return new; end $$`)
	exec(`create trigger t23_withdraw_after_checkpoint before update of repair_enc on review_requests for each row when (old.repair_enc is null and new.repair_enc is not null) execute function t23_withdraw_after_checkpoint()`)
	in = originalInput
	in.RequestId = uuid.New()
	before = len(stages)
	create(403)
	if len(stages) != before+1 || stages[before] != gateway.ReviewAnalysis {
		t.Fatalf("scored after consent was withdrawn at checkpoint: %v", stages[before:])
	}
	assertRows(0, 1, 0, 0)
	exec(`drop trigger t23_withdraw_after_checkpoint on review_requests`)
	exec(`drop function t23_withdraw_after_checkpoint()`)
	httpJSON("PUT", "me/consents/review", map[string]any{"version": "v1", "granted": true}, 200)

	// Terminal activity state is authoritative before quota settlement. A quota
	// write failure must not make a crisis replayable as a normal generation.
	exec(`create or replace function t23_fail_safety_quota() returns trigger language plpgsql as $$ begin if new.state='safety' then raise exception 'synthetic safety quota failure'; end if; return new; end $$`)
	exec(`create trigger t23_fail_safety_quota before update on quota_attempts for each row execute function t23_fail_safety_quota()`)
	mode = "crisis"
	in = originalInput
	in.RequestId = uuid.New()
	var safety gateway.Terminal
	must(json.Unmarshal(create(200), &safety))
	if !safety.Safety || safety.Message != gateway.HelpMessage {
		t.Fatal("crisis response was lost")
	}
	var state string
	must(db.QueryRow(ctx, `select a.state from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&state))
	if state != "safety" {
		t.Fatalf("crisis state was not persisted before quota settlement: %s", state)
	}
	exec(`drop trigger t23_fail_safety_quota on quota_attempts`)
	exec(`drop function t23_fail_safety_quota()`)
	mode = "normal"
	before = len(stages)
	must(json.Unmarshal(create(200), &safety))
	if !safety.Safety || len(stages) != before {
		t.Fatal("persisted crisis was regenerated")
	}
	assertRows(0, 1, 0, 0)

	// A failed safety terminal write must not be reported as a successful terminal.
	// Otherwise a client can receive help while the durable activity remains active,
	// allowing the same key to generate and charge after the lease expires.
	exec(`create or replace function t23_fail_safety_activity() returns trigger language plpgsql as $$ begin if new.state='safety' then raise exception 'synthetic safety activity failure'; end if; return new; end $$`)
	exec(`create trigger t23_fail_safety_activity before update of state on activities for each row when (new.state='safety') execute function t23_fail_safety_activity()`)
	mode = "crisis"
	in = originalInput
	in.RequestId = uuid.New()
	failure := create(500)
	if bytes.Contains(failure, []byte(gateway.HelpMessage)) || !bytes.Contains(failure, []byte(`"retryable":true`)) {
		t.Fatalf("safety persistence failure was reported as terminal: %s", failure)
	}
	exec(`drop trigger t23_fail_safety_activity on activities`)
	exec(`drop function t23_fail_safety_activity()`)

	// An unavailable moderation result persists its terminal state independently.
	// If quota settlement failed, the same key must settle the old hold and retry
	// without repeating the already checkpointed analysis.
	exec(`create or replace function t23_fail_outage_quota() returns trigger language plpgsql as $$ begin if new.state='moderation_unavailable' then raise exception 'synthetic outage quota failure'; end if; return new; end $$`)
	exec(`create trigger t23_fail_outage_quota before update on quota_attempts for each row execute function t23_fail_outage_quota()`)
	mode = "outage"
	in = originalInput
	in.RequestId = uuid.New()
	create(503)
	must(db.QueryRow(ctx, `select a.state from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&state))
	if state != "moderation_unavailable" {
		t.Fatalf("outage state was not persisted before quota settlement: %s", state)
	}
	exec(`drop trigger t23_fail_outage_quota on quota_attempts`)
	exec(`drop function t23_fail_outage_quota()`)
	mode = "normal"
	before = len(stages)
	var resumed app.Review
	must(json.Unmarshal(create(200), &resumed))
	if resumed.Score.Nvc.Total != 20 || len(stages) != before+1 || stages[before] != gateway.Scoring {
		t.Fatalf("outage retry repeated approved analysis: %v", stages[before:])
	}
	assertRows(1, 2, 1, 1)

	// A complete analysis output can be checkpointed before output moderation.
	// Its original request key must replay moderation and parsing without another
	// analysis model call, and the unmoderated bytes must stay out of history/export.
	mode = "analysis-output-outage"
	in = originalInput
	in.RequestId = uuid.New()
	in.Happened = "SYNTHETIC-ANALYSIS-CHECKPOINT"
	analysisBefore, scoringBefore := analysisModels, scoringModels
	scoresBefore, usedBefore := counts()
	create(503)
	if analysisModels != analysisBefore+1 || scoringModels != scoringBefore {
		t.Fatalf("analysis outage model calls: analysis=%d scoring=%d", analysisModels-analysisBefore, scoringModels-scoringBefore)
	}
	if scores, used := counts(); scores != scoresBefore || used != usedBefore {
		t.Fatalf("analysis outage changed ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}
	var pendingID uuid.UUID
	var generated []byte
	var generatedTask *string
	var generatedCall *uuid.UUID
	var repair []byte
	must(db.QueryRow(ctx, `select a.id,a.state,r.generated_enc,r.generated_task,r.generated_call_id,r.repair_enc
from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&pendingID, &state, &generated, &generatedTask, &generatedCall, &repair))
	if state != "moderation_unavailable" || generatedTask == nil || *generatedTask != string(gateway.ReviewAnalysis) || generatedCall == nil || generated == nil {
		t.Fatalf("missing analysis checkpoint: state=%s task=%v call=%v", state, generatedTask, generatedCall)
	}
	if bytes.Contains(generated, []byte("我刚才打断")) || repair != nil {
		t.Fatal("unmoderated analysis was stored in cleartext or released as approved repair")
	}
	httpJSON("GET", "reviews/"+pendingID.String(), nil, 404)
	if bytes.Contains(readExport(u), []byte(in.Happened)) {
		t.Fatal("unmoderated analysis entered export")
	}
	must(json.Unmarshal(create(200), &r))
	if analysisModels != analysisBefore+1 || analysisReplays != 1 || scoringModels != scoringBefore+1 {
		t.Fatalf("analysis replay repeated model: analysis=%d replay=%d scoring=%d", analysisModels-analysisBefore, analysisReplays, scoringModels-scoringBefore)
	}
	if scores, used := counts(); scores != scoresBefore+1 || used != usedBefore+1 {
		t.Fatalf("analysis recovery ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}
	must(db.QueryRow(ctx, `select r.generated_enc,r.generated_task,r.generated_call_id,r.repair_enc
from review_requests r where r.activity_id=$1`, pendingID).Scan(&generated, &generatedTask, &generatedCall, &repair))
	if generated != nil || generatedTask != nil || generatedCall != nil || repair != nil {
		t.Fatal("successful analysis recovery retained generation checkpoint")
	}
	if !bytes.Contains(readExport(u), []byte(in.Happened)) {
		t.Fatal("approved review missing from export")
	}

	// The same contract applies after a complete scoring output. Retry must run
	// only the external checks, then associate the original call with the one
	// durable score and one debit.
	mode = "scoring-output-outage"
	in = originalInput
	in.RequestId = uuid.New()
	in.Happened = "SYNTHETIC-SCORING-CHECKPOINT"
	analysisBefore, scoringBefore = analysisModels, scoringModels
	scoringReplayBefore := scoringReplays
	scoresBefore, usedBefore = counts()
	create(503)
	if analysisModels != analysisBefore+1 || scoringModels != scoringBefore+1 {
		t.Fatalf("scoring outage model calls: analysis=%d scoring=%d", analysisModels-analysisBefore, scoringModels-scoringBefore)
	}
	if scores, used := counts(); scores != scoresBefore || used != usedBefore {
		t.Fatalf("scoring outage changed ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}
	must(db.QueryRow(ctx, `select a.id,a.state,r.generated_enc,r.generated_task,r.generated_call_id,r.repair_enc
from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&pendingID, &state, &generated, &generatedTask, &generatedCall, &repair))
	if state != "moderation_unavailable" || generatedTask == nil || *generatedTask != string(gateway.Scoring) || generatedCall == nil || generated == nil || repair == nil {
		t.Fatalf("missing scoring checkpoint: state=%s task=%v call=%v repair=%v", state, generatedTask, generatedCall, repair)
	}
	if bytes.Contains(generated, []byte("safety_flag")) {
		t.Fatal("unmoderated scoring output was stored in cleartext")
	}
	httpJSON("GET", "reviews/"+pendingID.String(), nil, 404)
	if bytes.Contains(readExport(u), []byte(in.Happened)) {
		t.Fatal("unmoderated scoring output entered export")
	}
	must(json.Unmarshal(create(200), &r))
	if analysisModels != analysisBefore+1 || scoringModels != scoringBefore+1 || scoringReplays != scoringReplayBefore+1 {
		t.Fatalf("scoring replay repeated model: analysis=%d scoring=%d replay=%d", analysisModels-analysisBefore, scoringModels-scoringBefore, scoringReplays-scoringReplayBefore)
	}
	if scores, used := counts(); scores != scoresBefore+1 || used != usedBefore+1 {
		t.Fatalf("scoring recovery ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}
	must(db.QueryRow(ctx, `select r.generated_enc,r.generated_task,r.generated_call_id,r.repair_enc
from review_requests r where r.activity_id=$1`, pendingID).Scan(&generated, &generatedTask, &generatedCall, &repair))
	if generated != nil || generatedTask != nil || generatedCall != nil || repair != nil {
		t.Fatal("successful scoring recovery retained generation checkpoint")
	}
	var scoreID uuid.UUID
	must(db.QueryRow(ctx, `select id from scores where activity_id=$1`, pendingID).Scan(&scoreID))
	var calls, linked int
	var outcome string
	must(db.QueryRow(ctx, `select count(*),count(score_id),min(outcome) from ai_calls where activity_id=$1 and task='scoring'`, pendingID).Scan(&calls, &linked, &outcome))
	if calls != 1 || linked != 1 || outcome != "moderation_unavailable" {
		t.Fatalf("scoring call association: calls=%d linked=%d outcome=%s", calls, linked, outcome)
	}
	var linkedScore uuid.UUID
	must(db.QueryRow(ctx, `select score_id from ai_calls where activity_id=$1 and task='scoring'`, pendingID).Scan(&linkedScore))
	if linkedScore != scoreID || r.Score.ScoreId != scoreID {
		t.Fatal("replayed scoring call linked to the wrong score")
	}
	if !bytes.Contains(readExport(u), []byte(in.Happened)) {
		t.Fatal("approved scoring review missing from export")
	}

	// An unmoderated checkpoint is deliberately short-lived. Once its 15-minute
	// window expires, the original key must fail closed: silently regenerating
	// would turn a complete-but-unapproved result into a new model charge.
	mode = "analysis-output-outage"
	in = originalInput
	in.RequestId = uuid.New()
	in.Happened = "SYNTHETIC-CHECKPOINT-EXPIRY"
	create(503)
	must(db.QueryRow(ctx, `select a.id,r.generated_enc from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&pendingID, &generated))
	if generated == nil {
		t.Fatal("expiry fixture missing checkpoint")
	}
	// Even before minute maintenance physically removes it, the original key
	// must sanitize the checkpoint and reject recovery.
	exec(`update review_requests set generated_at=now()-interval '16 minutes' where activity_id=$1`, pendingID)
	analysisBefore, scoringBefore = analysisModels, scoringModels
	expiryReplayBefore := analysisReplays
	scoresBefore, usedBefore = counts()
	requestsBefore, attemptsBefore := reviewAttemptCounts(pendingID)
	mode = "normal"
	if body := create(409); !bytes.Contains(body, []byte("恢复窗口已过期")) {
		t.Fatalf("expired recovery was not explicit: %s", body)
	}
	if analysisModels != analysisBefore || analysisReplays != expiryReplayBefore || scoringModels != scoringBefore {
		t.Fatalf("expired checkpoint reached model: analysis=%d replay=%d scoring=%d", analysisModels-analysisBefore, analysisReplays-expiryReplayBefore, scoringModels-scoringBefore)
	}
	if scores, used := counts(); scores != scoresBefore || used != usedBefore {
		t.Fatalf("expired checkpoint changed ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}
	if requests, attempts := reviewAttemptCounts(pendingID); requests != requestsBefore || attempts != attemptsBefore {
		t.Fatalf("expired checkpoint created executable state: requests=%d/%d attempts=%d/%d", requestsBefore, requests, attemptsBefore, attempts)
	}
	var hasGenerated, hasGeneratedTask, hasGeneratedCall, hasGeneratedAt, generatedExpired bool
	must(db.QueryRow(ctx, `select r.generated_enc is not null,r.generated_task is not null,r.generated_call_id is not null,r.generated_at is not null,r.generated_expired from review_requests r where r.activity_id=$1`, pendingID).Scan(&hasGenerated, &hasGeneratedTask, &hasGeneratedCall, &hasGeneratedAt, &generatedExpired))
	if hasGenerated || hasGeneratedTask || hasGeneratedCall || hasGeneratedAt || !generatedExpired {
		t.Fatalf("expired checkpoint was not sanitized: enc=%v task=%v call=%v at=%v expired=%v", hasGenerated, hasGeneratedTask, hasGeneratedCall, hasGeneratedAt, generatedExpired)
	}
	var expiredState, expiredAttempt string
	must(db.QueryRow(ctx, `select a.state,q.state from activities a join quota_attempts q on q.activity_id=a.id where a.id=$1`, pendingID).Scan(&expiredState, &expiredAttempt))
	if expiredState != "failed" || expiredAttempt != string(membership.ModerationUnavailable) {
		t.Fatalf("expired recovery was not closed: activity=%s attempt=%s", expiredState, expiredAttempt)
	}
	create(409)
	if analysisModels != analysisBefore || analysisReplays != expiryReplayBefore || scoringModels != scoringBefore {
		t.Fatal("expired original key recovered on retry")
	}
	// A fresh request ID remains available and can complete normally.
	in.RequestId = uuid.New()
	must(json.Unmarshal(create(200), &r))
	if analysisModels != analysisBefore+1 || scoringModels != scoringBefore+1 {
		t.Fatalf("fresh recovery after expiry failed: analysis=%d scoring=%d", analysisModels-analysisBefore, scoringModels-scoringBefore)
	}
	if scores, used := counts(); scores != scoresBefore+1 || used != usedBefore+1 {
		t.Fatalf("fresh recovery ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}

	// A checkpoint is part of the review activity's sensitive working set and
	// must disappear with the activity and its quota attempt.
	mode = "analysis-output-outage"
	in = originalInput
	in.RequestId = uuid.New()
	in.Happened = "SYNTHETIC-CHECKPOINT-CASCADE"
	create(503)
	must(db.QueryRow(ctx, `select a.id,r.generated_enc from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&pendingID, &generated))
	if generated == nil {
		t.Fatal("cascade fixture missing checkpoint")
	}
	exec(`delete from activities where id=$1`, pendingID)
	var requests, attempts int
	must(db.QueryRow(ctx, `select (select count(*) from review_requests where activity_id=$1),(select count(*) from quota_attempts where activity_id=$1)`, pendingID).Scan(&requests, &attempts))
	if requests != 0 || attempts != 0 {
		t.Fatalf("checkpoint cascade left rows: requests=%d attempts=%d", requests, attempts)
	}

	// The scoring input may have been moderated as allow before a concurrent
	// consent withdrawal. The source must recheck authorization immediately
	// before the external scoring call and fail closed without a debit.
	mode = "withdraw-before-scoring"
	in = originalInput
	in.RequestId = uuid.New()
	in.Happened = "SYNTHETIC-WITHDRAW-BEFORE-SCORING"
	analysisBefore, scoringBefore = analysisModels, scoringModels
	analysisReplayBefore := analysisReplays
	scoresBefore, usedBefore = counts()
	create(403)
	if analysisModels != analysisBefore+1 || scoringModels != scoringBefore || analysisReplays != analysisReplayBefore {
		t.Fatalf("withdrawn scoring model calls: analysis=%d scoring=%d replay=%d", analysisModels-analysisBefore, scoringModels-scoringBefore, analysisReplays-analysisReplayBefore)
	}
	if scores, used := counts(); scores != scoresBefore || used != usedBefore {
		t.Fatalf("withdrawn scoring changed ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}
	must(db.QueryRow(ctx, `select a.id,a.state,r.generated_enc,r.generated_task,r.generated_call_id,r.repair_enc
from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&pendingID, &state, &generated, &generatedTask, &generatedCall, &repair))
	if state != "failed" || generated != nil || generatedTask != nil || generatedCall != nil || repair != nil {
		t.Fatalf("withdrawn scoring retained checkpoint: state=%s task=%v call=%v", state, generatedTask, generatedCall)
	}
	var scoringCalls int
	must(db.QueryRow(ctx, `select count(*) from ai_calls where activity_id=$1 and task='scoring'`, pendingID).Scan(&scoringCalls))
	if scoringCalls != 0 {
		t.Fatalf("withdrawn scoring reached upstream %d times", scoringCalls)
	}
	httpJSON("PUT", "me/consents/review", map[string]any{"version": "v1", "granted": true}, 200)

	// A complete scoring result can arrive just as review consent is withdrawn.
	// The pre-checkpoint transaction must reject it without storing the result,
	// linking a score, consuming quota or creating a pending delivery.
	mode = "withdraw-before-checkpoint"
	in = originalInput
	in.RequestId = uuid.New()
	in.Happened = "SYNTHETIC-WITHDRAW-BEFORE-CHECKPOINT"
	analysisBefore, scoringBefore = analysisModels, scoringModels
	scoresBefore, usedBefore = counts()
	create(403)
	if analysisModels != analysisBefore+1 || scoringModels != scoringBefore+1 {
		t.Fatalf("withdraw-before-checkpoint model calls: analysis=%d scoring=%d", analysisModels-analysisBefore, scoringModels-scoringBefore)
	}
	if scores, used := counts(); scores != scoresBefore || used != usedBefore {
		t.Fatalf("withdraw-before-checkpoint changed ledger: before=%v/%v after=%v/%v", scoresBefore, usedBefore, scores, used)
	}
	must(db.QueryRow(ctx, `select a.id,a.state,r.generated_enc,r.generated_task,r.generated_call_id,r.repair_enc
from activities a join review_requests r on r.activity_id=a.id where r.user_id=$1 and r.request_id=$2`, u, in.RequestId).Scan(&pendingID, &state, &generated, &generatedTask, &generatedCall, &repair))
	if state != "failed" || generated != nil || generatedTask != nil || generatedCall != nil || repair != nil {
		t.Fatalf("withdrawn checkpoint write survived: state=%s task=%v call=%v", state, generatedTask, generatedCall)
	}
	var linkedScores, pendingScores int
	must(db.QueryRow(ctx, `select (select count(*) from ai_calls where activity_id=$1 and score_id is not null),(select count(*) from review_requests where activity_id=$1 and score_pending)`, pendingID).Scan(&linkedScores, &pendingScores))
	if linkedScores != 0 || pendingScores != 0 {
		t.Fatalf("withdrawn checkpoint reached delivery: links=%d pending=%d", linkedScores, pendingScores)
	}
	httpJSON("PUT", "me/consents/review", map[string]any{"version": "v1", "granted": true}, 200)

	// Account erasure removes tombstones without a users foreign-key failure.
	must(dbs.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: u, Scope: "account"}))
	must(db.QueryRow(ctx, `select count(*) from review_tombstones where user_id=$1`, u).Scan(&tombstones))
	if tombstones != 0 {
		t.Fatalf("account erasure retained %d tombstones", tombstones)
	}
	t.Log("verified PostgreSQL rollback, terminal-state recovery, source rechecks, tombstoned deletion, one debit and outbox, encrypted history, ZIP hook partitions and account erasure")
}
