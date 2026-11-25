//go:build integration && t24quota

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

const (
	t24Checkpoint   = "/__t24/checkpoint"
	t24FlutterTest  = "tool/t24/quota_reset_journey_test.dart"
	t24FlutterLimit = 6 * time.Minute
	// The account day is UTC; only the Flutter child renders in Shanghai. The
	// service reset instant (UTC midnight) therefore appears as 08:00 on the
	// device, never as the device's own 00:00. The two zones are explicit.
	t24AccountZone = "UTC"
	t24DeviceZone  = "Asia/Shanghai"
)

type t24Calls struct {
	mu          sync.Mutex
	counts      map[string]int
	reviewPosts int
	reviewCode  string
	reviewAt    bool
}

func (c *t24Calls) record(method, path string, status int, body []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.counts[method+" "+path]++
	if method != http.MethodPost || path != "/v1/reviews" {
		return
	}
	c.reviewPosts++
	if status != http.StatusTooManyRequests {
		return
	}
	var problem struct {
		Code    string          `json:"code"`
		RetryAt json.RawMessage `json:"retry_at"`
	}
	if json.Unmarshal(body, &problem) == nil {
		c.reviewCode = problem.Code
		c.reviewAt = len(problem.RetryAt) > 0 && string(problem.RetryAt) != "null"
	}
}

func (c *t24Calls) count(key string) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.counts[key]
}

func (c *t24Calls) purchasePosts() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	total := 0
	for key, n := range c.counts {
		if strings.HasPrefix(key, "POST /v1/purchases") {
			total += n
		}
	}
	return total
}

func (c *t24Calls) review() (posts int, code string, retryAt bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.reviewPosts, c.reviewCode, c.reviewAt
}

type t24Observed struct {
	ErrorText      string `json:"error_text"`
	ReviewTitle    string `json:"review_title"`
	ResetText      string `json:"reset_text"`
	PracticeTitle  string `json:"practice_title"`
	ReplyTitle     string `json:"reply_title"`
	ExhaustedRows  int    `json:"exhausted_rows"`
	LocalOffsetMin int    `json:"local_offset_minutes"`
}

// t24Snapshot is a fixture-only readback taken from the same running service
// while the real MemberPage request is in flight. It never submits a review.
type t24Snapshot struct {
	Stage              string `json:"stage"`
	ReviewRemaining    int    `json:"review_remaining"`
	PracticeRemaining  int    `json:"practice_remaining"`
	ReplyRemaining     int    `json:"reply_remaining"`
	ResetsAt           string `json:"resets_at"`
	ReviewUsed         int    `json:"review_used"`
	ReviewRequests     int    `json:"review_requests"`
	ReviewActivities   int    `json:"review_activities"`
	Ledger             int    `json:"ledger"`
	ReviewsPosted      int    `json:"reviews_posted"`
	PurchasePosts      int    `json:"purchase_posts"`
	GenerationAnalyses int    `json:"generation_analyses"`
	GenerationScores   int    `json:"generation_scores"`
	ReviewStatus       int    `json:"review_status"`
	ReviewCode         string `json:"review_code"`
	ReviewHasRetryAt   bool   `json:"review_has_retry_at"`
}

type t24Fixture struct {
	ctx    context.Context
	s      *Runtime
	token  string
	user   uuid.UUID
	secret string
	calls  *t24Calls
	vendor *reviewUpstream

	mu        sync.Mutex
	snapshots map[string]t24Snapshot
	observed  map[string]t24Observed
}

