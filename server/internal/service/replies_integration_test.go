//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/replies"
)

type syntheticRun func(context.Context, gateway.Call) (gateway.Reply, error)

func (f syntheticRun) Run(c context.Context, v gateway.Call) (gateway.Reply, error) { return f(c, v) }

type countingProfileProvider struct {
	inner replies.ProfileProvider
	calls atomic.Int32
}

func (p *countingProfileProvider) ForModel(ctx context.Context, tx pgx.Tx, user, contact uuid.UUID) (app.Profile, error) {
	p.calls.Add(1)
	return p.inner.ForModel(ctx, tx, user, contact)
}

// Run only with runtime.sh's disposable DB and generated dev credentials.
func TestReplyLifecycle(t *testing.T) {
	ctx := context.Background()
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	profiles := &countingProfileProvider{inner: s.Profiles}
	var expectedSummary atomic.Value
	expectedSummary.Store("")
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	consentStarted, consentRelease := make(chan struct{}), make(chan struct{})
	var mode atomic.Int32
	const normal = `{"possible_feeling":"可能在担心进度","possible_need":"想知道具体时间","suggestions":[{"style":"直接","text":"我周三发计划。","reason":"明确时间。"},{"style":"确认","text":"你希望先看计划吗？","reason":"给出选择。"}]}`
	const raw = "T21-SYNTHETIC-CHAT-ONLY"
	s.Replies = replies.New(s.Accounts, s.Membership, s.Data, s.Fields, s.db, s.Bus, cfg.authMaster, func(stop gateway.Stop) (replies.Runner, error) {
		return syntheticRun(func(c context.Context, v gateway.Call) (gateway.Reply, error) {
			n := calls.Add(1)
			var message struct {
				Chat    string  `json:"chat_text"`
				Goal    *string `json:"goal,omitempty"`
				Profile string  `json:"profile_summary"`
			}
			if v.Task != gateway.ReplySuggestion || v.Mode != gateway.JSONObject || v.Emit != nil || len(v.Messages) != 1 {
				return gateway.Reply{}, errors.New("wrong call")
			}
			if e := json.Unmarshal([]byte(v.Messages[0].Content), &message); e != nil || message.Chat != raw {
				return gateway.Reply{}, errors.New("wrong model message")
			}
			if want := expectedSummary.Load().(string); message.Profile != want {
				return gateway.Reply{}, errors.New("wrong profile summary")
			}
			if n == 1 {
				close(started)
				select {
				case <-release:
				case <-c.Done():
					return gateway.Reply{}, c.Err()
				}
			}
			if mode.Load() == 4 {
				close(consentStarted)
				select {
				case <-consentRelease:
				case <-c.Done():
					return gateway.Reply{}, c.Err()
				}
			}
			if v.Authorize == nil {
				return gateway.Reply{}, errors.New("missing dispatch authorization")
			}
			if e := v.Authorize(c, nil, func(context.Context, pgx.Tx) error { return nil }); e != nil {
				return gateway.Reply{}, e
			}
			switch mode.Load() {
			case 1, 2:
				term := gateway.Terminal{Safety: mode.Load() == 1}
				return gateway.Reply{Terminal: &term}, stop(c, v.Scope, term)
			case 3:
				return gateway.Reply{Result: gateway.Result{Object: []byte(`{"partial":true}`)}}, nil
			case 5:
				term := gateway.Terminal{Safety: true, Message: gateway.HelpMessage}
				failed, cancel := context.WithCancel(c)
				cancel()
				_ = stop(failed, v.Scope, term)
				return gateway.Reply{Terminal: &term}, nil
			}
			return gateway.Reply{CallID: uuid.New(), Result: gateway.Result{Object: []byte(normal)}}, nil
		}), nil
	})
	s.Replies.AttachFeedback(s.Profiles)
	s.Replies.AttachProfiles(profiles)
	router := s.Router()
	type res struct {
		code int
		b    []byte
	}
	request := func(c context.Context, method, path, tok string, body any) res {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b)).WithContext(c)
		req.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return res{w.Code, w.Body.Bytes()}
	}
	check := func(r res, code int, to any) {
		t.Helper()
		if r.code != code {
			t.Fatalf("status %d want %d: %s", r.code, code, r.b)
		}
		if to != nil {
			if e := json.Unmarshal(r.b, to); e != nil {
				t.Fatal(e)
			}
		}
	}
	signup := func() app.Tokens {
		ticket := uuid.NewString()
		if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); e != nil {
			t.Fatal(e)
		}
		var tok app.Tokens
		check(request(ctx, "POST", "auth/login", "", map[string]any{"credential": map[string]any{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"}), 200, &tok)
		return tok
	}
	a, b := signup(), signup()
	in := app.CreateReplyInput{RequestId: uuid.New(), ChatText: raw}
	firstRequestID := in.RequestId
	post := func() res { return request(ctx, "POST", "replies", a.AccessToken, in) }
	check(post(), 403, nil)
	check(request(ctx, "PUT", "me/consents/chat_import", a.AccessToken, map[string]any{"version": "v1", "granted": true}), 200, nil)
	// Disconnect after upstream entry; the same request polls instead of generating.
	client, cancel := context.WithCancel(ctx)
	defer cancel()
	one := make(chan res, 1)
	go func() { one <- request(client, "POST", "replies", a.AccessToken, in) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("generation not started")
	}
	cancel()
	check(post(), 202, nil)
	if profiles.calls.Load() != 0 {
		t.Fatal("in-progress poll read a profile")
	}
	close(release)
	var answer app.Reply
	r := <-one
	check(r, 200, &answer)
	if answer.Id == uuid.Nil || len(answer.Suggestions) != 2 {
		t.Fatal("invalid success")
	}
	r2 := post()
	if !bytes.Equal(r.b, r2.b) || calls.Load() != 1 || profiles.calls.Load() != 0 {
		t.Fatal("not original result or profile reread")
	}
	if bytes.Contains(r2.b, []byte(raw)) {
		t.Fatal("replayed response contains the submitted chat")
	}
	var imports int
	if e = s.db.QueryRow(ctx, `select count(*) from chat_imports c join activities a on a.id=c.activity_id where a.user_id=$1`, a.UserId).Scan(&imports); e != nil || imports != 0 {
		t.Fatal("original request or replay persisted imported chat", imports, e)
	}
	in.ChatText += "different"
	check(post(), 409, nil)
	in.ChatText = raw
	used := func(want int) {
		var n int
		if e := s.db.QueryRow(ctx, `select coalesce(sum(used),0)::int from daily_quota_usage where user_id=$1 and feature='reply'`, a.UserId).Scan(&n); e != nil || n != want {
			t.Fatal("wrong usage", n, e)
		}
	}
	used(1)
	// Consent can be withdrawn while a request is between the pre-hold and its
	// external dispatch. The dispatch must stop and the failed attempt refund.
	in.RequestId = uuid.New()
	mode.Store(4)
	revoked := make(chan res, 1)
	go func() { revoked <- post() }()
	select {
	case <-consentStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("authorization wait not reached")
	}
	check(request(ctx, "PUT", "me/consents/chat_import", a.AccessToken, map[string]any{"version": "v1", "granted": false}), 200, nil)
	close(consentRelease)
	check(<-revoked, 403, nil)
	used(1)
	check(request(ctx, "PUT", "me/consents/chat_import", a.AccessToken, map[string]any{"version": "v1", "granted": true}), 200, nil)
	in.RequestId = uuid.New()
	mode.Store(1)
	for range 2 {
		var body map[string]any
		check(post(), 200, &body)
		if len(body) != 2 || body["message"] != gateway.HelpMessage || body["safety"] != true {
			t.Fatal("unsafe crisis shape")
		}
	}
	if calls.Load() != 3 {
		t.Fatal("crisis regenerated")
	}
	used(1)
	mode.Store(2)
	in.RequestId = uuid.New()
	var problem app.Error
	check(post(), 503, &problem)
	if problem.Code != "moderation_unavailable" || !problem.Retryable || problem.Message != gateway.UnavailableMessage {
		t.Fatal("review outage misclassified")
	}
	used(1)
	mode.Store(0)
	check(post(), 200, nil)
	used(2)
	// A canceled first settlement is compensated with the same idempotency token;
	// the durable safety state must survive and the request must not be charged.
	mode.Store(5)
	in.RequestId = uuid.New()
	var retriedSafety map[string]any
	check(post(), 200, &retriedSafety)
	if retriedSafety["safety"] != true || retriedSafety["message"] != gateway.HelpMessage {
		t.Fatal("settlement retry hid crisis")
	}
	var settledState string
	if e := s.db.QueryRow(ctx, `select state from activities where id=(select activity_id from reply_request_keys where user_id=$1 and request_id=$2)`, a.UserId, in.RequestId).Scan(&settledState); e != nil || settledState != "safety" {
		t.Fatal("settlement retry did not persist safety", settledState, e)
	}
	used(2)
	mode.Store(3)
	in.RequestId = uuid.New()
	failedRequestID := in.RequestId
	check(post(), 500, nil)
	used(2)
	feedback := "replies/" + answer.Id.String() + "/feedback"
	rate := func(tok string, idx int, note string) res {
		return request(ctx, "POST", feedback, tok, map[string]any{"index": idx, "outcome": note})
	}
	check(rate(b.AccessToken, 0, "本人没有上头"), 404, nil)
	check(rate(a.AccessToken, 2, "无第三项"), 400, nil)
	check(request(ctx, "POST", feedback, a.AccessToken, map[string]any{"outcome": "缺少选择"}), 400, nil)
	check(rate(a.AccessToken, 1, "对方好像不高兴"), 200, nil)
	var ordinaryID, ordinarySource uuid.UUID
	var ordinaryAt time.Time
	if e = s.db.QueryRow(ctx, `select f.id,a.source_id,f.occurred_at from reply_feedback f join activities a on a.id=f.activity_id where f.activity_id=$1 and not f.self_report`, answer.Id).Scan(&ordinaryID, &ordinarySource, &ordinaryAt); e != nil {
		t.Fatal(e)
	}
	ordinaryEvent := events.ReplyOutcome{FeedbackID: ordinaryID, UserID: a.UserId, SourceID: ordinarySource, SourceKind: "reply", OccurredAt: ordinaryAt}
	if e = s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error {
		got, err := s.Replies.ReadOutcomeTx(ctx, tx, ordinaryEvent)
		if err != nil {
			return err
		}
		if got != (replies.OutcomeDetails{Index: 1, Outcome: "对方好像不高兴"}) {
			return errors.New("wrong ordinary outcome details")
		}
		return nil
	}); e != nil {
		t.Fatal("read ordinary outcome", e)
	}
	if e = s.Data.Access(ctx, b.UserId, func(tx pgx.Tx) error { _, err := s.Replies.ReadOutcomeTx(ctx, tx, ordinaryEvent); return err }); !errors.Is(e, replies.ErrMissing) {
		t.Fatal("cross-account outcome read", e)
	}
	wrongSource := ordinaryEvent
	wrongSource.SourceID = uuid.New()
	if e = s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error { _, err := s.Replies.ReadOutcomeTx(ctx, tx, wrongSource); return err }); !errors.Is(e, replies.ErrMissing) {
		t.Fatal("wrong-source outcome read", e)
	}
	if e = s.Replies.ReplayPending(ctx); e != nil {
		t.Fatal("deliver ordinary outcome", e)
	}
	var receiptUser, receiptSource uuid.UUID
	var receiptKind string
	var receiptAt time.Time
	var receiptIndex int
	if e = s.db.QueryRow(ctx, `select user_id,source_id,source_kind,occurred_at,suggestion_index from reply_outcome_receipts where feedback_id=$1`, ordinaryID).Scan(&receiptUser, &receiptSource, &receiptKind, &receiptAt, &receiptIndex); e != nil {
		t.Fatal("missing ordinary receipt", e)
	}
	if receiptUser != a.UserId || receiptSource != ordinarySource || receiptKind != "reply" || !receiptAt.Equal(ordinaryAt) || receiptIndex != 1 {
		t.Fatal("wrong ordinary receipt", receiptUser, receiptSource, receiptKind, receiptAt, receiptIndex)
	}
	var outcomePending bool
	if e = s.db.QueryRow(ctx, `select outcome_pending from reply_feedback where id=$1`, ordinaryID).Scan(&outcomePending); e != nil || outcomePending {
		t.Fatal("ordinary outcome did not clear", outcomePending, e)
	}
	var ordinaryObservations int
	if e = s.db.QueryRow(ctx, `select count(*) from profile_observations where id=$1`, ordinaryID).Scan(&ordinaryObservations); e != nil || ordinaryObservations != 0 {
		t.Fatal("ordinary outcome became profile evidence", ordinaryObservations, e)
	}
	var effectColumns int
	if e = s.db.QueryRow(ctx, `select count(*) from information_schema.columns where table_schema=current_schema() and table_name='reply_outcome_receipts' and column_name in ('outcome','chat_text','suggestion_text')`).Scan(&effectColumns); e != nil || effectColumns != 0 {
		t.Fatal("receipt schema copies prose", effectColumns, e)
	}
	if e = s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error { return s.Profiles.ConsumeReplyOutcome(ctx, tx, ordinaryEvent, s.Replies) }); e != nil {
		t.Fatal("idempotent receipt redelivery", e)
	}
	if e = s.Data.Access(ctx, b.UserId, func(tx pgx.Tx) error { return s.Profiles.ConsumeReplyOutcome(ctx, tx, ordinaryEvent, s.Replies) }); !errors.Is(e, replies.ErrMissing) {
		t.Fatal("receipt replay must not trust the event owner independently of the guarded transaction", e)
	}
	changedKey := ordinaryEvent
	changedKey.OccurredAt = changedKey.OccurredAt.Add(time.Second)
	if e = s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error { return s.Profiles.ConsumeReplyOutcome(ctx, tx, changedKey, s.Replies) }); !errors.Is(e, accounts.ErrInvalid) {
		t.Fatal("same feedback id with another key", e)
	}
	if e = s.Replies.ReplayPending(ctx); e != nil {
		t.Fatal("replay ordinary receipt", e)
	}
	var receiptCount int
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where feedback_id=$1`, ordinaryID).Scan(&receiptCount); e != nil || receiptCount != 1 {
		t.Fatal("ordinary receipt duplicated", receiptCount, e)
	}
	if e = s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error { _, err := s.Replies.ReadOutcomeTx(ctx, tx, ordinaryEvent); return err }); !errors.Is(e, replies.ErrMissing) {
		t.Fatal("cleared outcome remained readable", e)
	}
	for range 2 {
		check(request(ctx, "POST", feedback, a.AccessToken, map[string]any{"index": 0, "outcome": "选择有效", "self_report": "not_overwhelmed"}), 200, nil)
	}
	check(request(ctx, "POST", feedback, a.AccessToken, map[string]any{"index": 0, "outcome": "另一条确认", "self_report": "overwhelmed"}), 409, nil)
	var pending, selfPending bool
	if e = s.db.QueryRow(ctx, `select pending,outcome_pending from reply_feedback where activity_id=$1 and self_report`, answer.Id).Scan(&pending, &selfPending); e != nil || !pending || !selfPending {
		t.Fatal("self report queue state", pending, selfPending, e)
	}
	var selfID uuid.UUID
	if e = s.db.QueryRow(ctx, `select id from reply_feedback where activity_id=$1 and self_report`, answer.Id).Scan(&selfID); e != nil {
		t.Fatal(e)
	}
	// Run the real profile subscriber, then fail the same transaction once.
	// The separate ordinary-outcome transaction must still commit its receipt.
	failure := errors.New("synthetic profile subscriber failure")
	fault := true
	s.Bus.ProfileFeedback.Subscribe(func(_ context.Context, _ pgx.Tx, v events.Feedback) error {
		if fault && v.FeedbackID == selfID {
			return failure
		}
		return nil
	})
	if e = s.Replies.ReplayPending(ctx); !errors.Is(e, failure) {
		t.Fatal("missing profile queue failure", e)
	}
	var beforeApplied bool
	if e = s.db.QueryRow(ctx, `select f.pending,f.outcome_pending,o.applied from reply_feedback f join profile_observations o on o.id=f.id where f.id=$1`, selfID).Scan(&pending, &selfPending, &beforeApplied); e != nil || !pending || selfPending || beforeApplied {
		t.Fatal("outcome and profile did not settle independently", pending, selfPending, beforeApplied, e)
	}
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where feedback_id=$1`, selfID).Scan(&receiptCount); e != nil || receiptCount != 1 {
		t.Fatal("missing independent outcome receipt", receiptCount, e)
	}
	fault = false
	for range 2 {
		if e = s.Replies.ReplayPending(ctx); e != nil {
			t.Fatal(e)
		}
	}
	var observations int
	var applied bool
	if e = s.db.QueryRow(ctx, `select count(*),coalesce(bool_or(applied),false) from profile_observations where activity_id=$1 and subject='self'`, answer.Id).Scan(&observations, &applied); e != nil || observations != 1 || !applied {
		t.Fatal("self report not consumed once", observations, applied, e)
	}
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where feedback_id=$1`, selfID).Scan(&receiptCount); e != nil || receiptCount != 1 {
		t.Fatal("self report outcome receipt", receiptCount, e)
	}
	ownerZIP := t35Download(t, router, a.AccessToken)
	foreignZIP := t35Download(t, router, b.AccessToken)
	replyData := t35Part(t, ownerZIP, "replies")
	out := string(replyData)
	if !strings.Contains(out, "选择有效") || !strings.Contains(out, answer.Id.String()) || string(t35Part(t, foreignZIP, "replies")) != "[]" {
		t.Fatal("export boundary")
	}
	t35Exclude(t, replyData, raw, "input_mac", `"outcome_pending":`, `"source_kind":`, `"reply_outcome_receipts":`,
		`"request_id":`, firstRequestID.String(), failedRequestID.String())
	type replyExportRow struct {
		ID         uuid.UUID               `json:"id"`
		ContactID  *uuid.UUID              `json:"contact_id"`
		Result     *app.Reply              `json:"result"`
		FeedbackID uuid.UUID               `json:"feedback_id"`
		ReplyID    uuid.UUID               `json:"reply_id"`
		Feedback   *replies.OutcomeDetails `json:"feedback"`
	}
	var replyRows []replyExportRow
	t35Decode(t, replyData, &replyRows)
	var result, rated bool
	for _, row := range replyRows {
		result = result || row.ID == answer.Id && row.Result != nil &&
			reflect.DeepEqual(*row.Result, answer)
		rated = rated || row.FeedbackID == ordinaryID && row.ReplyID == answer.Id &&
			row.Feedback != nil && row.Feedback.Index == 1 && row.Feedback.Outcome == "对方好像不高兴"
	}
	if !result || !rated {
		t.Fatalf("replies.json missing result or linked feedback: %t/%t", result, rated)
	}
	membershipData := t35Part(t, ownerZIP, "membership")
	var quotaToken uuid.UUID
	if e = s.db.QueryRow(ctx, "select token from quota_attempts where activity_id=$1", answer.Id).Scan(&quotaToken); e != nil {
		t.Fatal(e)
	}
	t35Exclude(t, membershipData, quotaToken.String(), `"token":`, `"valid_until":`)
	var quotaRows []struct {
		Kind       string    `json:"kind"`
		ActivityID uuid.UUID `json:"activity_id"`
		Feature    string    `json:"feature"`
		Day        string    `json:"charged_day"`
		ChargedAt  time.Time `json:"charged_at"`
		Used       int       `json:"used"`
		State      string    `json:"state"`
	}
	t35Decode(t, membershipData, &quotaRows)
	var charge, settlement bool
	var daily int
	for _, row := range quotaRows {
		charge = charge || row.Kind == "charge" && row.ActivityID == answer.Id &&
			row.Feature == "reply" && row.Day != "" && !row.ChargedAt.IsZero()
		settlement = settlement || row.Kind == "settlement" && row.ActivityID == answer.Id && row.State == "complete"
		if row.Kind == "daily_usage" && row.Feature == "reply" && row.Day != "" {
			daily += row.Used
		}
	}
	if !charge || !settlement || daily != 2 || string(t35Part(t, foreignZIP, "membership")) != "[]" {
		t.Fatalf("membership.json charge=%t settlement=%t daily usage=%d", charge, settlement, daily)
	}
	if _, e = s.db.Exec(ctx, `insert into chat_imports(activity_id,original_enc) values($1,$2)`, answer.Id, []byte("synthetic blocked import")); e == nil {
		t.Fatal("reply raw import unexpectedly persisted")
	}
	if e = s.db.QueryRow(ctx, `select count(*) from chat_imports c join activities a on a.id=c.activity_id where a.user_id=$1`, a.UserId).Scan(&imports); e != nil || imports != 0 {
		t.Fatal("chat retained", e)
	}
	var key, selfSource uuid.UUID
	if e = s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `select a.source_id from profile_observations o join activities a on a.id=o.activity_id where o.id=$1 and o.user_id=$2`, selfID, a.UserId).Scan(&selfSource); err != nil {
			return err
		}
		var err error
		key, err = replies.DeletionKey(ctx, tx, a.UserId, answer.Id)
		return err
	}); e != nil || key != selfSource {
		t.Fatal("wrong deletion key", e)
	}
	if e = s.Data.Access(ctx, b.UserId, func(tx pgx.Tx) error { _, err := replies.DeletionKey(ctx, tx, b.UserId, answer.Id); return err }); !errors.Is(e, replies.ErrMissing) {
		t.Fatal("cross-owner deletion key")
	}
	if e = s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: a.UserId, SourceID: selfSource, Scope: "replies"}); e != nil {
		t.Fatal(e)
	}
	out = string(t35Part(t, t35Download(t, router, a.AccessToken), "replies"))
	if strings.Contains(out, answer.Id.String()) || strings.Contains(out, "选择有效") || strings.Contains(out, "对方好像不高兴") {
		t.Fatal("erasure incomplete")
	}
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where feedback_id=any($1::uuid[])`, []uuid.UUID{ordinaryID, selfID}).Scan(&receiptCount); e != nil || receiptCount != 0 {
		t.Fatal("source deletion retained outcome receipts", receiptCount, e)
	}
	used(2)
	// A deleted source leaves only its HMAC tombstone. Replaying the same key
	// must not generate a fresh answer or charge a second time.
	if firstRequestID == failedRequestID {
		t.Fatal("regression must replay the deleted success key, not the live failure key")
	}
	in.RequestId = firstRequestID
	beforeReplay := calls.Load()
	check(post(), 409, nil)
	if calls.Load() != beforeReplay {
		t.Fatal("deleted request reached gateway")
	}
	var tombstoned bool
	if e = s.db.QueryRow(ctx, `select activity_id is null from reply_request_keys where user_id=$1 and request_id=$2`, a.UserId, firstRequestID).Scan(&tombstoned); e != nil || !tombstoned {
		t.Fatal("deleted request key was not tombstoned", tombstoned, e)
	}
	var failedKeyLive bool
	if e = s.db.QueryRow(ctx, `select activity_id is not null from reply_request_keys where user_id=$1 and request_id=$2`, a.UserId, failedRequestID).Scan(&failedKeyLive); e != nil || !failedKeyLive {
		t.Fatal("unrelated failed request key should remain live", failedKeyLive, e)
	}
	used(2)
	// Use the real contact routes. A paid fixture allows creation; after the
	// entitlement expires only the explicitly activated contact stays writable.
	if _, e = s.db.Exec(ctx, `with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '2 days',now()+interval '1 day' from o`, a.UserId, []byte(uuid.NewString())); e != nil {
		t.Fatal(e)
	}
	check(request(ctx, "PUT", "me/consents/contacts", a.AccessToken, map[string]any{"version": "v1", "granted": true}), 200, nil)
	contactIn := map[string]any{"nickname": "合成联系人甲", "scene": "partner", "initial_context": "愿意尝试"}
	var live, other app.Contact
	check(request(ctx, "POST", "contacts", a.AccessToken, contactIn), 200, &live)
	contactIn["nickname"] = "合成联系人乙"
	contactIn["initial_context"] = "先做计划"
	check(request(ctx, "POST", "contacts", a.AccessToken, contactIn), 200, &other)
	if _, e = s.db.Exec(ctx, `update entitlements set ends_at=now()-interval '1 day' where user_id=$1`, a.UserId); e != nil {
		t.Fatal(e)
	}
	check(request(ctx, "POST", "contacts/"+live.Id.String()+"/activate", a.AccessToken, nil), 200, nil)
	mode.Store(0)
	priorCalls, priorProfiles := calls.Load(), profiles.calls.Load()
	in.RequestId = uuid.New()
	in.ContactId = &other.Id
	check(post(), 403, nil)
	if calls.Load() != priorCalls || profiles.calls.Load() != priorProfiles {
		t.Fatal("read-only contact reached gateway or profile")
	}
	expectedSummary.Store("对方可能愿意试试新办法")
	in.ContactId = &live.Id
	var last app.Reply
	check(post(), 200, &last)
	if profiles.calls.Load() != priorProfiles+1 || calls.Load() != priorCalls+1 {
		t.Fatal("contact profile was not read exactly once", profiles.calls.Load(), priorProfiles, calls.Load(), priorCalls)
	}
	used(3)
	lastRequest := in
	check(post(), 200, &last)
	if profiles.calls.Load() != priorProfiles+1 || calls.Load() != priorCalls+1 {
		t.Fatal("completed reply reread profile", profiles.calls.Load(), calls.Load())
	}
	contactReplyData := t35Part(t, t35Download(t, router, a.AccessToken), "replies")
	t35Exclude(t, contactReplyData, `"request_id":`, lastRequest.RequestId.String())
	var contactReplyRows []replyExportRow
	t35Decode(t, contactReplyData, &contactReplyRows)
	var linkedReply bool
	for _, row := range contactReplyRows {
		linkedReply = linkedReply || row.ID == last.Id && row.ContactID != nil && *row.ContactID == live.Id &&
			row.Result != nil && reflect.DeepEqual(*row.Result, last)
	}
	if !linkedReply {
		t.Fatal("replies.json missing the reply result linked to its contact")
	}
	in = lastRequest
	feedback = "replies/" + last.Id.String() + "/feedback"
	check(request(ctx, "POST", feedback, a.AccessToken, map[string]any{"index": 0, "outcome": "普通效果"}), 200, nil)
	check(request(ctx, "POST", feedback, a.AccessToken, map[string]any{"index": 1, "outcome": "练习完成", "self_report": "not_overwhelmed"}), 200, nil)
	var pendingSelf, pendingOutcome int
	if e = s.db.QueryRow(ctx, `select count(*) filter (where pending and self_report),count(*) filter (where outcome_pending) from reply_feedback where activity_id=$1`, last.Id).Scan(&pendingSelf, &pendingOutcome); e != nil || pendingSelf != 1 || pendingOutcome != 2 {
		t.Fatal("contact feedback queues were not pending", pendingSelf, pendingOutcome, e)
	}
	if _, e = s.db.Exec(ctx, `update contacts set last_used_at=now()+interval '1 hour' where id=$1`, other.Id); e != nil {
		t.Fatal(e)
	}
	check(rate(a.AccessToken, 0, "无权限"), 403, nil)
	if e = s.Replies.ReplayPending(ctx); e != nil {
		t.Fatal(e)
	}
	if e = s.db.QueryRow(ctx, `select count(*) filter (where pending and self_report),count(*) filter (where outcome_pending) from reply_feedback where activity_id=$1`, last.Id).Scan(&pendingSelf, &pendingOutcome); e != nil || pendingSelf != 1 || pendingOutcome != 2 {
		t.Fatal("read-only contact queues were cleared", pendingSelf, pendingOutcome, e)
	}
	if e = s.db.QueryRow(ctx, `select count(*),coalesce(bool_or(applied),false) from profile_observations where activity_id=$1`, last.Id).Scan(&observations, &applied); e != nil || observations != 1 || applied {
		t.Fatal("read-only contact was consumed", observations, applied, e)
	}
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where source_id=(select source_id from activities where id=$1)`, last.Id).Scan(&receiptCount); e != nil || receiptCount != 0 {
		t.Fatal("read-only contact outcome was delivered", receiptCount, e)
	}
	if _, e = s.db.Exec(ctx, `update contacts set last_used_at=null where id=$1`, other.Id); e != nil {
		t.Fatal(e)
	}
	check(request(ctx, "POST", "contacts/"+live.Id.String()+"/activate", a.AccessToken, nil), 200, nil)
	if e = s.Replies.ReplayPending(ctx); e != nil {
		t.Fatal(e)
	}
	if e = s.db.QueryRow(ctx, `select count(*),coalesce(bool_or(applied),false) from profile_observations where activity_id=$1`, last.Id).Scan(&observations, &applied); e != nil || observations != 1 || !applied {
		t.Fatal("reactivated contact feedback was not consumed", observations, applied, e)
	}
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where source_id=(select source_id from activities where id=$1)`, last.Id).Scan(&receiptCount); e != nil || receiptCount != 2 {
		t.Fatal("contact outcome receipts", receiptCount, e)
	}
	var contactEvent events.ReplyOutcome
	if e = s.db.QueryRow(ctx, `select feedback_id,user_id,source_id,source_kind,occurred_at from reply_outcome_receipts where source_id=(select source_id from activities where id=$1) and suggestion_index=0`, last.Id).Scan(&contactEvent.FeedbackID, &contactEvent.UserID, &contactEvent.SourceID, &contactEvent.SourceKind, &contactEvent.OccurredAt); e != nil {
		t.Fatal(e)
	}
	in.ContactId = nil
	in.RequestId = uuid.New()
	priorCalls = calls.Load()
	check(post(), 429, nil)
	if calls.Load() != priorCalls {
		t.Fatal("exhausted quota reached gateway")
	}
	if e = s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: a.UserId, Scope: "contacts", SourceID: live.Id}); e != nil {
		t.Fatal(e)
	}
	check(rate(a.AccessToken, 0, "已删除"), 404, nil)
	if e = s.Replies.ReplayPending(ctx); e != nil {
		t.Fatal(e)
	}
	var remaining int
	if e = s.db.QueryRow(ctx, `select count(*) from reply_feedback f join activities a on a.id=f.activity_id where a.id=$1 and a.user_id=$2`, last.Id, a.UserId).Scan(&remaining); e != nil || remaining != 0 {
		t.Fatal("deleted contact source retained feedback", remaining, e)
	}
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where feedback_id=$1`, contactEvent.FeedbackID).Scan(&receiptCount); e != nil || receiptCount != 0 {
		t.Fatal("contact deletion retained receipt", receiptCount, e)
	}
	if e = s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error { return s.Profiles.ConsumeReplyOutcome(ctx, tx, contactEvent, s.Replies) }); !errors.Is(e, replies.ErrMissing) {
		t.Fatal("deleted contact receipt was revived", e)
	}
	// A separate account's live queue produces real receipts, then account
	// deletion removes them and stale delivery cannot recreate them.
	check(request(ctx, "PUT", "me/consents/chat_import", b.AccessToken, map[string]any{"version": "v1", "granted": true}), 200, nil)
	expectedSummary.Store("")
	bIn := app.CreateReplyInput{RequestId: uuid.New(), ChatText: raw}
	var bReply app.Reply
	check(request(ctx, "POST", "replies", b.AccessToken, bIn), 200, &bReply)
	bFeedback := "replies/" + bReply.Id.String() + "/feedback"
	check(request(ctx, "POST", bFeedback, b.AccessToken, map[string]any{"index": 0, "outcome": "账号删除前效果", "self_report": "not_overwhelmed"}), 200, nil)
	if e = s.db.QueryRow(ctx, `select count(*) filter (where pending and self_report),count(*) filter (where outcome_pending) from reply_feedback where activity_id=$1`, bReply.Id).Scan(&pendingSelf, &pendingOutcome); e != nil || pendingSelf != 1 || pendingOutcome != 1 {
		t.Fatal("account deletion fixture was not pending", pendingSelf, pendingOutcome, e)
	}
	if e = s.Replies.ReplayPending(ctx); e != nil {
		t.Fatal(e)
	}
	var bReceipt, bObservation int
	if e = s.db.QueryRow(ctx, `select (select count(*) from reply_outcome_receipts r join activities a on a.id=(select activity_id from reply_feedback where id=r.feedback_id) where a.user_id=$1),(select count(*)+0 from profile_observations where user_id=$1 and applied)`, b.UserId).Scan(&bReceipt, &bObservation); e != nil || bReceipt != 1 || bObservation != 1 {
		t.Fatal("account deletion fixtures were not consumed", bReceipt, bObservation, e)
	}
	var bEvent events.ReplyOutcome
	if e = s.db.QueryRow(ctx, `select feedback_id,user_id,source_id,source_kind,occurred_at from reply_outcome_receipts r where user_id=$1`, b.UserId).Scan(&bEvent.FeedbackID, &bEvent.UserID, &bEvent.SourceID, &bEvent.SourceKind, &bEvent.OccurredAt); e != nil {
		t.Fatal(e)
	}
	priorCalls = calls.Load()
	if e = s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: b.UserId, Scope: "account"}); e != nil {
		t.Fatal(e)
	}
	if e = s.Replies.ReplayPending(ctx); e != nil {
		t.Fatal(e)
	}
	if e = s.db.QueryRow(ctx, `select (select count(*) from reply_outcome_receipts where user_id=$1),(select count(*) from profile_observations where user_id=$1),(select count(*) from reply_feedback f join activities a on a.id=f.activity_id where a.user_id=$1)`, b.UserId).Scan(&bReceipt, &bObservation, &remaining); e != nil || bReceipt != 0 || bObservation != 0 || remaining != 0 {
		t.Fatal("account deletion retained reply data", bReceipt, bObservation, remaining, e)
	}
	if calls.Load() != priorCalls {
		t.Fatal("account deletion resurrected reply generation")
	}
	if e = s.Data.Access(ctx, b.UserId, func(tx pgx.Tx) error {
		return s.Profiles.ConsumeReplyOutcome(ctx, tx, bEvent, s.Replies)
	}); e == nil {
		t.Fatal("stale outcome was accepted after account deletion")
	}
	if e = s.db.QueryRow(ctx, `select count(*) from reply_outcome_receipts where feedback_id=$1`, bEvent.FeedbackID).Scan(&bReceipt); e != nil || bReceipt != 0 {
		t.Fatal("stale outcome recreated a receipt", bReceipt, e)
	}
	if e = s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: a.UserId, Scope: "account"}); e != nil {
		t.Fatal(e)
	}
}

// The authorization transaction already owns the only application connection
// when a provider dispatch starts. A database-backed dispatch step must reuse
// that transaction instead of waiting for a second pool connection.
func TestReplyDispatchReusesSinglePoolConnection(t *testing.T) {
	t.Setenv("DATABASE_POOL_MAX_CONNS", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	bus := events.New(s.Data, nil)
	const normal = `{"possible_feeling":"可能在担心进度","possible_need":"想知道具体时间","suggestions":[{"style":"直接","text":"我周三发计划。","reason":"明确时间。"},{"style":"确认","text":"你希望先看计划吗？","reason":"给出选择。"}]}`
	const raw = "T21-SYNTHETIC-SINGLE-POOL"
	s.Replies = replies.New(s.Accounts, s.Membership, s.Data, s.Fields, s.db, bus, cfg.authMaster, func(stop gateway.Stop) (replies.Runner, error) {
		return syntheticRun(func(c context.Context, v gateway.Call) (gateway.Reply, error) {
			if v.Authorize == nil {
				return gateway.Reply{}, errors.New("missing dispatch authorization")
			}
			if e := v.Authorize(c, nil, func(sendCtx context.Context, tx pgx.Tx) error {
				if tx == nil {
					return errors.New("missing authorization transaction")
				}
				var version uuid.UUID
				if e := tx.QueryRow(sendCtx, `select version from gateway_revision where singleton`).Scan(&version); e != nil {
					return e
				}
				if version == uuid.Nil {
					return errors.New("empty gateway revision")
				}
				return nil
			}); e != nil {
				return gateway.Reply{}, e
			}
			return gateway.Reply{CallID: uuid.New(), Result: gateway.Result{Object: []byte(normal)}}, nil
		}), nil
	})
	router := s.Router()
	request := func(method, path, tok string, body any) (int, []byte) {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b)).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return w.Code, w.Body.Bytes()
	}
	ticket := uuid.NewString()
	if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); e != nil {
		t.Fatal(e)
	}
	code, body := request("POST", "auth/login", "", map[string]any{"credential": map[string]any{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"})
	if code != 200 {
		t.Fatalf("login status %d", code)
	}
	var tok app.Tokens
	if e := json.Unmarshal(body, &tok); e != nil {
		t.Fatal(e)
	}
	if code, _ = request("PUT", "me/consents/chat_import", tok.AccessToken, map[string]any{"version": "v1", "granted": true}); code != 200 {
		t.Fatalf("consent status %d", code)
	}
	if code, _ = request("POST", "replies", tok.AccessToken, app.CreateReplyInput{RequestId: uuid.New(), ChatText: raw}); code != 200 {
		t.Fatalf("single-pool reply status %d", code)
	}
}

// A reply may only reuse the exact contacts grant that authorized its profile
// read. Withdrawing and regranting while input review is in flight must stop the
// not-yet-started model dispatch, and doing so after output review must still
// block the final save and charge.
func TestReplyContactRegrantBlocksPendingDispatchAndSave(t *testing.T) {
	t.Setenv("DATABASE_POOL_MAX_CONNS", "3")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()

	profiles := &countingProfileProvider{inner: s.Profiles}
	firstDispatchDone := make(chan struct{})
	outputReviewDone := make(chan struct{})
	regrantAfterInputReview := make(chan struct{})
	regrantBeforeSave := make(chan struct{})
	var firstReleaseOnce, secondReleaseOnce sync.Once
	releaseFirst := func() { firstReleaseOnce.Do(func() { close(regrantAfterInputReview) }) }
	releaseSecond := func() { secondReleaseOnce.Do(func() { close(regrantBeforeSave) }) }
	defer releaseFirst()
	defer releaseSecond()

	var runs, sends atomic.Int32
	const normal = `{"possible_feeling":"可能在担心进度","possible_need":"想知道具体时间","suggestions":[{"style":"直接","text":"我周三发计划。","reason":"明确时间。"},{"style":"确认","text":"你希望先看计划吗？","reason":"给出选择。"}]}`
	const raw = "T21-SYNTHETIC-CONTACTS-REGRANT"
	s.Replies = replies.New(s.Accounts, s.Membership, s.Data, s.Fields, s.db, s.Bus, cfg.authMaster, func(stop gateway.Stop) (replies.Runner, error) {
		return syntheticRun(func(c context.Context, v gateway.Call) (gateway.Reply, error) {
			run := runs.Add(1)
			if run > 2 || v.Authorize == nil {
				return gateway.Reply{}, errors.New("unexpected or unauthorized dispatch")
			}
			var message struct {
				Profile string `json:"profile_summary"`
			}
			if e := json.Unmarshal([]byte(v.Messages[0].Content), &message); e != nil || strings.TrimSpace(message.Profile) == "" {
				return gateway.Reply{}, errors.New("missing contact profile summary")
			}
			dispatch := func() error {
				return v.Authorize(c, nil, func(context.Context, pgx.Tx) error {
					sends.Add(1)
					return nil
				})
			}
			switch run {
			case 1:
				if e := dispatch(); e != nil {
					return gateway.Reply{}, e
				}
				close(firstDispatchDone)
				select {
				case <-regrantAfterInputReview:
				case <-c.Done():
					return gateway.Reply{}, c.Err()
				}
				if e := dispatch(); !errors.Is(e, membership.ErrForbidden) {
					return gateway.Reply{}, e
				}
				return gateway.Reply{}, membership.ErrForbidden
			case 2:
				for range 3 {
					if e := dispatch(); e != nil {
						return gateway.Reply{}, e
					}
				}
				close(outputReviewDone)
				select {
				case <-regrantBeforeSave:
				case <-c.Done():
					return gateway.Reply{}, c.Err()
				}
				return gateway.Reply{CallID: uuid.New(), Result: gateway.Result{Object: []byte(normal)}}, nil
			}
			return gateway.Reply{}, errors.New("unreachable")
		}), nil
	})
	s.Replies.AttachProfiles(profiles)
	router := s.Router()
	type res struct {
		code int
		b    []byte
	}
	request := func(method, path, tok string, body any) res {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b)).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return res{w.Code, w.Body.Bytes()}
	}
	check := func(r res, code int) {
		t.Helper()
		if r.code != code {
			t.Fatalf("status %d want %d: %s", r.code, code, r.b)
		}
	}
	ticket := uuid.NewString()
	if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); e != nil {
		t.Fatal(e)
	}
	var tok app.Tokens
	login := request("POST", "auth/login", "", map[string]any{"credential": map[string]any{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"})
	check(login, 200)
	if e := json.Unmarshal(login.b, &tok); e != nil {
		t.Fatal(e)
	}
	check(request("PUT", "me/consents/chat_import", tok.AccessToken, map[string]any{"version": "v1", "granted": true}), 200)

	check(request("PUT", "me/consents/contacts", tok.AccessToken, map[string]any{"version": "v1", "granted": true}), 200)
	var contact app.Contact
	contactResult := request("POST", "contacts", tok.AccessToken, map[string]any{"nickname": "合成联系人", "scene": "partner", "initial_context": "愿意尝试"})
	check(contactResult, 200)
	if e := json.Unmarshal(contactResult.b, &contact); e != nil || contact.Id == uuid.Nil {
		t.Fatal("invalid contact")
	}
	activeConsent := func(purpose string) uuid.UUID {
		t.Helper()
		var id uuid.UUID
		if e := s.db.QueryRow(ctx, `select id from consents where user_id=$1 and purpose=$2 and withdrawn_at is null`, tok.UserId, purpose).Scan(&id); e != nil {
			t.Fatal(e)
		}
		return id
	}
	chatConsent := activeConsent("chat_import")
	firstContactsConsent := activeConsent("contacts")

	in := app.CreateReplyInput{RequestId: uuid.New(), ChatText: raw, ContactId: &contact.Id}
	firstKey := in.RequestId
	firstResult := make(chan res, 1)
	go func() { firstResult <- request("POST", "replies", tok.AccessToken, in) }()
	select {
	case <-firstDispatchDone:
	case <-time.After(5 * time.Second):
		t.Fatal("input review dispatch did not start")
	}
	check(request("PUT", "me/consents/contacts", tok.AccessToken, map[string]any{"version": "v1", "granted": false}), 200)
	check(request("PUT", "me/consents/contacts", tok.AccessToken, map[string]any{"version": "v1", "granted": true}), 200)
	secondContactsConsent := activeConsent("contacts")
	if secondContactsConsent == firstContactsConsent {
		t.Fatal("contacts regrant reused the old consent row")
	}
	releaseFirst()
	check(<-firstResult, 403)
	if runs.Load() != 1 || sends.Load() != 1 || profiles.calls.Load() != 1 {
		t.Fatalf("input-review regrant counts runs=%d sends=%d profiles=%d", runs.Load(), sends.Load(), profiles.calls.Load())
	}

	in.RequestId = uuid.New()
	secondResult := make(chan res, 1)
	go func() { secondResult <- request("POST", "replies", tok.AccessToken, in) }()
	select {
	case <-outputReviewDone:
	case <-time.After(5 * time.Second):
		t.Fatal("output review dispatch did not start")
	}
	check(request("PUT", "me/consents/contacts", tok.AccessToken, map[string]any{"version": "v1", "granted": false}), 200)
	check(request("PUT", "me/consents/contacts", tok.AccessToken, map[string]any{"version": "v1", "granted": true}), 200)
	thirdContactsConsent := activeConsent("contacts")
	if thirdContactsConsent == secondContactsConsent {
		t.Fatal("second contacts regrant reused the prior consent row")
	}
	releaseSecond()
	check(<-secondResult, 403)
	if runs.Load() != 2 || sends.Load() != 4 || profiles.calls.Load() != 2 {
		t.Fatalf("final-save regrant counts runs=%d sends=%d profiles=%d", runs.Load(), sends.Load(), profiles.calls.Load())
	}
	if activeConsent("chat_import") != chatConsent {
		t.Fatal("chat_import grant changed during contacts regrant")
	}

	for i, want := range []struct {
		request  uuid.UUID
		contacts uuid.UUID
	}{
		{firstKey, firstContactsConsent},
		{in.RequestId, secondContactsConsent},
	} {
		var gotChat, gotContacts uuid.UUID
		if e := s.db.QueryRow(ctx, `select chat_consent_id,contacts_consent_id from reply_requests where user_id=$1 and request_id=$2`, tok.UserId, want.request).Scan(&gotChat, &gotContacts); e != nil {
			t.Fatalf("read request %d consent binding: %v", i, e)
		}
		if gotChat != chatConsent || gotContacts != want.contacts {
			t.Fatalf("request %d binding chat=%s contacts=%s", i, gotChat, gotContacts)
		}
	}
	var failed, billed int
	if err := s.db.QueryRow(ctx, `select
        (select count(*) from activities where user_id=$1 and kind='reply' and state='failed' and content_enc is null),
        (select count(*) from quota_ledger l join activities a on a.id=l.activity_id where a.user_id=$1 and l.refunded_at is null)`, tok.UserId).Scan(&failed, &billed); err != nil || failed != 2 || billed != 0 {
		t.Fatalf("revoked requests: failed=%d billed=%d err=%v", failed, billed, err)
	}
}

// The account lock must cover every actual external send, not just the consent
// check before it. Otherwise a withdrawal can commit while a request is still
// between authorization and a provider call. Once the queued withdrawal
// commits, later output review must fail closed and the generated result must
// not be persisted or charged.
func TestReplyWithdrawalWaitsForInFlightDispatch(t *testing.T) {
	t.Setenv("DATABASE_POOL_MAX_CONNS", "2")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	bus := events.New(s.Data, nil)
	dispatchStarted := make(chan struct{})
	releaseDispatch := make(chan struct{})
	continueToReview := make(chan struct{})
	authorizePID := make(chan int32, 1)
	var releaseOnce, reviewOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseDispatch) }) }
	review := func() { reviewOnce.Do(func() { close(continueToReview) }) }
	var runs, sends atomic.Int32
	const normal = `{"possible_feeling":"可能在担心进度","possible_need":"想知道具体时间","suggestions":[{"style":"直接","text":"我周三发计划。","reason":"明确时间。"},{"style":"确认","text":"你希望先看计划吗？","reason":"给出选择。"}]}`
	const raw = "T21-SYNTHETIC-WITHDRAWAL-RACE"
	s.Replies = replies.New(s.Accounts, s.Membership, s.Data, s.Fields, s.db, bus, cfg.authMaster, func(stop gateway.Stop) (replies.Runner, error) {
		return syntheticRun(func(c context.Context, v gateway.Call) (gateway.Reply, error) {
			if runs.Add(1) != 1 || v.Authorize == nil {
				return gateway.Reply{}, errors.New("unexpected or unauthorized dispatch")
			}
			// First dispatch: hold the authorization transaction while the provider
			// call is in flight, then wait for the withdrawal to commit before the
			// production runner would perform its next (output-review) dispatch.
			if e := v.Authorize(c, nil, func(sendCtx context.Context, tx pgx.Tx) error {
				if tx == nil {
					return errors.New("missing authorization transaction")
				}
				sends.Add(1)
				var pid int32
				if e := tx.QueryRow(sendCtx, `select pg_backend_pid()`).Scan(&pid); e != nil {
					return e
				}
				authorizePID <- pid
				close(dispatchStarted)
				select {
				case <-releaseDispatch:
					return nil
				case <-sendCtx.Done():
					return sendCtx.Err()
				}
			}); e != nil {
				return gateway.Reply{}, e
			}
			select {
			case <-continueToReview:
			case <-c.Done():
				return gateway.Reply{}, c.Err()
			}
			if e := v.Authorize(c, nil, func(context.Context, pgx.Tx) error {
				sends.Add(1)
				return nil
			}); !errors.Is(e, replies.ErrConsent) {
				return gateway.Reply{}, e
			}
			return gateway.Reply{CallID: uuid.New(), Result: gateway.Result{Object: []byte(normal)}}, nil
		}), nil
	})
	router := s.Router()
	type res struct {
		code int
		b    []byte
	}
	request := func(method, path, tok string, body any) res {
		b, _ := json.Marshal(body)
		req := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b)).WithContext(ctx)
		req.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, req)
		return res{w.Code, w.Body.Bytes()}
	}
	check := func(r res, code int) {
		t.Helper()
		if r.code != code {
			t.Fatalf("status %d want %d: %s", r.code, code, r.b)
		}
	}
	ticket := uuid.NewString()
	if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); e != nil {
		t.Fatal(e)
	}
	var tok app.Tokens
	login := request("POST", "auth/login", "", map[string]any{"credential": map[string]any{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"})
	check(login, 200)
	if e := json.Unmarshal(login.b, &tok); e != nil {
		t.Fatal(e)
	}
	check(request("PUT", "me/consents/chat_import", tok.AccessToken, map[string]any{"version": "v1", "granted": true}), 200)
	in := app.CreateReplyInput{RequestId: uuid.New(), ChatText: raw}
	reply := make(chan res, 1)
	replyDone := make(chan struct{})
	go func() {
		defer close(replyDone)
		reply <- request("POST", "replies", tok.AccessToken, in)
	}()
	defer func() {
		release()
		review()
		select {
		case <-replyDone:
		case <-time.After(5 * time.Second):
		}
	}()
	select {
	case <-dispatchStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("dispatch not started")
	}
	var authorizationPID int32
	select {
	case authorizationPID = <-authorizePID:
	case <-time.After(5 * time.Second):
		t.Fatal("authorization backend pid not captured")
	}
	observer, e := pgx.Connect(ctx, cfg.DatabaseURL)
	if e != nil {
		t.Fatal(e)
	}
	defer observer.Close(ctx)
	principal, e := s.Accounts.Parse(tok.AccessToken)
	if e != nil {
		t.Fatal(e)
	}
	type consentResult struct {
		consent app.Consent
		err     error
	}
	withdrawal := make(chan consentResult, 1)
	withdrawCtx, withdrawCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer withdrawCancel()
	go func() {
		c, e := s.Accounts.Consent(withdrawCtx, principal, "chat_import", "v1", false)
		withdrawal <- consentResult{c, e}
	}()
	// Prove that the withdrawal backend itself is blocked by the exact backend
	// holding the authorization transaction, rather than merely losing a
	// scheduling race. pg_blocking_pids includes tuple/transaction waits that a
	// relation-lock scan misses.
	deadline := time.Now().Add(5 * time.Second)
	for {
		select {
		case r := <-withdrawal:
			t.Fatalf("withdrawal returned while dispatch was still blocked: %v", r.err)
		default:
		}
		var waiting bool
		if e := observer.QueryRow(ctx, `select exists(
 select 1 from pg_stat_activity a
 where a.datname=current_database() and a.pid<>pg_backend_pid()
   and $1=any(pg_blocking_pids(a.pid))
   and (
     regexp_replace(lower(a.query),'[[:space:]]+',' ','g') like 'update consents %'
     or (regexp_replace(lower(a.query),'[[:space:]]+',' ','g') like 'select id from users %'
         and regexp_replace(lower(a.query),'[[:space:]]+',' ','g') like '% for update%')
   ))`, authorizationPID).Scan(&waiting); e != nil {
			t.Fatal("inspect withdrawal lock", e)
		}
		if waiting {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("withdrawal did not wait on the dispatch lock")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// Release the first provider call and prove the queued withdrawal commits
	// before the runner can reach output review. The second authorization must
	// then reject without executing its send/provider callback.
	release()
	select {
	case r := <-withdrawal:
		if r.err != nil || r.consent.Granted {
			t.Fatalf("withdrawal failed: consent=%+v err=%v", r.consent, r.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("withdrawal did not finish after dispatch release")
	}
	review()
	var replyResult res
	select {
	case replyResult = <-reply:
	case <-time.After(5 * time.Second):
		t.Fatal("reply did not finish after withdrawal")
	}
	if replyResult.code != 403 {
		t.Fatalf("reply status %d after in-flight withdrawal, want 403: %s", replyResult.code, replyResult.b)
	}
	if runs.Load() != 1 || sends.Load() != 1 {
		t.Fatalf("dispatch counts runs=%d sends=%d, want 1/1", runs.Load(), sends.Load())
	}
	var state string
	var resultBytes, charged int
	if e = s.db.QueryRow(ctx, `select a.state,coalesce(octet_length(a.content_enc),0) from activities a join reply_request_keys k on k.activity_id=a.id where k.user_id=$1 and k.request_id=$2`, principal.User, in.RequestId).Scan(&state, &resultBytes); e != nil || state != "failed" || resultBytes != 0 {
		t.Fatal("withdrawn in-flight result was retained", state, resultBytes, e)
	}
	if e = s.db.QueryRow(ctx, `select coalesce(sum(used),0)::int from daily_quota_usage where user_id=$1 and feature='reply'`, principal.User).Scan(&charged); e != nil || charged != 0 {
		t.Fatal("withdrawn in-flight request was charged", charged, e)
	}
	in.RequestId = uuid.New()
	before := sends.Load()
	check(request("POST", "replies", tok.AccessToken, in), 403)
	if sends.Load() != before {
		t.Fatal("withdrawn request reached gateway")
	}
}
