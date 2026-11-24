//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/training"
)

type growthHistoryFixture struct {
	h                    *practiceWire
	a                    app.Tokens
	subject, contact     uuid.UUID
	single, full, legacy uuid.UUID
	fullScore            uuid.UUID
	before, after        float64
}

func TestT27HistoryJourney(t *testing.T) {
	if os.Getenv("T27_HISTORY_DISPOSABLE") != "yes" {
		t.Skip("use python3 app/tool/t27/history_journey.py with disposable local services")
	}
	phase := func(name string, timeout time.Duration, action func(context.Context)) {
		t.Helper()
		t.Logf("BEGIN(%s)", name)
		passed := false
		defer func() {
			if !passed {
				t.Logf("FAIL(%s)", name)
			}
		}()
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		action(ctx)
		if ctx.Err() != nil {
			t.Fatal(ctx.Err())
		}
		passed = true
		t.Logf("PASS(%s)", name)
	}

	var f growthHistoryFixture
	phase("service.runtime", 40*time.Second, func(ctx context.Context) {
		f.h = newPracticeWireWithContext(t, ctx)
		f.h.must(f.h.s.Health(ctx))
	})
	phase("service.seed", 70*time.Second, func(ctx context.Context) {
		f.h.ctx = ctx
		f.seed()
	})
	phase("service.order-and-cursor", 25*time.Second, func(ctx context.Context) {
		f.h.ctx = ctx
		f.checkWireHistory()
	})
	phase("service.reference-before", 15*time.Second, func(ctx context.Context) {
		f.h.ctx = ctx
		got := f.reference()
		if got.WleisPercent == nil || got.LatestAssessment == nil {
			t.Fatal("expected seeded assessment in the growth response")
		}
		// Emotion level 3 contributes 15 points. The NVC scores 100 and
		// 60 contribute 70 and 42. Single-skill progress contributes zero.
		f.before = (float64(*got.WleisPercent) + 71) / 2
		f.after = (float64(*got.WleisPercent) + 57) / 2
		f.checkReference(got, 2, f.before)
	})
	summaryPath := "contacts/" + f.contact.String() + "/summary"
	phase("service.contact-summary-before", 15*time.Second, func(ctx context.Context) {
		f.h.ctx = ctx
		var got app.Profile
		f.h.json(f.a.AccessToken, http.MethodGet, summaryPath, nil, http.StatusOK, &got)
		if got.Summary == "" || len(got.BigFive) != 5 || got.ConflictStyle.Label == "" {
			t.Fatal("expected a valid contact profile before deletion")
		}
	})
	t.Log("BEGIN(page.runner)")
	pageCtx, cancelPage := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancelPage()
	f.h.ctx = pageCtx
	deleted, pageErr := f.runFlutter(pageCtx)
	if pageErr != nil {
		t.Errorf("FAIL(page.runner): %v", pageErr)
	} else {
		t.Log("PASS(page.runner)")
	}
	// Even if a later UI phase fails, verify an acknowledged deletion in PG.
	if deleted {
		phase("service.delete-cascade", 20*time.Second, func(ctx context.Context) {
			f.h.ctx = ctx
			f.checkCascade()
		})
		phase("service.contact-summary-after", 15*time.Second, func(ctx context.Context) {
			f.checkDeletedContactSummary(ctx, summaryPath)
		})
	} else {
		t.Log("NOT RUN(service.delete-cascade): no confirmed DELETE")
		t.Log("NOT RUN(service.contact-summary-after): no confirmed DELETE")
	}
	if !t.Failed() {
		t.Log("PASS(journey)")
	}

}

func (f *growthHistoryFixture) ticket(subject uuid.UUID) string {
	key := uuid.NewString()
	f.h.must(f.h.s.cache.Set(f.h.ctx, "dev:ticket:apple:"+key, subject.String(), 6*time.Minute).Err())
	return key
}

