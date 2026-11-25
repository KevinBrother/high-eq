//go:build integration && t15dashboard

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
)

// T15 acceptance, real page: one synthetic App user completes one normal
// review. Its generation attempt and T26 numeric projection are the source row
// this check selects; the gateway's moderation attempts keep task='scoring'
// but use the moderation model and a NULL prompt version. A synthetic operator
// then drives the shipped /metrics page over real loopback HTTP, selects task,
// model and prompt version, and presses "查询调用". The Go parent compares
// every value the page rendered for that group with SQL over the page's own
// [from,until) window plus the three selected keys, and with the decrypted
// growth projection. No provider, browser, account or real credential, and no
// fabricated metrics response.
//
// The integration && t15dashboard tag keeps this out of ordinary runs. A
// missing prerequisite fails; it never turns into a skipped "green".
func TestT15DashboardRealPage(t *testing.T) {
	if os.Getenv("T15_DISPOSABLE") != "yes" {
		t.Fatal("T15_DISPOSABLE=yes is required for disposable loopback stores")
	}
	ctx := t.Context()
	s := reviewRuntimeWithVendor(t, t15ProjectionVendor(t), nil)

	// Record the real /metrics request the page sends so the assertions can
	// prove the task/model/version selections reached the production handler.
	var queryMu sync.Mutex
	var lastQuery string
	router := s.Router()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/admin/v1/metrics" {
			queryMu.Lock()
			lastQuery = r.URL.RawQuery
			queryMu.Unlock()
		}
		router.ServeHTTP(w, r)
	}))
	defer server.Close()

	// Derive the checkout from this source file instead of taking a machine
	// path or a caller-supplied card root.
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the T15 test source")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(source), "..", "..", ".."))
	adminDir := filepath.Join(repoRoot, "admin")
	pageTest := filepath.Join("tool", "t15", "dashboard_live_test.dart")
	for _, name := range []string{pageTest, ".dart_tool/package_config.json"} {
		if info, err := os.Stat(filepath.Join(adminDir, name)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("T15 Flutter /metrics page prerequisite missing: admin/%s", filepath.ToSlash(name))
		}
	}

	client := server.Client()
	request := func(method, path, token string, in, out any, want int) {
		t.Helper()
		var body *bytes.Reader
		if in == nil {
			body = bytes.NewReader(nil)
		} else {
			data, err := json.Marshal(in)
			if err != nil {
				t.Fatal("encode request")
			}
			body = bytes.NewReader(data)
		}
		r, err := http.NewRequestWithContext(ctx, method, server.URL+path, body)
		if err != nil {
			t.Fatal("build request")
		}
		if in != nil {
			r.Header.Set("Content-Type", "application/json")
		}
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(r)
		if err != nil {
			t.Fatalf("%s %s: request failed", method, path)
		}
		defer resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("%s %s: status %d, want %d", method, path, resp.StatusCode, want)
		}
		if out != nil {
			dec := json.NewDecoder(resp.Body)
			if err := dec.Decode(out); err != nil {
				t.Fatalf("%s %s: decode response", method, path)
			}
		}
	}

	// One synthetic App user submits one complete review. The real handlers
	// write the analysis, the scoring attempt and, through the T26 subscriber,
	// the sealed numeric projection.
	ticket := uuid.NewString()
	if err := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); err != nil {
		t.Fatal("could not seed the synthetic login ticket")
	}
	var user app.Tokens
	request("POST", "/v1/auth/login", "", map[string]any{
		"credential":    map[string]string{"provider": "apple", "proof": ticket},
		"age_confirmed": true, "terms_version": "2026-11", "privacy_version": "2026-11",
	}, &user, 200)
	request("PUT", "/v1/me/consents/review", user.AccessToken, map[string]any{
		"version": "v1", "granted": true,
	}, nil, 200)
	scene := app.ReviewInputSceneWork
	var review app.Review
	request("POST", "/v1/reviews", user.AccessToken, app.ReviewInput{
		RequestId: uuid.New(), Scene: &scene,
		Happened: "T15-DASHBOARD-SYNTHETIC", MyFeeling: "着急",
		TheirPossibleFeeling: "也许没说完", MyAction: "我先说完", NextAction: "等对方说完",
	}, &review, 200)
	if review.Score.ScoreId == uuid.Nil {
		t.Fatal("synthetic review did not return a score")
	}

	// Persisted source row for the group the page will select. Moderation calls
	// keep task='scoring' but use the moderation model and a NULL prompt version,
	// so the page's model and version filters exclude them; they are not seeded
	// scoring attempts.
	var modelID uuid.UUID
	var versionID *uuid.UUID
	var latency int64
	var rawCost *string
	if err := s.db.QueryRow(ctx, `select model_id,prompt_version_id,coalesce(latency_ms,0)::bigint,cost_cny::text
		from ai_calls where score_id=$1 and task='scoring'`, review.Score.ScoreId).
		Scan(&modelID, &versionID, &latency, &rawCost); err != nil {
		t.Fatal("could not read the scoring attempt source row")
	}
	if versionID == nil {
		t.Fatal("scoring attempt was recorded without a prompt version")
	}

	// The distribution source is the sealed projection, not the response body.
	var sealed []byte
	if err := s.db.QueryRow(ctx, `select nvc_enc from growth_scores where score_id=$1`, review.Score.ScoreId).Scan(&sealed); err != nil {
		t.Fatal("the T26 numeric projection is missing")
	}
	plain, err := s.Fields.Open(sealed, []byte("growth_scores.nvc_enc/"+review.Score.ScoreId.String()))
	if err != nil {
		t.Fatal("could not open the numeric projection")
	}
	var projected struct {
		Total *int `json:"total"`
	}
	if err := json.Unmarshal(plain, &projected); err != nil || projected.Total == nil {
		t.Fatal("numeric projection has no integer total")
	}
	// A synthetic operator signs in through the real admin handler.
	login := uuid.NewString()
	const password = "fixture-password-only"
	if _, err := adminops.Provision(ctx, s.db, login, password, "operator"); err != nil {
		t.Fatal("could not provision the synthetic operator")
	}
	var session admin.AdminSession
	request("POST", "/admin/v1/auth/login", "", admin.AdminLoginJSONBody{
		Login: login, Password: password,
	}, &session, 200)
	if session.AccessToken == "" {
		t.Fatal("operator session not issued")
	}

	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	runCtx, cancel := context.WithTimeout(ctx, 6*time.Minute)
	defer cancel()
	receipt := filepath.Join(t.TempDir(), "dashboard-receipt.json")
	cmd := exec.CommandContext(runCtx, flutter, "test", "--no-pub", "-r", "expanded", pageTest)
	cmd.Dir = adminDir
	cmd.Env = append(os.Environ(),
		"T15_ADMIN_ORIGIN="+server.URL,
		"T15_ADMIN_TOKEN="+session.AccessToken,
		"T15_MODEL_ID="+modelID.String(),
		"T15_VERSION_ID="+versionID.String(),
		"T15_RECEIPT="+receipt,
	)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Run(); err != nil {
		t.Fatalf("T15 Flutter /metrics page stopped the flow (exit=%v): %s",
			err, t15DashboardRedact(output.String(), session.AccessToken, server.URL))
	}

	queryMu.Lock()
	sent := lastQuery
	queryMu.Unlock()
	filters, err := url.ParseQuery(sent)
	if err != nil {
		t.Fatal("the page sent an unreadable /metrics query")
	}
	for key, want := range map[string]string{
		"task":              "scoring",
		"model_id":          modelID.String(),
		"prompt_version_id": versionID.String(),
		"limit":             "20",
	} {
		if got := filters.Get(key); got != want {
			t.Fatalf("/metrics page selected %s=%q, want %q", key, got, want)
		}
	}
	from, err := time.Parse(time.RFC3339Nano, filters.Get("from"))
	if err != nil {
		t.Fatal("/metrics page sent an unreadable from bound")
	}
	until, err := time.Parse(time.RFC3339Nano, filters.Get("until"))
	if err != nil || !until.After(from) {
		t.Fatal("/metrics page sent an unreadable or empty time range")
	}
	var visible bool
	if err := s.db.QueryRow(ctx, `select exists(select from ai_calls where score_id=$1 and task='scoring'
		and started_at>=$2 and started_at<$3)`, review.Score.ScoreId, from, until).Scan(&visible); err != nil || !visible {
		t.Fatal("the synthetic scoring attempt is outside the page's requested range")
	}

	// Independently recompute the displayed group over the page's own
	// [from,until) window plus the three selected keys. Moderation attempts keep
	// task='scoring' but use another model and a NULL version, so they are
	// outside this filter.
	var calls, failures, unpriced, distinctScores, missing int
	var mean float64
	var knownCost string
	if err := s.db.QueryRow(ctx, `select count(*),count(*) filter(where outcome<>'ok'),
		count(*) filter(where cost_cny is null),coalesce(avg(latency_ms),0)::float8,
		coalesce(sum(cost_cny),0)::text
		from ai_calls where started_at>=$1 and started_at<$2 and task='scoring'
		and model_id=$3 and prompt_version_id=$4`,
		from, until, modelID, *versionID).
		Scan(&calls, &failures, &unpriced, &mean, &knownCost); err != nil {
		t.Fatal("could not aggregate the selected window")
	}
	if calls != 1 || failures != 0 {
		t.Fatalf("expected exactly one successful scoring attempt in the selected window, got calls=%d failures=%d",
			calls, failures)
	}
	if rawCost == nil && unpriced != 1 || rawCost != nil && unpriced != 0 {
		t.Fatalf("unpriced count %d disagrees with the persisted cost", unpriced)
	}
	if err := s.db.QueryRow(ctx, `select count(distinct s.score_id),count(distinct s.score_id) filter(where g.score_id is null)
		from (select distinct score_id from ai_calls where started_at>=$1 and started_at<$2
		 and task='scoring' and model_id=$3 and prompt_version_id=$4
		 and outcome='ok' and score_id is not null) s
		left join growth_scores g using(score_id)`, from, until, modelID, *versionID).
		Scan(&distinctScores, &missing); err != nil {
		t.Fatal("could not verify the score projection coverage")
	}
	if distinctScores != 1 || missing != 0 {
		t.Fatalf("expected one projected score and no missing projection, got distinct=%d missing=%d",
			distinctScores, missing)
	}

	var shown struct {
		Identity string   `json:"identity"`
		Calls    string   `json:"calls"`
		Mean     string   `json:"mean"`
		Failures string   `json:"failures"`
		Cost     string   `json:"cost"`
		Bins     []string `json:"bins"`
		Counts   []string `json:"counts"`
		Missing  string   `json:"missing"`
	}
	raw, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatal("T15 Flutter /metrics page finished without a receipt")
	}
	if err := json.Unmarshal(raw, &shown); err != nil {
		t.Fatal("T15 Flutter /metrics receipt is not readable")
	}

	known, err := strconv.ParseFloat(knownCost, 64)
	if err != nil {
		t.Fatal("persisted cost total is not numeric")
	}
	expected := map[string]string{
		"identity": fmt.Sprintf("模型 %s\n模板 %s", modelID, *versionID),
		"calls":    fmt.Sprintf("调用 %d 次", calls),
		"mean":     fmt.Sprintf("平均 %.1f ms", mean),
		"failures": fmt.Sprintf("失败 %d 次 · %.1f%%", failures, 100*float64(failures)/float64(calls)),
		"cost":     fmt.Sprintf("已知成本 ¥%.8f  ·  未知成本 %d 次", known, unpriced),
	}
	actual := map[string]string{
		"identity": shown.Identity,
		"calls":    shown.Calls,
		"mean":     shown.Mean,
		"failures": shown.Failures,
		"cost":     shown.Cost,
	}
	for _, key := range []string{"identity", "calls", "mean", "failures", "cost"} {
		if actual[key] != expected[key] {
			t.Fatalf("/metrics row %s rendered %q, want %q", key, actual[key], expected[key])
		}
	}
	wantBin := fmt.Sprintf("%d 分", *projected.Total)
	if len(shown.Bins) != 1 || shown.Bins[0] != wantBin {
		t.Fatalf("/metrics score bins rendered %v, want exactly %q", shown.Bins, wantBin)
	}
	wantCount := fmt.Sprintf("%d 份", distinctScores)
	if len(shown.Counts) != 1 || shown.Counts[0] != wantCount {
		t.Fatalf("/metrics score counts rendered %v, want exactly %q", shown.Counts, wantCount)
	}
	if shown.Missing != "" {
		t.Fatalf("/metrics rendered a missing-projection note %q for complete data", shown.Missing)
	}
	// The rendered latency is the source row's own value even though the query
	// aggregated it; the synthetic group has exactly one attempt.
	if mean != float64(latency) {
		t.Fatalf("aggregate latency %v differs from the source row %d ms", mean, latency)
	}
	t.Logf("T15 /metrics real page: calls=%d mean=%.1fms failures=%d cost=%s unpriced=%d bin=%s count=%s missing=%d",
		calls, mean, failures, knownCost, unpriced, wantBin, wantCount, missing)
}

// t15DashboardRedact keeps a bounded diagnostic tail without the session token
// or the loopback origin.
func t15DashboardRedact(output, token, origin string) string {
	output = strings.ReplaceAll(output, token, "[redacted]")
	output = strings.ReplaceAll(output, origin, "[redacted]")
	if len(output) > 4000 {
		output = output[len(output)-4000:]
	}
	return output
}
