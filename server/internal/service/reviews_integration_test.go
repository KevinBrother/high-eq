//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

type reviewResponse struct {
	code int
	body []byte
}
type reviewRun func(context.Context, gateway.Call) (gateway.Reply, error)

func (f reviewRun) Run(ctx context.Context, c gateway.Call) (gateway.Reply, error) { return f(ctx, c) }

func TestReviewLifecycle(t *testing.T) {
	ctx := t.Context()
	f := &reviewUpstream{entered: make(chan struct{}), resume: make(chan struct{}), outputEntered: make(chan struct{}, 1), releaseOutput: make(chan struct{})}
	s := reviewRuntime(t, f)
	router := s.Router()
	request := func(method, path, token string, in any) reviewResponse {
		b, _ := json.Marshal(in)
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return reviewResponse{w.Code, w.Body.Bytes()}
	}
	check := func(r reviewResponse, code int, out any) {
		t.Helper()
		if r.code != code {
			t.Fatalf("wanted %d, got %d: %s", code, r.code, r.body)
		}
		if out != nil {
			if e := json.Unmarshal(r.body, out); e != nil {
				t.Fatal(e)
			}
		}
	}
	must := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	signup := func() app.Tokens {
		ticket := uuid.NewString()
		must(s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err())
		var v app.Tokens
		check(request("POST", "auth/login", "", map[string]any{"credential": map[string]string{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"}), 200, &v)
		return v
	}
	a, b := signup(), signup()
	consent := func(token string, on bool) {
		check(request("PUT", "me/consents/review", token, map[string]any{"version": "v1", "granted": on}), 200, nil)
	}
	sc := app.ReviewInputSceneWork
	in := app.ReviewInput{RequestId: uuid.New(), Scene: &sc, Happened: "T23-SYNTHETIC-MEETING", MyFeeling: "着急", TheirPossibleFeeling: "也许没说完", MyAction: "我先说完", NextAction: "等对方说完"}
	post := func(in app.ReviewInput) reviewResponse { return request("POST", "reviews", a.AccessToken, in) }
	count := func(q string, want int, args ...any) {
		t.Helper()
		var n int
		must(s.db.QueryRow(ctx, q, args...).Scan(&n))
		if n != want {
			t.Fatalf("expected %d rows, got %d in %s", want, n, q)
		}
	}
	usage := func(n int) {
		count(`select coalesce(sum(used),0) from daily_quota_usage where feature='review' and user_id=$1`, n, a.UserId)
	}
	check(post(in), 403, nil)
	consent(a.AccessToken, true)
	invalid := in
	invalid.MyAction = "   "
	check(post(invalid), 400, nil)
	unknown := uuid.New()
	invalid = in
	invalid.MarkId = &unknown
	check(post(invalid), 400, nil)
	// Persist a projection in the actual subscriber transaction, then fail it. Neither
	// the projection nor the outbox ACK may survive the failed delivery.
	ready := false
	var delivered events.Score
	var success int
	s.Bus.ScoreCompleted.Subscribe(func(c context.Context, tx pgx.Tx, v events.Score) error {
		data, _ := json.Marshal(v)
		if bytes.Contains(data, []byte("reason")) || v.Kind != "review" || v.NVC.Total != 20 {
			return errors.New("unexpected score projection")
		}
		// The production T26 subscriber ran first in this transaction. Don't
		// insert a second test projection; check the numeric source is present,
		// then inject a downstream failure to prove both projection and ACK roll back.
		var projected bool
		if err := tx.QueryRow(c, `select exists(select from growth_scores where score_id=$1 and kind='review')`, v.SourceID).Scan(&projected); err != nil {
			return err
		}
		if !projected {
			return errors.New("growth did not consume the canonical score")
		}
		if !ready {
			return errors.New("synthetic subscriber rollback")
		}
		delivered = v
		success++
		return nil
	})
	done := make(chan reviewResponse, 1)
	go func(v app.ReviewInput) { done <- post(v) }(in)
	select {
	case <-f.entered:
	case early := <-done:
		t.Fatalf("before gateway: %d %s", early.code, early.body)
	case <-time.After(8 * time.Second):
		t.Fatal("gateway not reached")
	}
	check(post(in), 202, nil)
	changed := in
	changed.NextAction = "其他计划"
	check(post(changed), 409, nil)
	close(f.resume)
	var v app.Review
	check(<-done, 200, &v)
	if v.Submitted.MyAction != in.MyAction || v.Score.Nvc.Total != 20 || v.RepairPhrase == "" || v.Score.ScoreId == v.Id {
		t.Fatal("bad journal")
	}
	usage(1)
	var encrypted, detail, requestMAC []byte
	var source uuid.UUID
	var at time.Time
	must(s.db.QueryRow(ctx, `select a.content_enc,s.detail_enc,r.input_mac,a.source_id,s.occurred_at from activities a join scores s on s.id=a.source_id join review_requests r on r.activity_id=a.id where a.id=$1 and r.score_pending`, v.Id).Scan(&encrypted, &detail, &requestMAC, &source, &at))
	if source != v.Score.ScoreId || len(requestMAC) != 32 || bytes.Contains(encrypted, []byte(in.Happened)) || bytes.Contains(detail, []byte("合成引文")) {
		t.Fatal("source encryption or key mismatch")
	}
	count(`select count(*) from ai_calls where activity_id=$1 and task='scoring' and score_id=$2`, 1, v.Id, source)
	count(`select count(*) from growth_scores where score_id=$1`, 0, source)
	ready = true
	must(s.Reviews.ReplayPending(ctx))
	must(s.Reviews.ReplayPending(ctx))
	if success != 1 || !delivered.OccurredAt.Equal(at) {
		t.Fatal("non-idempotent or retimed event")
	}
	var replay app.Review
	check(post(in), 200, &replay)
	if !reflect.DeepEqual(v, replay) || f.scores.Load() != 1 || f.analyses.Load() != 1 {
		t.Fatal("replayed generation")
	}
	path := "reviews/" + v.Id.String()
	check(request("GET", path, b.AccessToken, nil), 404, nil)
	check(request("DELETE", path, b.AccessToken, nil), 404, nil)
	check(request("GET", path, a.AccessToken, nil), 200, &replay)
	usage(1)
	// If T25 is present use its real feedback endpoint. The journal itself contains
	// no assertion of another person's state; a score never emits a profile vote.
	if s.Reviews.Profile != nil {
		note := "本人没有上头"
		fb := app.SendProfileFeedbackInput{SourceId: v.Score.ScoreId, Confirmed: true, Subject: "self", Note: &note}
		for range 2 {
			check(request("POST", "profiles/feedback", a.AccessToken, fb), 200, nil)
		}
		count(`select count(*) from profile_observations where activity_id=$1 and applied`, 1, v.Id)
	}
	newer := in
	newer.RequestId = uuid.New()
	f.mode.Store(1)
	var safety gateway.Terminal
	check(post(newer), 200, &safety)
	if !safety.Safety || safety.Message != gateway.HelpMessage {
		t.Fatal("input crisis disguised as outage")
	}
	check(post(newer), 200, nil)
	usage(1)
	newer.RequestId = uuid.New()
	f.mode.Store(3)
	check(post(newer), 200, &safety)
	if !safety.Safety {
		t.Fatal("score crisis disguised as outage")
	}
	usage(1)
	newer.RequestId = uuid.New()
	f.mode.Store(4)
	check(post(newer), 500, nil)
	usage(1)
	f.mode.Store(0)
	check(post(newer), 500, nil)
	// Fail the scoring input moderation only. Same ID resumes the approved repair,
	// no second repair call, no published score or charge for the failed attempt.
	newer.RequestId = uuid.New()
	f.mode.Store(2)
	outage := post(newer)
	check(outage, 503, nil)
	if !bytes.Contains(outage.body, []byte(`"code":"moderation_unavailable"`)) || bytes.Contains(outage.body, []byte(gateway.HelpMessage)) {
		t.Fatal("wrong outage body")
	}
	usage(1)
	analyses := f.analyses.Load()
	f.mode.Store(0)
	var second app.Review
	check(post(newer), 200, &second)
	if f.analyses.Load() != analyses {
		t.Fatal("duplicate approved analysis")
	}
	usage(2)
	var page app.ListReviewsResult
	check(request("GET", "reviews?scene=work&limit=1", a.AccessToken, nil), 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != second.Id || page.NextCursor == nil {
		t.Fatal("bad first page")
	}
	check(request("GET", "reviews?scene=work&limit=1&cursor="+*page.NextCursor, a.AccessToken, nil), 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != v.Id || page.NextCursor != nil {
		t.Fatal("bad next page")
	}
	check(request("GET", "reviews?scene=family", a.AccessToken, nil), 200, &page)
	if len(page.Items) != 0 {
		t.Fatal("scene leaked")
	}
	// Force LinkScoreTx to fail after insertion. SaveApproved must roll the whole
	// transaction back including score, content, event and debit.
	original := s.Reviews.Router
	s.Reviews.Router = func(stop gateway.Stop) (scoring.Runner, error) {
		r, e := original(stop)
		return reviewRun(func(c context.Context, v gateway.Call) (gateway.Reply, error) {
			reply, e := r.Run(c, v)
			if v.Task == gateway.Scoring {
				reply.CallID = uuid.New()
			}
			return reply, e
		}), e
	}
	bad := in
	bad.RequestId = uuid.New()
	check(post(bad), 500, nil)
	s.Reviews.Router = original
	usage(2)
	count(`select count(*) from review_requests r join activities a on a.id=r.activity_id where r.request_id=$1 and a.state='failed' and a.content_enc is null and not r.score_pending and not exists(select from scores where activity_id=a.id)`, 1, bad.RequestId)
	// Revoke while a complete score is in flight, before SaveApproved. The
	// recheck must abort the entire write, even though T10 approved the output.
	s.Reviews.Router = func(stop gateway.Stop) (scoring.Runner, error) {
		r, e := original(stop)
		return reviewRun(func(c context.Context, v gateway.Call) (gateway.Reply, error) {
			out, e := r.Run(c, v)
			if v.Task == gateway.Scoring {
				consent(a.AccessToken, false)
			}
			return out, e
		}), e
	}
	bad.RequestId = uuid.New()
	check(post(bad), 403, nil)
	usage(2)
	s.Reviews.Router = original
	consent(a.AccessToken, true)
	bad.RequestId = uuid.New()
	check(post(bad), 200, nil)
	usage(3)
	bad.RequestId = uuid.New()
	prior := f.analyses.Load()
	check(post(bad), 429, nil)
	if prior != f.analyses.Load() {
		t.Fatal("exhausted quota reached upstream")
	}
	export := func(user uuid.UUID, name string) string {
		var buf bytes.Buffer
		must(s.Data.Export(ctx, privacy.ExportRequest{UserID: user, OperationID: uuid.New()}, &buf))
		z, e := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
		must(e)
		f, e := z.Open(name)
		must(e)
		defer f.Close()
		b, e := io.ReadAll(f)
		must(e)
		return string(b)
	}
	if data := export(a.UserId, "reviews.json"); !strings.Contains(data, source.String()) || !strings.Contains(data, "合成引文") || !strings.Contains(data, in.Happened) || strings.Contains(data, "input_mac") || export(b.UserId, "reviews.json") != "[]" {
		t.Fatal("invalid journal export")
	}
	if !strings.Contains(export(a.UserId, "ai_calls.json"), source.String()) {
		t.Fatal("missing linked calls")
	}
	consent(a.AccessToken, false)
	check(request("DELETE", path, a.AccessToken, nil), 200, nil)
	check(request("GET", path, a.AccessToken, nil), 404, nil)
	usage(3)
	// A deleted request key stays tombstoned. Replaying the original body must not
	// create another review, call the model or consume quota.
	analyses, scores := f.analyses.Load(), f.scores.Load()
	check(post(in), 409, nil)
	if f.analyses.Load() != analyses || f.scores.Load() != scores {
		t.Fatal("deleted request regenerated")
	}
	usage(3)
	if e := s.Bus.PublishScore(ctx, events.Score{ScoreKey: privacy.ScoreKey{UserID: a.UserId, SourceID: source, ActivityID: v.Id, OccurredAt: at, Kind: "review"}}); e == nil {
		t.Fatal("recreated deleted score")
	}
	count(`select count(*) from growth_scores where score_id=$1`, 0, source)
	count(`select count(*) from ai_calls where activity_id=$1`, 0, v.Id)
	if strings.Contains(export(a.UserId, "reviews.json"), source.String()) {
		t.Fatal("deleted score exported")
	}
	// Use a fresh account so the tombstone replay check is not masked by exhausted
	// quota. This exercises the production Gin route, T04 deletion and T23 insert
	// guard together rather than only the SQL trigger.
	c := signup()
	consent(c.AccessToken, true)
	check(request("PUT", "me/consents/assessment", c.AccessToken, map[string]any{"version": "v1", "granted": true}), 200, nil)
	var bank app.GetInstrumentResult
	check(request("GET", "assessments/instrument", c.AccessToken, nil), 200, &bank)
	answers := make([]int, len(bank.Items))
	for i := range answers {
		answers[i] = 4
	}
	check(request("POST", "assessments", c.AccessToken, app.SubmitAssessmentInput{Version: bank.Version, Answers: answers}), 200, nil)
	getReference := func(want int) {
		var g app.GetGrowthResult
		check(request("GET", "growth", c.AccessToken, nil), 200, &g)
		if g.WleisPercent == nil || g.ValidBehaviorCount != want || (g.TrainingReference == nil) != (want == 0) {
			t.Fatalf("reference availability: WLEIS=%v count=%d ref=%v", g.WleisPercent, g.ValidBehaviorCount, g.TrainingReference)
		}
		// Known score fixture: 20 * 0.7 + ((2+3+2)/3 - 1)/4 * 100 * 0.3 = 24.
		if want == 1 && math.Abs(float64(*g.TrainingReference)-(float64(*g.WleisPercent)+24)/2) > .01 {
			t.Fatalf("reference from real review: %v", *g.TrainingReference)
		}
	}
	getReference(0)
	inC := app.ReviewInput{RequestId: uuid.New(), Scene: &sc, Happened: "T23-TOMBSTONE", MyFeeling: "平静", TheirPossibleFeeling: "不确定", MyAction: "我先说完", NextAction: "请对方补充"}
	postC := func(v app.ReviewInput) reviewResponse { return request("POST", "reviews", c.AccessToken, v) }
	var created app.Review
	check(postC(inC), 200, &created)
	getReference(1)
	var canonicalAt time.Time
	must(s.db.QueryRow(ctx, `select occurred_at from scores where id=$1 and activity_id=$2`, created.Score.ScoreId, created.Id).Scan(&canonicalAt))
	if ex := export(c.UserId, "growth.json"); !strings.Contains(ex, created.Score.ScoreId.String()) || strings.Contains(ex, "合成引文") {
		t.Fatal("growth export does not match numeric-only source")
	}
	pathC := "reviews/" + created.Id.String()
	check(request("DELETE", pathC, c.AccessToken, nil), 200, nil)
	if err := s.Bus.PublishScore(ctx, events.Score{ScoreKey: privacy.ScoreKey{UserID: c.UserId, ActivityID: created.Id, SourceID: created.Score.ScoreId, OccurredAt: canonicalAt, Kind: "review"}}); err == nil {
		t.Fatal("deleted review was accepted by score bus")
	}
	getReference(0)
	if strings.Contains(export(c.UserId, "growth.json"), created.Score.ScoreId.String()) {
		t.Fatal("growth export kept the erased score")
	}

	analyses, scores = f.analyses.Load(), f.scores.Load()
	check(postC(inC), 409, nil)
	if f.analyses.Load() != analyses || f.scores.Load() != scores {
		t.Fatal("deleted account request reached upstream")
	}
	count(`select coalesce(sum(used),0) from daily_quota_usage where feature='review' and user_id=$1`, 1, c.UserId)
	count(`select count(*) from review_requests r join activities a on a.id=r.activity_id where a.user_id=$1`, 0, c.UserId)
	// Real concurrent requests: the first retry is waiting on moderation of an
	// already produced score. A second request observes the retention boundary.
	expiryUser := signup()
	consent(expiryUser.AccessToken, true)
	expiring := inC
	expiring.RequestId = uuid.New()
	retryExpiry := func() reviewResponse { return request("POST", "reviews", expiryUser.AccessToken, expiring) }
	f.mode.Store(5)
	check(retryExpiry(), 503, nil)
	count(`select count(*) from review_requests where user_id=$1 and request_id=$2 and generated_task='scoring' and generated_enc is not null`, 1, expiryUser.UserId, expiring.RequestId)
	expiryAnalyses, expiryScores := f.analyses.Load(), f.scores.Load()
	f.mode.Store(6)
	releaseOutput := sync.OnceFunc(func() { close(f.releaseOutput) })
	defer releaseOutput()
	waiting := make(chan reviewResponse, 1)
	go func() { waiting <- retryExpiry() }()
	select {
	case <-f.outputEntered:
	case early := <-waiting:
		t.Fatalf("recovery stopped before output moderation: %d", early.code)
	case <-time.After(5 * time.Second):
		t.Fatal("recovery never reached score moderation")
	}
	check(retryExpiry(), 202, nil)
	_, e := s.db.Exec(ctx, `update review_requests set generated_at=clock_timestamp()-interval '16 minutes' where request_id=$1 and user_id=$2`, expiring.RequestId, expiryUser.UserId)
	must(e)
	var expiredWire app.Error
	check(retryExpiry(), 409, &expiredWire)
	if expiredWire.Retryable {
		t.Fatal("an expired request key is not retryable")
	}
	releaseOutput()
	select {
	case old := <-waiting:
		if old.code >= 200 && old.code < 300 {
			t.Fatalf("old worker returned success after terminal expiry: %d", old.code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("in-flight recovery did not finish")
	}
	check(retryExpiry(), 409, nil)
	if f.analyses.Load() != expiryAnalyses || f.scores.Load() != expiryScores {
		t.Fatal("generated the original review again during recovery")
	}
	count(`select count(*) from scores join activities a on a.id=scores.activity_id where a.user_id=$1`, 0, expiryUser.UserId)
	count(`select coalesce(sum(used),0) from daily_quota_usage where user_id=$1 and feature='review'`, 0, expiryUser.UserId)
	count(`select count(*) from review_requests where user_id=$1 and request_id=$2 and generated_expired and generated_enc is null and repair_enc is null and not score_pending`, 1, expiryUser.UserId, expiring.RequestId)
	f.mode.Store(0)
	must(s.Data.Delete(ctx, privacy.Deletion{UserID: a.UserId, Scope: "account", OperationID: uuid.New()}))
	if e := s.Bus.PublishScore(ctx, delivered); e == nil {
		t.Fatal("recreated deleted account")
	}
}