func (f *growthHistoryFixture) seed() {
	h := f.h
	f.subject = uuid.New()
	h.json("", "POST", "auth/login", map[string]any{
		"credential":    map[string]string{"provider": "apple", "proof": f.ticket(f.subject)},
		"age_confirmed": true, "terms_version": accounts.PolicyVersion, "privacy_version": accounts.PolicyVersion,
	}, 200, &f.a)
	token := f.a.AccessToken
	// Both formal assessment startup and contacts require the current
	// notice version. A generic "v1" grant passes HTTP but blocks the UI.
	for _, purpose := range []string{"practice", "contacts", "assessment"} {
		h.json(token, "PUT", "me/consents/"+purpose, map[string]any{
			"version": accounts.PolicyVersion, "granted": true,
		}, 200, nil)
	}
	var bank app.GetInstrumentResult
	h.json(token, "GET", "assessments/instrument", nil, 200, &bank)
	h.json(token, "POST", "assessments", app.SubmitAssessmentInput{
		Version: bank.Version,
		Answers: []int{1, 1, 1, 1, 7, 7, 7, 7, 5, 6, 5, 6, 1, 1, 1, 2},
	}, 200, nil)

	var contact app.Contact
	h.json(token, "POST", "contacts", map[string]any{"nickname": "合成关系人", "scene": "work"}, 200, &contact)
	f.contact = contact.Id
	create := func(level string, contact *uuid.UUID) uuid.UUID {
		id := uuid.New()
		in := map[string]any{"request_id": id, "level_id": level}
		if contact != nil {
			in["contact_id"] = *contact
		}
		var row training.SessionSummary
		h.json(token, "POST", "sessions", in, 200, &row)
		if row.ID != id {
			h.t.Fatal("session creation did not retain its request ID")
		}
		return id
	}
	const singleLevel = "19000000-0000-4000-8000-000000000001"
	const fullLevel = "19000000-0000-4000-8000-000000000005"
	f.single = create(singleLevel, nil)
	for range 98 {
		create(singleLevel, nil)
	}
	f.full = create(fullLevel, &f.contact)
	f.legacy = create(fullLevel, nil)

	finish := func(id uuid.UUID, label string) training.Result {
		path := "sessions/" + id.String()
		h.framesWithMessage(f.a, path, map[string]string{
			"client_message_id": uuid.NewString(), "text": label,
		}, "fragment", "fragment", "reply_saved")
		var out training.Result
		h.json(token, "POST", path+"/finish", nil, 200, &out)
		return out
	}
	h.set("first_score")
	if v := finish(f.legacy, "合成历史整场"); v.Score == nil || v.Score.NVC.Total != 60 || v.Progress != nil {
		h.t.Fatal("legacy full score must equal 60/100")
	}
	// Model a real legacy record whose score survived without a completion time.
	h.exec("update practice_work set completed_at=null where activity_id=$1", f.legacy)
	h.set("")
	if v := finish(f.full, "合成较晚创建整场"); v.Score == nil || v.Score.NVC.Total != 100 || v.Progress != nil {
		h.t.Fatal("linked full score must equal 100/100")
	}
	if v := finish(f.single, "合成较早创建单项"); v.Progress == nil || v.Progress.Score != 15 || v.Score != nil {
		h.t.Fatal("finished drill must contain only the 15/25 target progress")
	}
	h.must(h.s.db.QueryRow(h.ctx, "select id from scores where activity_id=$1", f.full).Scan(&f.fullScore))
}

