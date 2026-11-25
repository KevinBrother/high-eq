//go:build integration && t32ajourney

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
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

const (
	t32aCheckpoint   = "/__t32a/checkpoint"
	t32aFlutterTest  = "tool/t32a/mark_review_journey_test.dart"
	t32aFlutterLimit = 6 * time.Minute
)

// t32aSnapshot is a readback taken by the same running service while the real
// Flutter page journey is in progress. It is deliberately a fixture-only view:
// the product routes remain the only way marks and reviews are created.
type t32aSnapshot struct {
	Stage              string `json:"stage"`
	Marks              int    `json:"marks"`
	Scene              string `json:"scene"`
	Reviews            int    `json:"reviews"`
	ReviewMarkMatches  int    `json:"review_mark_matches"`
	ReviewsWithSignal  int    `json:"reviews_with_signal"`
	Scored             int    `json:"scored"`
	Remaining          int    `json:"remaining"`
	Used               int    `json:"used"`
	Ledger             int    `json:"ledger"`
	ReadbackReview     bool   `json:"readback_review"`
	SubmittedMarkMatch bool   `json:"submitted_mark_match"`
	SubmittedScene     string `json:"submitted_scene"`
	SubmittedTimeMatch bool   `json:"submitted_time_match"`
}

type t32aFixture struct {
	ctx    context.Context
	s      *Runtime
	token  string
	user   uuid.UUID
	secret string

	mu        sync.Mutex
	snapshots map[string]t32aSnapshot
}

func newT32aFixture(ctx context.Context, s *Runtime, token string, user uuid.UUID, secret string) *t32aFixture {
	return &t32aFixture{
		ctx: ctx, s: s, token: token, user: user, secret: secret,
		snapshots: map[string]t32aSnapshot{},
	}
}

