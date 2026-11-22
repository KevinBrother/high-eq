//go:build integration && t23

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

// Requires T23 and T25 assembled on the same runtime and a disposable PG/Redis
// stack. The upstream is T23's synthetic vendor; all app routes, source writes,
// feedback, grouping and deletion use the production services.
func TestProfileReviewSourceLifecycle(t *testing.T) {
	ctx := t.Context()
	f := &reviewUpstream{entered: make(chan struct{}), resume: make(chan struct{})}
	close(f.resume)
	s := reviewRuntime(t, f)
	router := s.Router()
	call := func(t *testing.T, method, path, token string, in any, status int, out any) {
		t.Helper()
		b, err := json.Marshal(in)
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s: status %d, want %d: %s", method, path, w.Code, status, w.Body)
		}
		if out != nil {
			if err := json.Unmarshal(w.Body.Bytes(), out); err != nil {
				t.Fatal(err)
			}
		}
	}
	signup := func() app.Tokens {
		t.Helper()
		ticket := uuid.NewString()
		if err := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); err != nil {
			t.Fatal(err)
		}
		var a app.Tokens
		call(t, "POST", "auth/login", "", map[string]any{
			"credential":    map[string]string{"provider": "apple", "proof": ticket},
			"age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11",
		}, 200, &a)
		return a
	}
	a, foreign := signup(), signup()
	token := a.AccessToken
	for _, purpose := range []string{"contacts", "review"} {
		call(t, "PUT", "me/consents/"+purpose, token, map[string]any{"version": "v1", "granted": true}, 200, nil)
	}
	// Only membership is seeded. No activity, feedback, or projection is seeded.
	if _, err := s.db.Exec(ctx, `with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '2 days',now()+interval '1 day' from o`, a.UserId, []byte(uuid.NewString())); err != nil {
		t.Fatal(err)
	}
	work := app.ReviewInputSceneWork
	for _, tc := range []struct {
		name  string
		scene *app.ReviewInputScene
	}{
		{name: "work", scene: &work},
		{name: "null scene"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var contact app.Contact
			call(t, "POST", "contacts", token, map[string]string{"nickname": "合成关系人", "scene": "friends"}, 200, &contact)
			in := app.ReviewInput{RequestId: uuid.New(), ContactId: &contact.Id, Scene: tc.scene,
				Happened: "T23-T25 synthetic private journal", MyFeeling: "着急", TheirPossibleFeeling: "也许没说完", MyAction: "我先说完", NextAction: "等对方说完"}
			var review app.Review
			call(t, "POST", "reviews", token, in, 200, &review)
			counts := func(want int) {
				t.Helper()
				var facts, applied, contexts int
				err := s.db.QueryRow(ctx, `select (select count(*) from profile_observations where activity_id=$1), (select count(*) from profile_observations where activity_id=$1 and applied), (select count(*) from activity_profile_context where activity_id=$1)`, review.Id).Scan(&facts, &applied, &contexts)
				if err != nil || facts != want || applied != want || contexts != want {
					t.Fatalf("feedback counts: facts=%d applied=%d contexts=%d; want %d each; err=%v", facts, applied, contexts, want, err)
				}
			}
			groups := func(want int) {
				t.Helper()
				var summary app.EmotionSummaryResult
				call(t, "GET", "emotion-summary", token, nil, 200, &summary)
				if len(summary.Groups) != want {
					t.Fatalf("groups=%+v, want %d", summary.Groups, want)
				}
				for _, g := range summary.Groups {
					if g.ContactId == nil || *g.ContactId != contact.Id || g.ConfirmedSelfCount != 1 || g.ManualCount != 0 ||
						(tc.scene == nil) != (g.Scene == nil) || tc.scene != nil && *g.Scene != string(*tc.scene) {
						t.Fatalf("unexpected group for %s: %+v", tc.name, g)
					}
				}
			}
			note := "本人上头"
			fb := app.SendProfileFeedbackInput{SourceId: review.Score.ScoreId, Subject: "self", Confirmed: true, Note: &note}
			counts(0)
			groups(0)
			call(t, "POST", "profiles/feedback", foreign.AccessToken, fb, 404, nil)
			wrongKey := fb
			wrongKey.SourceId = review.Id
			call(t, "POST", "profiles/feedback", token, wrongKey, 404, nil)
			counts(0)
			call(t, "POST", "profiles/feedback", token, fb, 200, nil)
			counts(1)
			groups(1)
			var id uuid.UUID
			var enc []byte
			if err := s.db.QueryRow(ctx, `select id,fact_enc from profile_observations where activity_id=$1`, review.Id).Scan(&id, &enc); err != nil {
				t.Fatal(err)
			}
			plain, err := s.Fields.Open(enc, []byte("feedback/"+a.UserId.String()+"/"+id.String()))
			want := `{"positive":true}`
			if tc.scene != nil {
				want = `{"positive":true,"scene":"work"}`
			}
			if err != nil || !bytes.Equal(plain, []byte(want)) {
				t.Fatal("feedback fact must contain only direction and optional scene")
			}

			call(t, "PATCH", "contacts/"+contact.Id.String(), token, map[string]string{"nickname": "已改名", "scene": "partner"}, 200, nil)
			call(t, "POST", "profiles/feedback", token, fb, 200, nil)
			counts(1)
			groups(1)
			call(t, "DELETE", "reviews/"+review.Id.String(), token, nil, 200, nil)
			counts(0)
			groups(0)
			call(t, "POST", "profiles/feedback", token, fb, 404, nil)
		})
	}
}