func (f *growthHistoryFixture) checkWireHistory() {
	h := f.h
	token := f.a.AccessToken
	singlePath := "sessions/" + f.single.String()
	single := h.history(f.a, singlePath)
	full := h.history(f.a, "sessions/"+f.full.String())
	if single.CompletedAt == nil || full.CompletedAt == nil || !single.CompletedAt.After(*full.CompletedAt) {
		h.t.Fatal("earliest-created drill must have completed after the linked full session")
	}
	h.json(token, "POST", singlePath+"/finish", nil, 200, nil)
	replay := h.history(f.a, singlePath)
	if replay.CompletedAt == nil || !replay.CompletedAt.Equal(*single.CompletedAt) {
		h.t.Fatal("idempotent finish changed completed_at")
	}

	var first struct {
		Items []struct {
			ID          uuid.UUID       `json:"session_id"`
			CompletedAt json.RawMessage `json:"completed_at"`
		} `json:"items"`
		Next *string `json:"next_cursor"`
	}
	h.json(token, "GET", "sessions?limit=100", nil, 200, &first)
	if len(first.Items) != 100 || first.Next == nil || *first.Next != first.Items[99].ID.String() ||
		first.Items[0].ID != f.legacy || !bytes.Equal(first.Items[0].CompletedAt, []byte("null")) ||
		first.Items[1].ID != f.full {
		h.t.Fatal("first page must be in creation order with the explicit legacy null and a real cursor")
	}
	var last training.Page
	h.json(token, "GET", "sessions?limit=100&cursor="+url.QueryEscape(*first.Next), nil, 200, &last)
	if len(last.Items) != 1 || last.Next != nil || last.Items[0].ID != f.single ||
		last.Items[0].CompletedAt == nil || !last.Items[0].CompletedAt.Equal(*single.CompletedAt) {
		h.t.Fatal("terminal page must hold the earliest-created, most recently completed drill")
	}
}

func (f *growthHistoryFixture) reference() (got app.GetGrowthResult) {
	f.h.json(f.a.AccessToken, "GET", "growth", nil, 200, &got)
	return got
}

func (f *growthHistoryFixture) checkReference(got app.GetGrowthResult, count int, want float64) {
	f.h.t.Helper()
	if got.ValidBehaviorCount != count || got.TrainingReference == nil ||
		math.Abs(float64(*got.TrainingReference)-want) > 0.001 {
		value := "null"
		if got.TrainingReference != nil {
			value = fmt.Sprintf("%.3f", *got.TrainingReference)
		}
		f.h.t.Fatalf("growth reference must be %.3f over %d surviving behaviors (got count %d, reference %s)",
			want, count, got.ValidBehaviorCount, value)
	}
}

func (f *growthHistoryFixture) runFlutter(ctx context.Context) (deleted bool, err error) {
	h := f.h
	// The outage is a real HTTP 503 on listSessions only. All other
	// requests, including deletion and growth, use the production router.
	pageAPI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/v1/sessions" && r.Header.Get("X-T27-History-Outage") == "1" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			io.WriteString(w, `{"code":"service_unavailable","message":"synthetic history outage","retryable":true}`)
			return
		}
		h.api.Config.Handler.ServeHTTP(w, r)
	}))
	h.t.Cleanup(pageAPI.Close)
	cmd := exec.CommandContext(ctx, os.Getenv("T27_HISTORY_DART"), os.Getenv("T27_HISTORY_FLUTTER_SNAPSHOT"),
		"--no-version-check", "test", "--no-pub", "--reporter", "expanded", "tool/t27/history_journey_test.dart")
	cmd.Dir = os.Getenv("T27_HISTORY_APP")
	cmd.WaitDelay = 3 * time.Second
	// The launcher already provides an allowlisted environment. DB and
	// vendor configuration stay in the Go process.
	for _, key := range []string{
		"PATH", "LANG", "LC_ALL", "HOME", "TMPDIR", "PUB_CACHE", "FLUTTER_ROOT",
		"CI", "FLUTTER_SUPPRESS_ANALYTICS", "DART_SUPPRESS_ANALYTICS",
		"XDG_CACHE_HOME", "XDG_CONFIG_HOME", "FLUTTER_STORAGE_BASE_URL", "PUB_HOSTED_URL",
	} {
		if value, present := os.LookupEnv(key); present {
			cmd.Env = append(cmd.Env, key+"="+value)
		}
	}
	cmd.Env = append(cmd.Env,
		"T27_HISTORY_ORIGIN="+pageAPI.URL,
		"T27_HISTORY_TICKET_A="+f.ticket(f.subject),
		"T27_HISTORY_TICKET_B="+f.ticket(uuid.New()),
		"T27_HISTORY_ACCOUNT_A="+f.a.UserId.String(),
		"T27_HISTORY_SINGLE="+f.single.String(),
		"T27_HISTORY_FULL="+f.full.String(),
		"T27_HISTORY_CONTACT="+f.contact.String(),
		"T27_HISTORY_LEGACY="+f.legacy.String(),
		"T27_HISTORY_REFERENCE_BEFORE="+strconv.FormatInt(int64(math.Round(f.before)), 10),
		"T27_HISTORY_REFERENCE_AFTER="+strconv.FormatInt(int64(math.Round(f.after)), 10),
	)
	var output bytes.Buffer
	sink := io.MultiWriter(os.Stdout, &output)
	cmd.Stdout, cmd.Stderr = sink, sink
	err = cmd.Run()
	receipts := output.String()
	deleted = strings.Contains(receipts, "OBSERVED(page.delete-ack)")
	if err != nil {
		if !strings.Contains(receipts, "BEGIN(page.fixture)") {
			h.t.Log("NOT RUN(page.startup): Flutter did not enter the widget test")
		}
		if ctx.Err() != nil {
			return deleted, ctx.Err()
		}
		return deleted, err
	}
	if !deleted || !strings.Contains(receipts, "PASS(page.journey)") {
		return deleted, fmt.Errorf("Flutter omitted the deletion acknowledgment or final journey receipt")
	}
	return deleted, nil

}