func (f *t32aFixture) checkpoint(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.Header.Get("X-T32A-Fixture") != f.secret {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var in struct {
		Stage string `json:"stage"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	switch in.Stage {
	case "mark_scene", "draft_reopened", "submitted", "returned_mark":
	default:
		http.Error(w, "unknown stage", http.StatusBadRequest)
		return
	}
	snapshot, err := f.readback(in.Stage)
	if err != nil {
		http.Error(w, "readback failed", http.StatusInternalServerError)
		return
	}
	f.mu.Lock()
	f.snapshots[in.Stage] = snapshot
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(snapshot)
}

func (f *t32aFixture) readback(stage string) (t32aSnapshot, error) {
	out := t32aSnapshot{Stage: stage}
	var marks app.ListMarksResult
	if err := f.get("/v1/marks", &marks); err != nil {
		return out, err
	}
	out.Marks = len(marks.Items)
	if len(marks.Items) == 1 && marks.Items[0].Scene != nil {
		out.Scene = *marks.Items[0].Scene
	}
	var rights app.Entitlements
	if err := f.get("/v1/entitlements", &rights); err != nil {
		return out, err
	}
	for _, allowance := range rights.Allowances {
		if string(allowance.Feature) == "review" && allowance.Remaining != nil {
			out.Remaining = *allowance.Remaining
		}
	}
	if err := f.s.db.QueryRow(f.ctx, `select coalesce(sum(used),0) from daily_quota_usage where user_id=$1 and feature='review'`, f.user).Scan(&out.Used); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from quota_ledger q join activities a on a.id=q.activity_id where a.user_id=$1 and a.kind='review'`, f.user).Scan(&out.Ledger); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from review_requests where user_id=$1`, f.user).Scan(&out.Reviews); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from review_requests r join manual_marks m on m.id=r.mark_id and m.user_id=$1 where r.user_id=$1`, f.user).Scan(&out.ReviewMarkMatches); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from review_requests where user_id=$1 and signal_event_id is not null`, f.user).Scan(&out.ReviewsWithSignal); err != nil {
		return out, err
	}
	if err := f.s.db.QueryRow(f.ctx, `select count(*) from scores s join activities a on a.id=s.activity_id where a.user_id=$1 and a.kind='review'`, f.user).Scan(&out.Scored); err != nil {
		return out, err
	}
	if out.Reviews == 1 && out.Marks >= 1 {
		var id uuid.UUID
		if err := f.s.db.QueryRow(f.ctx, `select a.id from review_requests r join activities a on a.id=r.activity_id where r.user_id=$1`, f.user).Scan(&id); err != nil {
			return out, err
		}
		var review app.Review
		if err := f.get("/v1/reviews/"+id.String(), &review); err != nil {
			return out, err
		}
		out.ReadbackReview = true
		if review.Submitted.MarkId != nil {
			for _, mark := range marks.Items {
				if mark.Id != *review.Submitted.MarkId {
					continue
				}
				out.SubmittedMarkMatch = true
				out.SubmittedTimeMatch = review.Submitted.OccurredAt != nil && review.Submitted.OccurredAt.Equal(mark.MarkedAt)
				if mark.Scene != nil {
					out.Scene = *mark.Scene
				}
			}
		}
		if review.Submitted.Scene != nil {
			out.SubmittedScene = string(*review.Submitted.Scene)
		}
	}
	return out, nil
}

func (f *t32aFixture) get(path string, out any) error {
	req := httptest.NewRequestWithContext(f.ctx, http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+f.token)
	rec := httptest.NewRecorder()
	f.s.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		return fmt.Errorf("GET %s status %d", path, rec.Code)
	}
	return json.Unmarshal(rec.Body.Bytes(), out)
}

func (f *t32aFixture) snapshot(stage string) (t32aSnapshot, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	snapshot, ok := f.snapshots[stage]
	return snapshot, ok
}

// TestT32AMarkReviewJourney is one cross-process journey on one synthetic free
// account and one session: the real loopback HTTP service is running, the only
// Flutter child process drives the real marks editor, the real /marks/review
// route and the real ReviewPage, and that same session's product HTTP routes
// record the mark, the draft-backed review and the single debit. The Flutter
// child is not a mock transport and does not submit from Go.
func TestT32AMarkReviewJourney(t *testing.T) {
	if os.Getenv("T32A_DISPOSABLE") != "yes" {
		t.Fatal("T32A_DISPOSABLE=yes is required; this journey only runs against disposable loopback stores")
	}
	if os.Getenv("T19_DISPOSABLE") != "yes" || os.Getenv("APP_ENV") != "development" {
		t.Fatal("requires disposable loopback PostgreSQL 17 and two Redis instances")
	}
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
		filepath.Join(appDir, t32aFlutterTest),
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
	count := func(query string, args ...any) int {
		t.Helper()
		var n int
		must(s.db.QueryRow(ctx, query, args...).Scan(&n))
		return n
	}

	// One synthetic free account, logged in once. The same token and session are
	// handed to the Flutter process; it does not log in again.
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
	for _, purpose := range []string{"review", "manual_mark", "contacts"} {
		check(request("PUT", "me/consents/"+purpose, account.AccessToken, map[string]any{
			"version": "v1",
			"granted": true,
		}), 200, nil)
	}

	// Precondition, stated explicitly: one review left today. Seed the already
	// used counter; no tier, clock or policy change.
	var day time.Time
	must(s.db.QueryRow(ctx, `select (now() at time zone timezone)::date from users where id=$1`, account.UserId).Scan(&day))
	_, e := s.db.Exec(ctx, `insert into daily_quota_usage(user_id,feature,charged_day,used) values($1,'review',$2::date,2)`, account.UserId, day)
	must(e)
	remaining := func() int {
		t.Helper()
		var rights app.Entitlements
		check(request("GET", "entitlements", account.AccessToken, nil), 200, &rights)
		for _, allowance := range rights.Allowances {
			if string(allowance.Feature) == "review" && allowance.Remaining != nil {
				return *allowance.Remaining
			}
		}
		t.Fatal("review allowance missing")
		return -1
	}
	if got := remaining(); got != 1 {
		t.Fatalf("initial review remaining = %d, want 1", got)
	}
	if got := count(`select coalesce(sum(used),0) from daily_quota_usage where user_id=$1 and feature='review'`, account.UserId); got != 2 {
		t.Fatalf("initial review used = %d, want 2", got)
	}
	if got := count(`select count(*) from review_requests where user_id=$1`, account.UserId); got != 0 {
		t.Fatalf("reviews before journey = %d", got)
	}
	if got := count(`select count(*) from manual_marks where user_id=$1`, account.UserId); got != 0 {
		t.Fatalf("marks before journey = %d", got)
	}

	fixture := newT32aFixture(ctx, s, account.AccessToken, account.UserId, uuid.NewString())
	var callsMu sync.Mutex
	calls := map[string]int{}
	wrapped := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == t32aCheckpoint {
			fixture.checkpoint(w, r)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/v1/") {
			callsMu.Lock()
			calls[r.Method+" "+r.URL.Path]++
			callsMu.Unlock()
		}
		router.ServeHTTP(w, r)
	}))
	t.Cleanup(wrapped.Close)

	tokensJSON, err := json.Marshal(account)
	must(err)
	runCtx, cancel := context.WithTimeout(ctx, t32aFlutterLimit)
	defer cancel()
	cmd := exec.CommandContext(runCtx, flutter, "--no-version-check", "test", "--no-pub", "--reporter", "expanded", t32aFlutterTest)
	cmd.Dir = appDir
	cmd.WaitDelay = 5 * time.Second
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.Env = t32aFlutterEnv(wrapped.URL, string(tokensJSON), fixture.secret)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	runErr := cmd.Run()
	logFlutterReceipts(t, output.String())
	if runErr != nil {
		t.Logf("Flutter output:\n%s", output.String())
		var exitErr *exec.ExitError
		if runCtx.Err() != nil {
			t.Fatalf("Flutter mark/review journey terminated (%s, 阶段 %s)", runCtx.Err(), t32aLastStage(output.String()))
		}
		if errors.As(runErr, &exitErr) {
			t.Fatalf("Flutter mark/review journey failed (exit=%d, 阶段 %s)", exitErr.ExitCode(), t32aLastStage(output.String()))
		}
		t.Fatalf("could not run the Flutter mark/review journey (%s, 阶段 %s)", runErr, t32aLastStage(output.String()))
	}
	if !strings.Contains(output.String(), "T32A_STAGE complete") {
		t.Fatalf("Flutter journey exited without its completion receipt (阶段 %s)", t32aLastStage(output.String()))
	}

	// The page-created mark, draft-backed review and single debit must be visible
	// from the same running service, through the same session.
	afterMark, ok := fixture.snapshot("mark_scene")
	if !ok {
		t.Fatal("mark_scene checkpoint was never read back")
	}
	if afterMark.Marks != 1 || afterMark.Scene != "work" || afterMark.Reviews != 0 ||
		afterMark.Remaining != 1 || afterMark.Used != 2 || afterMark.Ledger != 0 {
		t.Fatalf("after mark/scene readback = %+v", afterMark)
	}
	afterDraft, ok := fixture.snapshot("draft_reopened")
	if !ok {
		t.Fatal("draft_reopened checkpoint was never read back")
	}
	if afterDraft.Marks != 1 || afterDraft.Reviews != 0 || afterDraft.Remaining != 1 ||
		afterDraft.Used != 2 || afterDraft.Ledger != 0 {
		t.Fatalf("after draft reopen readback = %+v", afterDraft)
	}
	afterSubmit, ok := fixture.snapshot("submitted")
	if !ok {
		t.Fatal("submitted checkpoint was never read back")
	}
	if afterSubmit.Marks != 1 || afterSubmit.Reviews != 1 || afterSubmit.ReviewMarkMatches != 1 ||
		afterSubmit.ReviewsWithSignal != 0 || afterSubmit.Scored != 1 ||
		afterSubmit.Remaining != 0 || afterSubmit.Used != 3 || afterSubmit.Ledger != 1 ||
		!afterSubmit.ReadbackReview || !afterSubmit.SubmittedMarkMatch ||
		afterSubmit.SubmittedScene != "work" || !afterSubmit.SubmittedTimeMatch {
		t.Fatalf("after submit readback = %+v", afterSubmit)
	}

	backOnMarks, ok := fixture.snapshot("returned_mark")
	if !ok {
		t.Fatal("returned_mark checkpoint was never read back")
	}
	if backOnMarks.Marks < 1 || backOnMarks.Scene != "work" || backOnMarks.Reviews != 1 ||
		backOnMarks.ReviewMarkMatches != 1 || backOnMarks.Scored != 1 ||
		backOnMarks.Remaining != 0 || backOnMarks.Used != 3 || backOnMarks.Ledger != 1 ||
		!backOnMarks.ReadbackReview || !backOnMarks.SubmittedMarkMatch ||
		backOnMarks.SubmittedScene != "work" || !backOnMarks.SubmittedTimeMatch {
		t.Fatalf("after return to marks readback = %+v", backOnMarks)
	}

	final, err := fixture.readback("final")
	must(err)
	if final.Marks < 1 || final.Scene != "work" || final.Reviews != 1 ||
		final.ReviewMarkMatches != 1 || final.ReviewsWithSignal != 0 || final.Scored != 1 ||
		final.Remaining != 0 || final.Used != 3 || final.Ledger != 1 ||
		!final.ReadbackReview || !final.SubmittedMarkMatch || final.SubmittedScene != "work" ||
		!final.SubmittedTimeMatch {
		t.Fatalf("final readback = %+v", final)
	}
	if fake.analyses.Load() != 1 || fake.scores.Load() != 1 {
		t.Fatalf("generation attempts analyses=%d scores=%d, want one each", fake.analyses.Load(), fake.scores.Load())
	}

	// Only page-triggered product writes may appear, and exactly once each.
	callsMu.Lock()
	defer callsMu.Unlock()
	var markPatches int
	for key, n := range calls {
		if strings.HasPrefix(key, "PATCH /v1/marks/") {
			markPatches += n
		}
	}
	if calls["POST /v1/marks"] != 2 || markPatches != 1 || calls["POST /v1/reviews"] != 1 {
		keys := make([]string, 0, len(calls))
		for key := range calls {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		t.Fatalf("product write calls = %v; want two mark clicks, one scene patch and one review", calls)
	}
	if got := count(`select count(*) from signal_events where user_id=$1`, account.UserId); got != 0 {
		t.Fatalf("sensor events touched = %d", got)
	}
	if got := count(`select count(*) from manual_marks where user_id=$1`, account.UserId); got < 1 {
		t.Fatalf("marks after journey = %d, want at least the original", got)
	}
	t.Logf("stage=complete marks=%d reviews=%d remaining=%d used=%d ledger=%d", final.Marks, final.Reviews, final.Remaining, final.Used, final.Ledger)
}

func logFlutterReceipts(t *testing.T, output string) {
	t.Helper()
	for line := range strings.SplitSeq(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "T32A_STAGE ") || strings.HasPrefix(line, "All tests passed!") ||
			strings.HasPrefix(line, "Some tests failed.") {
			t.Log(line)
		}
	}
}

func t32aLastStage(output string) string {
	last := "unreported"
	for line := range strings.SplitSeq(output, "\n") {
		if strings.HasPrefix(line, "T32A_STAGE ") {
			last = strings.TrimSpace(strings.TrimPrefix(line, "T32A_STAGE "))
		}
	}
	return last
}

func t32aFlutterEnv(origin, tokens, fixture string) []string {
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
		"T32A_ORIGIN="+origin,
		"T32A_TOKENS="+tokens,
		"T32A_FIXTURE="+fixture,
	)
}