func (f *t24Fixture) checkpoint(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.Header.Get("X-T24-Fixture") != f.secret {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var raw struct {
		t24Observed
		Stage string `json:"stage"`
	}
	if json.NewDecoder(r.Body).Decode(&raw) != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	in, stage := raw.t24Observed, raw.Stage
	switch stage {
	case "quota_shown", "member_view", "returned":
	default:
		http.Error(w, "unknown stage", http.StatusBadRequest)
		return
	}
	snapshot, err := f.readback(stage)
	if err != nil {
		http.Error(w, "readback failed", http.StatusInternalServerError)
		return
	}
	f.mu.Lock()
	f.snapshots[stage] = snapshot
	f.observed[stage] = in
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(snapshot)
}

func (f *t24Fixture) readback(stage string) (t24Snapshot, error) {
	out := t24Snapshot{Stage: stage}
	var rights app.Entitlements
	if err := f.get("/v1/entitlements", &rights); err != nil {
		return out, err
	}
	for _, allowance := range rights.Allowances {
		switch string(allowance.Feature) {
		case "review":
			if allowance.Remaining != nil {
				out.ReviewRemaining = *allowance.Remaining
			}
		case "practice":
			if allowance.Remaining != nil {
				out.PracticeRemaining = *allowance.Remaining
			}
		case "reply":
			if allowance.Remaining != nil {
				out.ReplyRemaining = *allowance.Remaining
			}
		}
		out.ResetsAt = allowance.ResetsAt.Format(time.RFC3339Nano)
	}
	if err := f.s.db.QueryRow(f.ctx, `select coalesce(sum(used),0) from daily_quota_usage where user_id=$1 and feature='review'`, f.user).Scan(&out.ReviewUsed); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from review_requests where user_id=$1`, f.user).Scan(&out.ReviewRequests); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from activities where user_id=$1 and kind='review'`, f.user).Scan(&out.ReviewActivities); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from quota_ledger q join activities a on a.id=q.activity_id where a.user_id=$1 and a.kind='review'`, f.user).Scan(&out.Ledger); err != nil {
		return out, err
	}
	out.ReviewsPosted = f.calls.count("POST /v1/reviews")
	out.PurchasePosts = f.calls.purchasePosts()
	out.ReviewStatus = 0
	_, out.ReviewCode, out.ReviewHasRetryAt = f.calls.review()
	out.GenerationAnalyses = int(f.vendor.analyses.Load())
	out.GenerationScores = int(f.vendor.scores.Load())
	return out, nil
}

func (f *t24Fixture) get(path string, out any) error {
	req := httptest.NewRequestWithContext(f.ctx, http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+f.token)
	rec := httptest.NewRecorder()
	f.s.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		return fmt.Errorf("GET %s status %d", path, rec.Code)
	}
	return json.Unmarshal(rec.Body.Bytes(), out)
}

func (f *t24Fixture) snapshot(stage string) (t24Snapshot, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	snapshot, ok := f.snapshots[stage]
	return snapshot, ok
}

func (f *t24Fixture) observation(stage string) (t24Observed, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	observed, ok := f.observed[stage]
	return observed, ok
}

// TestT24QuotaResetMemberPageJourney drives the real ReviewPage, its real 429
// response and the real MemberPage on one consented synthetic free account.
// Only the AI vendor is synthetic: the exhausted allowance is seeded before the
// page submits, so no generation is attempted or charged.
func TestT24QuotaResetMemberPageJourney(t *testing.T) {
	if os.Getenv("T24_DISPOSABLE") != "yes" {
		t.Fatal("T24_DISPOSABLE=yes is required; this journey only runs against disposable loopback stores")
	}
	if os.Getenv("T19_DISPOSABLE") != "yes" || os.Getenv("APP_ENV") != "development" {
		t.Fatal("requires disposable loopback PostgreSQL 17 and two Redis instances")
	}
	ports := map[string]string{}
	for _, name := range []string{"DATABASE_URL", "REDIS_URL", "LEDGER_URL"} {
		raw := os.Getenv(name)
		u, err := url.Parse(raw)
		if err != nil || u.Hostname() == "" {
			t.Fatalf("%s must be a loopback URL", name)
		}
		host := u.Hostname()
		if host != "127.0.0.1" && host != "::1" && host != "localhost" {
			t.Fatalf("%s must point at a loopback fixture", name)
		}
		ports[name] = u.Port()
	}
	if ports["REDIS_URL"] == "" || ports["REDIS_URL"] == ports["LEDGER_URL"] {
		t.Fatalf("cache and ledger must be two distinct Redis instances")
	}
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	appDir, err := filepath.Abs(filepath.Join("..", "..", "..", "app"))
	if err != nil {
		t.Fatal("could not resolve the app workspace")
	}
	for _, path := range []string{
		filepath.Join(appDir, t24FlutterTest),
		filepath.Join(appDir, ".dart_tool", "package_config.json"),
		flutter,
	} {
		if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("Flutter prerequisite missing: %s", path)
		}
	}

	ctx := t.Context()
	fake := &reviewUpstream{entered: make(chan struct{}), resume: make(chan struct{})}
	close(fake.resume)
	s := reviewRuntime(t, fake)
	router := s.Router()

	var postgres int
	if err := s.db.QueryRow(ctx, `select current_setting('server_version_num')::int / 10000`).Scan(&postgres); err != nil {
		t.Fatal(err)
	}
	if postgres != 17 {
		t.Fatalf("expected PostgreSQL 17, got %d", postgres)
	}

	request := func(method, path, token string, in any) reviewResponse {
		var body bytes.Buffer
		if in != nil {
			if err := json.NewEncoder(&body).Encode(in); err != nil {
				t.Fatal(err)
			}
		}
		r := httptest.NewRequestWithContext(ctx, method, "/v1/"+path, &body)
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		r.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return reviewResponse{w.Code, w.Body.Bytes()}
	}
	check := func(r reviewResponse, code int, out any) {
		t.Helper()
		if r.code != code {
			t.Fatalf("%d want %d: %s", r.code, code, r.body)
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

	// One synthetic free account, logged in once. The same session is handed to
	// the Flutter child; it does not log in again.
	loginTicket := uuid.NewString()
	must(s.cache.Set(ctx, "dev:ticket:apple:"+loginTicket, "synthetic-"+uuid.NewString(), time.Minute).Err())
	t.Cleanup(func() {
		_ = s.cache.Del(context.Background(), "dev:ticket:apple:"+loginTicket).Err()
	})
	var account app.Tokens
	check(request("POST", "auth/login", "", map[string]any{
		"credential":      map[string]string{"provider": "apple", "proof": loginTicket},
		"age_confirmed":   true,
		"privacy_version": "2026-11",
		"terms_version":   "2026-11",
	}), 200, &account)
	check(request("PATCH", "me", account.AccessToken, map[string]string{"timezone": t24AccountZone}), 200, nil)
	check(request("PUT", "me/consents/review", account.AccessToken, map[string]any{
		"version": "v1",
		"granted": true,
	}), 200, nil)

	// Precondition, stated explicitly: review is exactly full for the account's
	// local day. The other two allowances stay untouched. This is a fixture, so
	// the journey does not spend real attempts first.
	var day time.Time
	must(s.db.QueryRow(ctx, `select (now() at time zone timezone)::date from users where id=$1`, account.UserId).Scan(&day))
	var zone string
	must(s.db.QueryRow(ctx, `select timezone from users where id=$1`, account.UserId).Scan(&zone))
	if zone != t24AccountZone {
		t.Fatalf("account timezone = %q, want %q", zone, t24AccountZone)
	}
	accountLoc, e := time.LoadLocation(t24AccountZone)
	must(e)
	// The service day and reset are derived from the ACCOUNT zone only.
	accountDay := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, accountLoc)
	expectedAPIReset := accountDay.AddDate(0, 0, 1)
	_, e = s.db.Exec(ctx, `insert into daily_quota_usage(user_id,feature,charged_day,used) values($1,'review',$2::date,3)`, account.UserId, day)
	must(e)
	var used int
	must(s.db.QueryRow(ctx, `select coalesce(sum(used),0) from daily_quota_usage where user_id=$1 and feature='review'`, account.UserId).Scan(&used))
	if used != 3 {
		t.Fatalf("seeded review used = %d, want 3", used)
	}

	rights := func() app.Entitlements {
		t.Helper()
		var out app.Entitlements
		check(request("GET", "entitlements", account.AccessToken, nil), 200, &out)
		return out
	}
	remaining := func(out app.Entitlements, feature string) int {
		t.Helper()
		for _, allowance := range out.Allowances {
			if string(allowance.Feature) == feature && allowance.Remaining != nil {
				return *allowance.Remaining
			}
		}
		t.Fatalf("%s allowance missing", feature)
		return -1
	}
	initial := rights()
	if got := remaining(initial, "review"); got != 0 {
		t.Fatalf("initial review remaining = %d, want 0", got)
	}
	if got := remaining(initial, "practice"); got != 3 {
		t.Fatalf("initial practice remaining = %d, want 3", got)
	}
	if got := remaining(initial, "reply"); got != 3 {
		t.Fatalf("initial reply remaining = %d, want 3", got)
	}
	for _, allowance := range initial.Allowances {
		if allowance.ResetsAt.IsZero() {
			t.Fatalf("%s resets_at is missing", allowance.Feature)
		}
		// API reset is the account-day boundary, not a device-local guess.
		if !allowance.ResetsAt.Equal(expectedAPIReset) {
			t.Fatalf("%s resets_at = %s, want account-day boundary %s",
				allowance.Feature, allowance.ResetsAt.Format(time.RFC3339Nano),
				expectedAPIReset.Format(time.RFC3339Nano))
		}
	}
	if got := countRows(ctx, t, s, `select count(*) from review_requests where user_id=$1`, account.UserId); got != 0 {
		t.Fatalf("reviews before journey = %d", got)
	}

	calls := &t24Calls{counts: map[string]int{}}
	fixture := &t24Fixture{
		ctx: ctx, s: s, token: account.AccessToken, user: account.UserId,
		secret: uuid.NewString(), calls: calls, vendor: fake,
		snapshots: map[string]t24Snapshot{}, observed: map[string]t24Observed{},
	}
	wrapped := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == t24Checkpoint {
			fixture.checkpoint(w, r)
			return
		}
		if !strings.HasPrefix(r.URL.Path, "/v1/") {
			router.ServeHTTP(w, r)
			return
		}
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, r)
		calls.record(r.Method, r.URL.Path, rec.Code, rec.Body.Bytes())
		for key, values := range rec.Header() {
			w.Header()[key] = values
		}
		w.WriteHeader(rec.Code)
		_, _ = w.Write(rec.Body.Bytes())
	}))
	t.Cleanup(wrapped.Close)

	tokensJSON, err := json.Marshal(account)
	must(err)
	runCtx, cancel := context.WithTimeout(ctx, t24FlutterLimit)
	defer cancel()
	cmd := exec.CommandContext(runCtx, flutter, "--no-version-check", "test", "--no-pub", "--reporter", "expanded", t24FlutterTest)
	cmd.Dir = appDir
	cmd.WaitDelay = 5 * time.Second
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.Env = t24FlutterEnv(wrapped.URL, string(tokensJSON), fixture.secret)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	runErr := cmd.Run()
	t24LogFlutter(t, output.String())
	if runErr != nil {
		t.Logf("Flutter output:\n%s", output.String())
		var exitErr *exec.ExitError
		if runCtx.Err() != nil {
			t.Fatalf("Flutter quota/member journey terminated (%s, 阶段 %s)", runCtx.Err(), t24LastStage(output.String()))
		}
		if errors.As(runErr, &exitErr) {
			t.Fatalf("Flutter quota/member journey failed (exit=%d, 阶段 %s)", exitErr.ExitCode(), t24LastStage(output.String()))
		}
		t.Fatalf("could not run the Flutter quota/member journey (%s, 阶段 %s)", runErr, t24LastStage(output.String()))
	}
	if !strings.Contains(output.String(), "T24_STAGE complete") {
		t.Fatalf("Flutter journey exited without its completion receipt (阶段 %s)", t24LastStage(output.String()))
	}

	// The page showed the no-time copy because the service 429 carries no
	// retry_at; it did not invent midnight or a timezone.
	quotaShown, ok := fixture.observation("quota_shown")
	if !ok {
		t.Fatal("quota_shown checkpoint was never read back")
	}
	if quotaShown.ErrorText != "今日文字复盘剩余 0 次，请在额度重置后再试。" {
		t.Fatalf("quota copy = %q", quotaShown.ErrorText)
	}

	// Every checkpoint must show one rejected POST and no net usage change; the
	// other two allowances stay available, and only the review row is full.
	for _, stage := range []string{"quota_shown", "member_view", "returned"} {
		snapshot, ok := fixture.snapshot(stage)
		if !ok {
			t.Fatalf("%s checkpoint was never read back", stage)
		}
		if snapshot.ReviewRemaining != 0 || snapshot.PracticeRemaining != 3 || snapshot.ReplyRemaining != 3 {
			t.Fatalf("%s allowances = review:%d practice:%d reply:%d", stage,
				snapshot.ReviewRemaining, snapshot.PracticeRemaining, snapshot.ReplyRemaining)
		}
		if snapshot.ReviewUsed != 3 || snapshot.ReviewRequests != 0 || snapshot.ReviewActivities != 0 || snapshot.Ledger != 0 {
			t.Fatalf("%s net usage changed = used:%d requests:%d activities:%d ledger:%d", stage,
				snapshot.ReviewUsed, snapshot.ReviewRequests, snapshot.ReviewActivities, snapshot.Ledger)
		}
		if snapshot.ReviewsPosted != 1 || snapshot.PurchasePosts != 0 {
			t.Fatalf("%s posts = reviews:%d purchases:%d", stage, snapshot.ReviewsPosted, snapshot.PurchasePosts)
		}
		if snapshot.GenerationAnalyses != 0 || snapshot.GenerationScores != 0 {
			t.Fatalf("%s generation was called = analyses:%d scores:%d", stage,
				snapshot.GenerationAnalyses, snapshot.GenerationScores)
		}
		if snapshot.ReviewCode != "quota_exceeded" || snapshot.ReviewHasRetryAt {
			t.Fatalf("%s rejection = code:%q retry_at:%t", stage, snapshot.ReviewCode, snapshot.ReviewHasRetryAt)
		}
		if snapshot.ResetsAt == "" {
			t.Fatalf("%s resets_at is missing", stage)
		}
	}

	// The visible MemberPage row is the same /v1/entitlements resets_at instant
	// converted to the DEVICE zone (Shanghai), never the account's UTC wall
	// clock and never the device's own next midnight.
	member, ok := fixture.observation("member_view")
	if !ok {
		t.Fatal("member_view checkpoint was never read back")
	}
	memberSnapshot, ok := fixture.snapshot("member_view")
	if !ok {
		t.Fatal("member_view snapshot was never read back")
	}
	deviceLoc, err := time.LoadLocation(t24DeviceZone)
	must(err)
	reset, err := time.Parse(time.RFC3339Nano, memberSnapshot.ResetsAt)
	must(err)
	at := reset.In(deviceLoc)
	if at.Hour() == 0 && at.Minute() == 0 {
		t.Fatalf("device rendering is the device's own midnight: %s", member.ResetText)
	}
	expectedReset := fmt.Sprintf("今日限次已用尽。%d 月 %d 日 %d:%02d 重置（本地时间），也可选择会员。",
		at.Month(), at.Day(), at.Hour(), at.Minute())
	if member.ReviewTitle != "文字复盘 · 剩余 0 次" {
		t.Fatalf("review quota title = %q", member.ReviewTitle)
	}
	if member.ResetText != expectedReset {
		t.Fatalf("visible reset = %q, service resets_at (%s) in %s renders %q",
			member.ResetText, memberSnapshot.ResetsAt, t24DeviceZone, expectedReset)
	}
	if member.PracticeTitle != "对练 · 剩余 3 次" || member.ReplyTitle != "回复助手 · 剩余 3 次" {
		t.Fatalf("other allowances rendered = practice:%q reply:%q", member.PracticeTitle, member.ReplyTitle)
	}
	if member.ExhaustedRows != 1 {
		t.Fatalf("exhausted quota rows = %d, want only review", member.ExhaustedRows)
	}
	if member.LocalOffsetMin != 8*60 {
		t.Fatalf("Flutter test zone offset = %d minutes, want %s (+480)", member.LocalOffsetMin, t24DeviceZone)
	}
	t.Logf("visible_reset=%q account_zone=%s device_zone=%s resets_at=%s device=%02d:%02d",
		member.ResetText, t24AccountZone, t24DeviceZone, memberSnapshot.ResetsAt, at.Hour(), at.Minute())

	final, err := fixture.readback("final")
	must(err)
	if final.ReviewsPosted != 1 || final.PurchasePosts != 0 ||
		final.ReviewUsed != 3 || final.ReviewRequests != 0 || final.ReviewActivities != 0 || final.Ledger != 0 ||
		final.GenerationAnalyses != 0 || final.GenerationScores != 0 ||
		final.ReviewCode != "quota_exceeded" || final.ReviewHasRetryAt {
		t.Fatalf("final readback = %+v", final)
	}
	t.Logf("stage=complete review_posts=%d remaining=%d used=%d requests=%d ledger=%d",
		final.ReviewsPosted, final.ReviewRemaining, final.ReviewUsed, final.ReviewRequests, final.Ledger)
}

func countRows(ctx context.Context, t *testing.T, s *Runtime, query string, args ...any) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow(ctx, query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func t24LogFlutter(t *testing.T, output string) {
	t.Helper()
	for line := range strings.SplitSeq(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "T24_STAGE ") || strings.HasPrefix(line, "All tests passed!") ||
			strings.HasPrefix(line, "Some tests failed.") {
			t.Log(line)
		}
	}
}

func t24LastStage(output string) string {
	last := "unreported"
	for line := range strings.SplitSeq(output, "\n") {
		if strings.HasPrefix(line, "T24_STAGE ") {
			last = strings.TrimSpace(strings.TrimPrefix(line, "T24_STAGE "))
		}
	}
	return last
}

func t24FlutterEnv(origin, tokens, fixture string) []string {
	var env []string
	for _, key := range []string{
		"PATH", "HOME", "TMPDIR", "TMP", "TEMP", "PUB_CACHE", "FLUTTER_ROOT",
		"FLUTTER_ALREADY_LOCKED", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
		"GIT_OPTIONAL_LOCKS", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
		"XDG_STATE_HOME", "XDG_RUNTIME_DIR", "CI", "FLUTTER_SUPPRESS_ANALYTICS",
		"DART_SUPPRESS_ANALYTICS", "LANG", "LC_ALL",
	} {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}
	return append(env,
		"T24_ORIGIN="+origin,
		"T24_TOKENS="+tokens,
		"T24_FIXTURE="+fixture,
		"TZ="+t24DeviceZone,
	)
}