func (f *growthHistoryFixture) checkCascade() {
	h := f.h
	token := f.a.AccessToken
	h.json(token, "GET", "sessions/"+f.full.String(), nil, http.StatusNotFound, nil)
	h.json(token, "GET", "sessions/"+f.single.String(), nil, http.StatusOK, nil)
	h.json(token, "GET", "sessions/"+f.legacy.String(), nil, http.StatusOK, nil)
	if n := h.number(`select
		(select count(*) from contacts where id=$1) +
		(select count(*) from activities where id=$2) +
		(select count(*) from practice_work where activity_id=$2) +
		(select count(*) from practice_messages where activity_id=$2) +
		(select count(*) from scores where id=$3) +
		(select count(*) from growth_scores where score_id=$3)`, f.contact, f.full, f.fullScore); n != 0 {
		h.t.Fatalf("contact and linked session, messages and score projections still have %d database rows", n)
	}
	if n := h.number("select count(*) from activities where user_id=$1 and id in ($2,$3) and state='complete'",
		f.a.UserId, f.single, f.legacy); n != 2 {
		h.t.Fatalf("expected both unaffected completed activities in PostgreSQL, got %d", n)
	}
	f.checkReference(f.reference(), 1, f.after)
}

func (f *growthHistoryFixture) checkDeletedContactSummary(ctx context.Context, path string) {
	h := f.h
	h.t.Helper()
	for _, tc := range []struct {
		name, token string
		status      int
		code        string
	}{
		{"owner", f.a.AccessToken, http.StatusNotFound, "contact_not_found"},
		{"anonymous", "", http.StatusUnauthorized, "unauthenticated"},
		{"invalid token", "invalid-fixture-token", http.StatusUnauthorized, "unauthenticated"},
	} {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, h.api.URL+"/v1/"+path, nil)
		h.must(err)
		if tc.token != "" {
			req.Header.Set("Authorization", "Bearer "+tc.token)
		}
		resp, err := h.api.Client().Do(req)
		h.must(err)
		var got app.Error
		err = json.NewDecoder(resp.Body).Decode(&got)
		resp.Body.Close()
		if err != nil || resp.StatusCode != tc.status || got.Code != tc.code {
			h.t.Fatalf("GET %s (%s): got status %d, code %q, decode error %v; want status %d and code %q",
				path, tc.name, resp.StatusCode, got.Code, err, tc.status, tc.code)
		}
	}
}
