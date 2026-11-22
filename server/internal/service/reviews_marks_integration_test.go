//go:build integration

package service

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

// TestReviewMarkLinks exercises the T32A mark -> T23 review path through the
// production Gin routes and transactions. The model and moderation endpoints are
// loopback TLS fixtures; accounts and records are disposable synthetic data.
func TestReviewMarkLinks(t *testing.T) {
	ctx := t.Context()
	f := &reviewUpstream{entered: make(chan struct{}), resume: make(chan struct{})}
	close(f.resume)
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
		check(request("POST", "auth/login", "", map[string]any{
			"credential":      map[string]string{"provider": "apple", "proof": ticket},
			"age_confirmed":   true,
			"privacy_version": "2026-11",
			"terms_version":   "2026-11",
		}), 200, &v)
		return v
	}
	consent := func(token, purpose string) {
		check(request("PUT", "me/consents/"+purpose, token, map[string]any{"version": "v1", "granted": true}), 200, nil)
	}
	createMark := func(token string) app.Mark {
		var mark app.Mark
		check(request("POST", "marks", token, app.CreateMarkInput{RequestId: uuid.New()}), 200, &mark)
		return mark
	}
	count := func(q string, want int, args ...any) {
		t.Helper()
		var n int
		must(s.db.QueryRow(ctx, q, args...).Scan(&n))
		if n != want {
			t.Fatalf("expected %d rows, got %d in %s", want, n, q)
		}
	}

	a, b := signup(), signup()
	for _, token := range []string{a.AccessToken, b.AccessToken} {
		consent(token, "review")
		consent(token, "manual_mark")
	}
	foreign := createMark(b.AccessToken)
	sc := app.ReviewInputSceneWork
	input := func() app.ReviewInput {
		return app.ReviewInput{
			RequestId:            uuid.New(),
			Scene:                &sc,
			Happened:             "T23-T32A-SYNTHETIC-MEETING",
			MyFeeling:            "着急",
			TheirPossibleFeeling: "也许没说完",
			MyAction:             "我先说完",
			NextAction:           "等对方说完",
		}
	}
	post := func(token string, in app.ReviewInput) reviewResponse {
		return request("POST", "reviews", token, in)
	}

	foreignIn := input()
	foreignIn.MarkId = &foreign.Id
	analyses := f.analyses.Load()
	check(post(a.AccessToken, foreignIn), 400, nil)
	if f.analyses.Load() != analyses {
		t.Fatal("foreign mark reached the model")
	}
	count(`select count(*) from review_requests where request_id=$1`, 0, foreignIn.RequestId)

	own := createMark(a.AccessToken)
	// The retention predicate is exclusive. A mark exactly at 4320 hours is no
	// longer linkable; five minutes inside the boundary remains linkable.
	_, e := s.db.Exec(ctx, `update manual_marks set accepted_at=clock_timestamp()-interval '4320 hours' where id=$1`, own.Id)
	must(e)
	boundary := input()
	boundary.MarkId = &own.Id
	check(post(a.AccessToken, boundary), 400, nil)
	count(`select count(*) from review_requests where request_id=$1`, 0, boundary.RequestId)

	_, e = s.db.Exec(ctx, `update manual_marks set accepted_at=clock_timestamp()-interval '4320 hours'+interval '5 minutes' where id=$1`, own.Id)
	must(e)
	linkedIn := input()
	linkedIn.MarkId = &own.Id
	var linked app.Review
	check(post(a.AccessToken, linkedIn), 200, &linked)
	var persistedMark string
	must(s.db.QueryRow(ctx, `select r.mark_id::text from review_requests r where r.activity_id=$1`, linked.Id).Scan(&persistedMark))
	if persistedMark != own.Id.String() {
		t.Fatalf("linked mark = %q, want %q", persistedMark, own.Id)
	}

	reviewPath := "reviews/" + linked.Id.String()
	check(request("GET", reviewPath, b.AccessToken, nil), 404, nil)
	check(request("DELETE", reviewPath, b.AccessToken, nil), 404, nil)
	check(request("GET", reviewPath, a.AccessToken, nil), 200, nil)

	// Deleting the source mark must retain the completed review and clear only the
	// optional association. The review remains readable and independently deletable.
	check(request("DELETE", "marks/"+own.Id.String(), a.AccessToken, nil), 200, nil)
	var retained, unlinked bool
	must(s.db.QueryRow(ctx, `
		select exists(select from activities where id=$1),
		       coalesce((select mark_id is null from review_requests where activity_id=$1),false)`, linked.Id).Scan(&retained, &unlinked))
	if !retained || !unlinked {
		t.Fatalf("review retained=%v mark-unlinked=%v", retained, unlinked)
	}
	check(request("GET", reviewPath, a.AccessToken, nil), 200, nil)

	// Reviews without a mark stay a supported path after source deletion.
	plain := input()
	var noMark app.Review
	check(post(a.AccessToken, plain), 200, &noMark)
	count(`select coalesce(sum(used),0) from daily_quota_usage where feature='review' and user_id=$1`, 2, a.UserId)

	// A source older than 180 days is rejected before model dispatch.
	expired := createMark(a.AccessToken)
	_, e = s.db.Exec(ctx, `update manual_marks set accepted_at=clock_timestamp()-interval '4320 hours'-interval '1 minute' where id=$1`, expired.Id)
	must(e)
	expiredIn := input()
	expiredIn.MarkId = &expired.Id
	analyses = f.analyses.Load()
	check(post(a.AccessToken, expiredIn), 400, nil)
	if f.analyses.Load() != analyses {
		t.Fatal("expired mark reached the model")
	}
	count(`select count(*) from review_requests where request_id=$1`, 0, expiredIn.RequestId)
	check(request("DELETE", "marks/"+expired.Id.String(), a.AccessToken, nil), 200, nil)

	check(request("DELETE", reviewPath, a.AccessToken, nil), 200, nil)
	check(request("GET", reviewPath, a.AccessToken, nil), 404, nil)
	count(`select count(*) from review_requests where activity_id=$1`, 0, linked.Id)
	check(request("DELETE", "reviews/"+noMark.Id.String(), a.AccessToken, nil), 200, nil)
}
