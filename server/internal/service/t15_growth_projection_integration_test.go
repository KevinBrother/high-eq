//go:build integration

package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
)

// TestT15ActualGrowthProjection proves the T26 write side against T15's read
// side. One synthetic App user submits one complete review (full_review mode,
// scoring only the reported my_action). The review save commits the activity,
// source score and call link first; the service then attempts ScoreCompleted in
// a second transaction, whose T26 subscriber writes the encrypted numeric
// projection. No projection row, metrics response or bucket is fabricated here:
// every value below is read through the real HTTP handlers or compared with an
// independent SQL count over the same window. CI logs carry no IDs or bodies.
func TestT15ActualGrowthProjection(t *testing.T) {
	ctx := t.Context()
	s := reviewRuntimeWithVendor(t, t15ProjectionVendor(t), nil)
	router := s.Router()

	do := func(method, path, token string, in any) (int, []byte) {
		t.Helper()
		b, _ := json.Marshal(in)
		r := httptest.NewRequest(method, path, bytes.NewReader(b))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w.Code, w.Body.Bytes()
	}
	// Never print the query string on failure: it carries synthetic filter IDs.
	route := func(path string) string {
		if i := strings.IndexByte(path, '?'); i >= 0 {
			return path[:i]
		}
		return path
	}
	ok := func(method, path, token string, in any, out any) {
		t.Helper()
		code, body := do(method, path, token, in)
		if code != 200 {
			t.Fatalf("%s %s: status %d", method, route(path), code)
		}
		if out != nil {
			if err := json.Unmarshal(body, out); err != nil {
				t.Fatalf("%s %s: decode response", method, route(path))
			}
		}
	}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	// Required fields are checked against their raw JSON so a missing key or an
	// explicit null can never masquerade as the numeric zero value.
	required := func(fields map[string]json.RawMessage, key string) json.RawMessage {
		t.Helper()
		raw, exists := fields[key]
		if !exists {
			t.Fatalf("response is missing required field %q", key)
		}
		return raw
	}
	intField := func(fields map[string]json.RawMessage, key string) int {
		t.Helper()
		var value *int
		if err := json.Unmarshal(required(fields, key), &value); err != nil || value == nil {
			t.Fatalf("response field %q is not an integer", key)
		}
		return *value
	}
	numberField := func(fields map[string]json.RawMessage, key string) float64 {
		t.Helper()
		var value *float64
		if err := json.Unmarshal(required(fields, key), &value); err != nil || value == nil {
			t.Fatalf("response field %q is not a number", key)
		}
		return *value
	}
	stringField := func(fields map[string]json.RawMessage, key string) string {
		t.Helper()
		var value *string
		if err := json.Unmarshal(required(fields, key), &value); err != nil || value == nil {
			t.Fatalf("response field %q is not a string", key)
		}
		return *value
	}

	ticket := uuid.NewString()
	must(s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err())
	var user app.Tokens
	ok("POST", "/v1/auth/login", "", map[string]any{
		"credential": map[string]string{"provider": "apple", "proof": ticket},
		"age_confirmed": true, "terms_version": "2026-11", "privacy_version": "2026-11",
	}, &user)
	ok("PUT", "/v1/me/consents/review", user.AccessToken, map[string]any{"version": "v1", "granted": true}, nil)

	scene := app.ReviewInputSceneWork
	input := app.ReviewInput{
		RequestId: uuid.New(), Scene: &scene,
		Happened: "T15-SYNTHETIC-MEETING", MyFeeling: "着急",
		TheirPossibleFeeling: "也许没说完", MyAction: "我先说完", NextAction: "等对方说完",
	}
	const wantTotal = 20
	var review app.Review
	ok("POST", "/v1/reviews", user.AccessToken, input, &review)
	if review.Score.ScoreId == uuid.Nil || review.Score.Nvc.Total != wantTotal {
		t.Fatal("synthetic review did not return the expected score")
	}

	// Two phases: the save committed first, then delivery ran. After a normal 200
	// the outbox is acknowledged and the T26 subscriber has written exactly one row.
	var pending bool
	must(s.db.QueryRow(ctx, `select score_pending from review_requests where activity_id=$1`, review.Id).Scan(&pending))
	if pending {
		t.Fatal("score delivery left the review request pending")
	}
	var rows int
	must(s.db.QueryRow(ctx, `select count(*) from growth_scores where score_id=$1`, review.Score.ScoreId).Scan(&rows))
	if rows != 1 {
		t.Fatalf("expected one growth projection row, got %d", rows)
	}
	var kind string
	var sealed []byte
	must(s.db.QueryRow(ctx, `select kind,nvc_enc from growth_scores where score_id=$1`, review.Score.ScoreId).Scan(&kind, &sealed))
	if kind != "review" || len(sealed) == 0 {
		t.Fatal("growth projection was not written by the real score event")
	}
	if bytes.Contains(sealed, []byte(`"total"`)) || bytes.Contains(sealed, []byte("T15-SYNTHETIC")) {
		t.Fatal("growth_scores.nvc_enc is not sealed")
	}
	plain, err := s.Fields.Open(sealed, []byte("growth_scores.nvc_enc/"+review.Score.ScoreId.String()))
	must(err)
	var projected struct {
		Total int `json:"total"`
	}
	must(json.Unmarshal(plain, &projected))
	if projected.Total != wantTotal {
		t.Fatalf("projected total %d differs from the synthetic %d", projected.Total, wantTotal)
	}

	var modelID uuid.UUID
	var versionID *uuid.UUID
	var startedAt time.Time
	var callTask, outcome string
	must(s.db.QueryRow(ctx, `select model_id,prompt_version_id,started_at,task::text,outcome from ai_calls where score_id=$1 and task='scoring'`,
		review.Score.ScoreId).Scan(&modelID, &versionID, &startedAt, &callTask, &outcome))
	if versionID == nil || callTask != "scoring" || outcome != "ok" {
		t.Fatal("scoring attempt was not recorded against a prompt version")
	}
	var published uuid.UUID
	must(s.db.QueryRow(ctx, `select primary_version_id from prompt_releases where task='scoring' and model_id=$1`, modelID).Scan(&published))
	if published != *versionID {
		t.Fatal("recorded prompt version differs from the released primary version")
	}

	// One window for both reads: whole-second bounds, the same time.Time values
	// for SQL and the HTTP query. No endpoint-inclusion claim beyond this sample.
	from := startedAt.Truncate(time.Second)
	until := from.Add(time.Second)
	var calls, distinct, failures, unpriced int
	must(s.db.QueryRow(ctx, `select count(*),count(distinct score_id),
  count(*) filter(where outcome<>'ok'),count(*) filter(where cost_cny is null) from ai_calls
where started_at>=$1 and started_at<$2 and task='scoring' and model_id=$3
  and prompt_version_id is not distinct from $4`,
		from, until, modelID, *versionID).Scan(&calls, &distinct, &failures, &unpriced))
	if calls != 1 || distinct != 1 || failures != 0 {
		t.Fatalf("expected one successful synthetic scoring call, got calls=%d distinct=%d failures=%d", calls, distinct, failures)
	}

	login := uuid.NewString()
	const password = "fixture-password-only"
	_, err = adminops.Provision(ctx, s.db, login, password, "operator")
	must(err)
	var session admin.AdminSession
	ok("POST", "/admin/v1/auth/login", "", admin.AdminLoginJSONBody{Login: login, Password: password}, &session)
	if session.AccessToken == "" {
		t.Fatal("operator session not issued")
	}

	q := url.Values{
		"from":              {from.Format(time.RFC3339)},
		"until":             {until.Format(time.RFC3339)},
		"task":              {"scoring"},
		"model_id":          {modelID.String()},
		"prompt_version_id": {versionID.String()},
	}
	var page struct {
		Items      []map[string]json.RawMessage `json:"items"`
		NextCursor json.RawMessage              `json:"next_cursor"`
	}
	ok("GET", "/admin/v1/metrics?"+q.Encode(), session.AccessToken, nil, &page)
	if len(page.Items) != 1 {
		t.Fatalf("expected exactly one dashboard group, got %d", len(page.Items))
	}
	if string(bytes.TrimSpace(page.NextCursor)) != "null" {
		t.Fatal("expected next_cursor to be present and JSON null")
	}
	got := page.Items[0]
	if stringField(got, "task") != "scoring" {
		t.Fatal("dashboard group task does not match the recorded call")
	}
	if stringField(got, "model_id") != modelID.String() || stringField(got, "prompt_version_id") != versionID.String() {
		t.Fatal("dashboard group model or version does not match the recorded call")
	}
	httpCalls := intField(got, "calls")
	httpFailures := intField(got, "failures")
	httpRate := numberField(got, "failure_rate")
	httpUnpriced := intField(got, "unpriced_calls")
	httpMissing := intField(got, "missing_score_values")
	httpLatency := numberField(got, "mean_latency_ms")
	if httpCalls != calls || httpFailures != failures || httpUnpriced != unpriced {
		t.Fatalf("dashboard counts disagree with SQL: calls=%d failures=%d unpriced=%d, want calls=%d failures=%d unpriced=%d",
			httpCalls, httpFailures, httpUnpriced, calls, failures, unpriced)
	}
	if httpFailures != 0 || httpRate != 0 {
		t.Fatalf("dashboard failure fields are not explicitly zero: failures=%d rate=%v", httpFailures, httpRate)
	}
	if httpMissing != 0 {
		t.Fatalf("missing_score_values is %d, want an explicit 0", httpMissing)
	}
	if httpLatency < 0 {
		t.Fatalf("negative mean latency %v", httpLatency)
	}
	var distribution []struct {
		NvcTotal *int `json:"nvc_total"`
		Count    *int `json:"count"`
	}
	if err := json.Unmarshal(required(got, "score_distribution"), &distribution); err != nil {
		t.Fatal("score_distribution is not an array")
	}
	if len(distribution) != 1 || distribution[0].NvcTotal == nil || distribution[0].Count == nil ||
		*distribution[0].NvcTotal != wantTotal || *distribution[0].Count != 1 {
		t.Fatalf("score_distribution does not contain exactly one %d-point score", wantTotal)
	}

	// T26 read port for the same account: the count comes from the projection
	// written above, not from an aggregate table.
	var growth map[string]json.RawMessage
	ok("GET", "/v1/growth", user.AccessToken, nil, &growth)
	if count := intField(growth, "valid_behavior_count"); count != 1 {
		t.Fatalf("growth readback count is %d, want 1", count)
	}
	reference, exists := growth["training_reference"]
	if !exists {
		t.Fatal("growth response is missing training_reference")
	}
	if string(bytes.TrimSpace(reference)) != "null" {
		t.Fatal("training_reference is not JSON null without an assessment")
	}
}

func t15ProjectionVendor(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var v struct {
			Stream   bool
			Messages []gateway.Message
		}
		if json.NewDecoder(r.Body).Decode(&v) != nil || len(v.Messages) < 2 {
			http.Error(w, "fixture mismatch", 400)
			return
		}
		if !v.Stream {
			fmt.Fprintf(w, `{"choices":[{"message":{"content":%q},"finish_reason":"stop"}]}`, `{"verdict":"allow"}`)
			return
		}
		out := repairFixture
		if strings.Contains(v.Messages[0].Content, "full_review") {
			out = reviewScore
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", out)
	})
}
