//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

type growthRequest func(method, path, token string, in any, want int, out any)

func newGrowthRequest(t *testing.T, router http.Handler) growthRequest {
	return func(method, path, token string, in any, want int, out any) {
		t.Helper()
		body, err := json.Marshal(in)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("%s %s: got %d, want %d: %s", method, path, rec.Code, want, rec.Body.String())
		}
		if out != nil {
			if err := json.Unmarshal(rec.Body.Bytes(), out); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func growthAppleProof(t *testing.T, s *Runtime, subject string) map[string]string {
	t.Helper()
	ticket := uuid.NewString()
	if err := s.cache.Set(t.Context(), "dev:ticket:apple:"+ticket, subject, time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	return map[string]string{"provider": "apple", "proof": ticket}
}

func TestGrowthRoutesRejectFrozenAccountWithoutGeneratingPlan(t *testing.T) {
	ctx := context.Background()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if s != nil {
			s.Close()
		}
	}()

	call := newGrowthRequest(t, s.Router())
	proof := func(subject string) map[string]string { return growthAppleProof(t, s, subject) }

	subject := uuid.NewString()
	var tokens app.Tokens
	call("POST", "auth/login", "", map[string]any{
		"credential":      proof(subject),
		"age_confirmed":   true,
		"privacy_version": "2026-11",
		"terms_version":   "2026-11",
	}, 200, &tokens)
	call("PUT", "me/consents/assessment", tokens.AccessToken, map[string]any{"version": "v1", "granted": true}, 200, nil)

	var bank app.GetInstrumentResult
	call("GET", "assessments/instrument", tokens.AccessToken, nil, 200, &bank)
	call("POST", "assessments", tokens.AccessToken, app.SubmitAssessmentInput{
		Version: bank.Version,
		Answers: []int{1, 1, 1, 1, 7, 7, 7, 7, 5, 6, 5, 6, 1, 1, 1, 2},
	}, 200, nil)

	planCount := func() int {
		t.Helper()
		var n int
		if err := s.db.QueryRow(ctx, `select count(*) from daily_plans where user_id=$1`, tokens.UserId).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := planCount(); n != 1 {
		t.Fatalf("plans after assessment=%d", n)
	}
	// If the frozen GET is incorrectly allowed through, Today will recreate this
	// missing plan from the surviving assessment.
	if _, err := s.db.Exec(ctx, `delete from daily_plans where user_id=$1`, tokens.UserId); err != nil {
		t.Fatal(err)
	}
	call("POST", "me/closure", tokens.AccessToken, map[string]any{"proof": proof(subject)}, 200, nil)
	if n := planCount(); n != 0 {
		t.Fatalf("plans before frozen growth reads=%d", n)
	}

	itemID, contentID := uuid.NewString(), uuid.NewString()
	for _, route := range []struct {
		method string
		path   string
		body   any
	}{
		{"GET", "plans/today", nil},
		{"POST", "plans/items/" + itemID + "/complete", nil},
		{"GET", "exercises/" + contentID, nil},
		{"POST", "exercises/" + contentID + "/answers", map[string]any{"choice_index": 0}},
		{"GET", "cards", nil},
		{"GET", "cards/" + contentID, nil},
		{"GET", "growth", nil},
	} {
		call(route.method, route.path, tokens.AccessToken, route.body, 401, nil)
	}
	if n := planCount(); n != 0 {
		t.Fatalf("frozen growth read generated plans=%d", n)
	}

	// A pending assessment for one frozen account must not prevent the process
	// from starting. Its outbox stays pending for the minute worker, while the
	// account can still read /v1/me and cannot reach growth routes.
	if _, err := s.db.Exec(ctx, `update assessments set completion_pending=true where user_id=$1`, tokens.UserId); err != nil {
		t.Fatal(err)
	}
	s.Close()
	s = nil
	s, err = Start(ctx, cfg)
	if err != nil {
		t.Fatalf("restart with frozen pending assessment: %v", err)
	}
	call = newGrowthRequest(t, s.Router())
	var pending bool
	if err := s.db.QueryRow(ctx, `select completion_pending from assessments where user_id=$1`, tokens.UserId).Scan(&pending); err != nil || !pending {
		t.Fatalf("pending assessment was not retained: pending=%v err=%v", pending, err)
	}
	var fresh app.Tokens
	call("POST", "auth/login", "", map[string]any{
		"credential":      proof(subject),
		"age_confirmed":   true,
		"privacy_version": "2026-11",
		"terms_version":   "2026-11",
	}, 200, &fresh)
	call("GET", "me", fresh.AccessToken, nil, 200, nil)
	call("GET", "plans/today", fresh.AccessToken, nil, 401, nil)
	call("GET", "growth", fresh.AccessToken, nil, 401, nil)

	var other app.Tokens
	call("POST", "auth/login", "", map[string]any{
		"credential":      proof(uuid.NewString()),
		"age_confirmed":   true,
		"privacy_version": "2026-11",
		"terms_version":   "2026-11",
	}, 200, &other)
	call("GET", "me", other.AccessToken, nil, 200, nil)
	call("GET", "plans/today", other.AccessToken, nil, 200, nil)
}

// This test uses the production composition. The order is a synthetic local
// entitlement, but grants, contact selection, assessment and plan reads all
// go through the same routes as the app. No provider is contacted.
func TestGrowthProfilePlanComposition(t *testing.T) {
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s, err := Start(t.Context(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	for _, tc := range []struct {
		name                string
		paid, revoked, want bool
	}{{"free with chosen contact", false, false, false}, {"member with chosen contact", true, false, true}, {"member after contacts withdrawal", true, true, false}} {
		t.Run(tc.name, func(t *testing.T) {
			call := newGrowthRequest(t, s.Router())
			var a app.Tokens
			call("POST", "auth/login", "", map[string]any{"credential": growthAppleProof(t, s, uuid.NewString()), "age_confirmed": true, "terms_version": "2026-11", "privacy_version": "2026-11"}, 200, &a)
			if tc.paid {
				_, err := s.db.Exec(t.Context(), `with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '1 day',now()+interval '1 day' from o`, a.UserId, []byte(uuid.NewString()))
				if err != nil {
					t.Fatal(err)
				}
			}
			consent := func(purpose string, on bool) {
				call("PUT", "me/consents/"+purpose, a.AccessToken, map[string]any{"version": "v1", "granted": on}, 200, nil)
			}
			consent("contacts", true)
			var c app.Contact
			call("POST", "contacts", a.AccessToken, map[string]string{"nickname": "合成称呼", "scene": "friends"}, 200, &c)
			call("POST", "contacts/"+c.Id.String()+"/activate", a.AccessToken, nil, 200, nil)
			if tc.revoked {
				consent("contacts", false)
			}
			consent("assessment", true)
			var bank app.GetInstrumentResult
			call("GET", "assessments/instrument", a.AccessToken, nil, 200, &bank)
			answers := make([]int, len(bank.Items))
			for i := range answers {
				answers[i] = 4
			}
			call("POST", "assessments", a.AccessToken, app.SubmitAssessmentInput{Version: bank.Version, Answers: answers}, 200, nil)
			var count int
			if err := s.db.QueryRow(t.Context(), `select count(*) from daily_plans where user_id=$1`, a.UserId).Scan(&count); err != nil || count != 1 {
				t.Fatalf("event did not create one plan: %d %v", count, err)
			}
			var plan app.GetTodayPlanResult
			call("GET", "plans/today", a.AccessToken, nil, 200, &plan)
			if plan.Personalized != tc.want || len(plan.Items) == 0 {
				t.Fatalf("unexpected plan personalization=%v, count=%d", plan.Personalized, len(plan.Items))
			}
			if tc.want {
				var levels app.ListLevelsResult
				call("GET", "levels?scene=friends&limit=100", a.AccessToken, nil, 200, &levels)
				matches := 0
				for _, l := range levels.Items {
					if l.Mode != "full_session" {
						continue
					}
					for _, i := range plan.Items {
						if i.Kind == app.PlanItemKindLevel && i.ContentId == l.Id {
							matches++
						}
					}
				}
				if matches != 1 {
					t.Fatalf("plan must include one real full-session level from the authorized scene; matches=%d", matches)
				}
			}
		})
	}
}
