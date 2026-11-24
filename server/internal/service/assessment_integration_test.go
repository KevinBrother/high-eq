//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/events"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/privacy"
)

// Generated HTTP routes + real account lock, independent deletion ledger, subscriber
// rollback, and ZIP hooks. Uses synthetic, disposable accounts in runtime.sh only.
func TestAssessmentLifecycle(t *testing.T) {
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
	router := s.Router()
	type response struct {
		code int
		body []byte
	}
	request := func(method, path, token string, in any) response {
		b, _ := json.Marshal(in)
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return response{w.Code, w.Body.Bytes()}
	}
	check := func(r response, code int, out any) {
		t.Helper()
		if r.code != code {
			t.Fatalf("unexpected status %d (want %d): %s", r.code, code, r.body)
		}
		if out != nil {
			if e := json.Unmarshal(r.body, out); e != nil {
				t.Fatal(e)
			}
		}
	}
	signup := func() app.Tokens {
		t.Helper()
		ticket := uuid.NewString()
		if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); e != nil {
			t.Fatal(e)
		}
		var tok app.Tokens
		check(request("POST", "auth/login", "", map[string]any{"credential": map[string]string{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"}), 200, &tok)
		return tok
	}
	a, b := signup(), signup()
	base := "assessments"
	token := a.AccessToken
	var bank app.GetInstrumentResult
	check(request("GET", base+"/instrument", "", nil), 401, nil)
	check(request("GET", base+"/instrument", token, nil), 200, &bank)
	if len(bank.Items) != 16 || len(bank.Options) != 7 {
		t.Fatal("instrument")
	}
	answers := []int{1, 1, 1, 1, 7, 7, 7, 7, 5, 6, 5, 6, 1, 1, 1, 2}
	sheet := app.SubmitAssessmentInput{Version: bank.Version, Answers: answers}
	post := func() response { return request("POST", base, token, sheet) }
	consent := func(grant bool) {
		check(request("PUT", "me/consents/assessment", token, map[string]any{"version": "v1", "granted": grant}), 200, nil)
	}
	check(post(), 403, nil)
	consent(true)
	for _, bad := range []app.SubmitAssessmentInput{{Version: "obsolete", Answers: answers}, {Version: bank.Version, Answers: answers[:15]}} {
		check(request("POST", base, token, bad), 400, nil)
	}
	var ready bool
	delivered := []events.Assessment{}
	s.Bus.AssessmentCompleted.Subscribe(func(ctx context.Context, tx pgx.Tx, v events.Assessment) error {
		if !ready {
			return errors.New("fixture: subscriber unavailable")
		}
		r, e := s.Assessments.ReadResult(ctx, tx, v.UserID, v.AssessmentID)
		if e != nil {
			return e
		}
		if r.Total.Mean != 3.6875 {
			return errors.New("wrong canonical score")
		}
		delivered = append(delivered, v)
		return nil
	})
	// Wait for both responses before changing the subscriber state.
	ch := make(chan response, 2)
	go func() { ch <- post() }()
	go func() { ch <- post() }()
	one, two := <-ch, <-ch
	if one.code != 200 {
		one, two = two, one
	}
	var first assessment.Result
	var conflict app.Error
	check(one, 200, &first)
	check(two, 409, &conflict)
	if conflict.RetryAt == nil || !conflict.RetryAt.Equal(first.NextEligibleAt) || first.NextEligibleAt.Sub(first.CompletedAt) != 672*time.Hour {
		t.Fatal("retest deadline mismatch")
	}
	var count int
	var encA, encS []byte
	var pending bool
	if e = s.db.QueryRow(ctx, `select answers_enc,scores_enc,completion_pending from assessments where id=$1`, first.ID).Scan(&encA, &encS, &pending); e != nil || !pending || json.Valid(encA) || json.Valid(encS) {
		t.Fatal("unexpected stored source", e)
	}
	if e = s.db.QueryRow(ctx, `select count(*) from assessments where user_id=$1`, a.UserId).Scan(&count); e != nil || count != 1 {
		t.Fatal("racing submits", e)
	}
	ready = true
	for range 2 {
		if e = s.Assessments.ReplayPending(ctx); e != nil {
			t.Fatal(e)
		}
	}
	if len(delivered) != 1 || delivered[0].AssessmentID != first.ID || delivered[0].UserID != a.UserId || !delivered[0].OccurredAt.Equal(first.CompletedAt) {
		t.Fatal("did not replay original completion exactly once in sequential drains")
	}
	var today app.GetTodayPlanResult
	check(request("GET", "plans/today", token, nil), 200, &today)
	if _, e = s.db.Exec(ctx, `update assessments set completed_at=clock_timestamp()-interval '672 hours' where id=$1`, first.ID); e != nil {
		t.Fatal(e)
	}
	consent(false)
	check(post(), 403, nil)
	consent(true)
	var second assessment.Result
	check(post(), 200, &second)
	if len(delivered) != 2 || delivered[1].AssessmentID != second.ID {
		t.Fatal("immediate delivery")
	}
	history := func(tok, path string) assessment.Page {
		t.Helper()
		var p assessment.Page
		check(request("GET", base+path, tok, nil), 200, &p)
		return p
	}
	p := history(token, "?limit=1")
	if len(p.Items) != 1 || p.Items[0].ID != second.ID || p.Next == nil {
		t.Fatal("first page")
	}
	p = history(token, "?limit=1&cursor="+*p.Next)
	if len(p.Items) != 1 || p.Items[0].ID != first.ID || p.Next != nil {
		t.Fatal("second page")
	}
	if len(history(b.AccessToken, "").Items) != 0 {
		t.Fatal("cross-account history")
	}
	check(request("GET", base+"?limit=0", token, nil), 400, nil)
	check(request("GET", base+"?cursor=bad", token, nil), 400, nil)
	type exported struct {
		assessment.Result
		Version string `json:"version"`
		Answers []int  `json:"answers"`
	}
	export := func(bearer string) []exported {
		t.Helper()
		body := t35Part(t, t35Download(t, router, bearer), "assessments")
		t35Exclude(t, body, `"answers_enc":`, `"scores_enc":`, `"completion_pending":`)
		var result []exported
		t35Decode(t, body, &result)
		return result
	}
	check(request("PUT", "me/consents/assessment", b.AccessToken, map[string]any{"version": "v1", "granted": true}), 200, nil)
	var foreign assessment.Result
	check(request("POST", base, b.AccessToken, sheet), 200, &foreign)
	all := export(a.AccessToken)
	other := export(b.AccessToken)
	if len(all) != 2 || all[0].ID != first.ID || all[1].ID != second.ID ||
		all[0].Version != bank.Version || !reflect.DeepEqual(all[0].Answers, answers) ||
		!reflect.DeepEqual(all[0].Scores, first.Scores) || !all[1].CompletedAt.Equal(second.CompletedAt) ||
		len(other) != 1 || other[0].ID != foreign.ID {
		t.Fatal("incomplete or cross-owner export")
	}
	body := t35Part(t, t35Download(t, router, token), "growth")
	t35Exclude(t, body, foreign.ID.String(), `"review_activity_id":`, `"plan_enc":`)
	var plans []growth.PlanExportRecord
	t35Decode(t, body, &plans)
	found := false
	for _, plan := range plans {
		if plan.RecordType == "plan" && plan.Day == today.Day.Time.Format(time.DateOnly) &&
			plan.AssessmentID != nil && *plan.AssessmentID == first.ID {
			if len(plan.Items) == 0 || len(plan.Items) != len(today.Items) || plan.Personalized != today.Personalized {
				t.Fatal("growth.json contains an incomplete plan")
			}
			for i, item := range plan.Items {
				want := today.Items[i]
				if item.ID != want.Id || item.Kind != string(want.Kind) || item.ContentID != want.ContentId ||
					item.Title != want.Title || item.Completed != want.Completed {
					t.Fatalf("growth.json plan item %d differs from the public plan", i)
				}
			}
			found = true
		}
	}
	if !found {
		t.Fatal("growth.json missing the owner's current daily plan")
	}
	del := privacy.Deletion{OperationID: uuid.New(), UserID: a.UserId, Scope: "assessments", SourceID: first.ID}
	if e = s.Data.Delete(ctx, del); e != nil {
		t.Fatal(e)
	}
	if x := export(a.AccessToken); len(x) != 1 || x[0].ID != second.ID {
		t.Fatal("source deletion")
	}
	if e = s.Bus.PublishAssessment(ctx, delivered[0]); e == nil {
		t.Fatal("deleted source replayed")
	}
	if e = s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: a.UserId, Scope: "account"}); e != nil {
		t.Fatal(e)
	}
	if e = s.Bus.PublishAssessment(ctx, delivered[1]); e == nil {
		t.Fatal("deleted account replayed")
	}
}
