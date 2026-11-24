//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"high-eq/server/internal/api/app"
)

// Exercise the phone-only account through generated HTTP routes and the
// runtime maintenance pass used by cmd/api.
func TestPrivacyPhoneOnlyClosureHTTP(t *testing.T) {
	ctx := context.Background()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	router := s.Router()

	call := func(method, path, bearer string, body any, want int, result any) {
		t.Helper()
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest(method, "/v1"+path, bytes.NewReader(raw))
		r.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			r.Header.Set("Authorization", "Bearer "+bearer)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != want {
			t.Fatalf("%s %s: got %d, want %d", method, path, w.Code, want)
		}
		if result != nil {
			if err := json.Unmarshal(w.Body.Bytes(), result); err != nil {
				t.Fatal(err)
			}
		}
	}

	const phone = "+99900000001"
	proof := map[string]any{"provider": "phone", "phone": phone, "proof": "000000"}
	login := func(register bool, want int) app.Tokens {
		t.Helper()
		body := map[string]any{"credential": proof}
		var tokens app.Tokens
		if register {
			body["age_confirmed"] = true
			body["privacy_version"] = "2026-11"
			body["terms_version"] = "2026-11"
		}
		if want == 200 {
			call("POST", "/auth/login", "", body, want, &tokens)
		} else {
			call("POST", "/auth/login", "", body, want, nil)
		}
		return tokens
	}
	sms := func() {
		t.Helper()
		call("POST", "/auth/sms", "", map[string]any{"phone": phone}, 200, nil)
	}
	sms()
	initial := login(true, 200)
	initialAccess := initial.AccessToken

	var phoneKey []byte
	if err := s.db.QueryRow(ctx, `select subject_hmac from login_identities where user_id=$1 and provider='phone'`, initial.UserId).Scan(&phoneKey); err != nil {
		t.Fatal(err)
	}
	freshSMS := func() {
		t.Helper()
		if _, err := s.db.Exec(ctx, `update sms_challenges set sent_at=clock_timestamp()-interval '61 seconds' where phone_hmac=$1`, phoneKey); err != nil {
			t.Fatal(err)
		}
		sms()
	}
	assertMe := func(access, zone string, expectedFreeze *time.Time) {
		t.Helper()
		var me app.Account
		call("GET", "/me", access, nil, 200, &me)
		if me.UserId != initial.UserId || me.Timezone != zone || len(me.Bindings) != 1 || me.Bindings[0] != "phone" {
			t.Fatal("account readback changed the owner, timezone or phone-only binding")
		}
		if expectedFreeze == nil && me.FrozenUntil != nil ||
			expectedFreeze != nil && (me.FrozenUntil == nil || !me.FrozenUntil.Equal(*expectedFreeze)) {
			t.Fatal("account readback did not match the closure deadline")
		}
	}
	correction := map[string]string{"timezone": "UTC"}
	call("PATCH", "/me", initialAccess, correction, 200, nil)
	assertMe(initialAccess, "UTC", nil)

	closure := map[string]any{"proof": proof}
	call("POST", "/me/closure", initialAccess, closure, 401, nil)
	assertMe(initialAccess, "UTC", nil)
	freshSMS()
	var freeze app.FreezeAccountResult
	call("POST", "/me/closure", initialAccess, closure, 200, &freeze)
	if remaining := time.Until(freeze.FrozenUntil); remaining < 359*time.Hour || remaining > 361*time.Hour {
		t.Fatalf("phone-only frozen window = %s, want about 15 days", remaining)
	}
	call("GET", "/me", initialAccess, nil, 401, nil)
	call("DELETE", "/me/closure", initialAccess, nil, 401, nil)
	call("POST", "/auth/refresh", "", map[string]string{"refresh_token": initial.RefreshToken}, 401, nil)
	var sessions int
	if err := s.db.QueryRow(ctx, `select count(*) from auth_sessions where user_id=$1`, initial.UserId).Scan(&sessions); err != nil || sessions != 0 {
		t.Fatalf("old sessions after freeze = %d (%v)", sessions, err)
	}

	freshSMS()
	recovery := login(false, 200)
	assertMe(recovery.AccessToken, "UTC", &freeze.FrozenUntil)
	call("PATCH", "/me", recovery.AccessToken, correction, 401, nil)
	call("GET", "/plans/today", recovery.AccessToken, nil, 401, nil)
	call("GET", "/growth", recovery.AccessToken, nil, 401, nil)

	var cancelled app.Ack
	call("DELETE", "/me/closure", recovery.AccessToken, nil, 200, &cancelled)
	if !cancelled.Ok {
		t.Fatal("cancellation was not acknowledged")
	}
	assertMe(recovery.AccessToken, "UTC", nil)
	call("GET", "/me", initialAccess, nil, 401, nil)

	freshSMS()
	call("POST", "/me/closure", recovery.AccessToken, closure, 200, nil)
	freshSMS()
	expiring := login(false, 200)
	if _, err := s.db.Exec(ctx, `update users set closure_requested_at=clock_timestamp()-interval '360 hours' where id=$1`, initial.UserId); err != nil {
		t.Fatal(err)
	}
	call("GET", "/me", expiring.AccessToken, nil, 401, nil)
	call("DELETE", "/me/closure", expiring.AccessToken, nil, 401, nil)

	s.RunMaintenancePass(ctx, time.Now())
	var remains int
	if err := s.db.QueryRow(ctx, `select
		(select count(*) from users where id=$1) +
		(select count(*) from login_identities where user_id=$1) +
		(select count(*) from auth_sessions where user_id=$1) +
		(select count(*) from consents where user_id=$1) +
		(select count(*) from sms_challenges where phone_hmac=$2)`, initial.UserId, phoneKey).Scan(&remains); err != nil || remains != 0 {
		t.Fatalf("phone account rows after maintenance = %d (%v)", remains, err)
	}
	call("GET", "/me", expiring.AccessToken, nil, 401, nil)
	call("DELETE", "/me/closure", expiring.AccessToken, nil, 401, nil)
	sms()
	login(false, 400)
}
