//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/privacy"
)

// Exercise the generated routes, running service composition and both privacy hooks.
func TestAccountLifecycle(t *testing.T) {
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
	call := func(method, path, bearer string, data any, status int, dst any) {
		t.Helper()
		b, _ := json.Marshal(data)
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		r.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			r.Header.Set("Authorization", "Bearer "+bearer)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s: got %d, want %d: %s", method, path, w.Code, status, w.Body.String())
		}
		if dst != nil {
			if e := json.Unmarshal(w.Body.Bytes(), dst); e != nil {
				t.Fatal(e)
			}
		}
	}
	proof := func(provider, subject string) map[string]any {
		ticket := uuid.NewString()
		if e := s.cache.Set(ctx, "dev:ticket:"+provider+":"+ticket, subject, time.Minute).Err(); e != nil {
			t.Fatal(e)
		}
		return map[string]any{"provider": provider, "proof": ticket}
	}
	first, other := uuid.NewString(), uuid.NewString()
	login := func(cred any, register bool, status int) app.Tokens {
		v := map[string]any{"credential": cred}
		if register {
			v["age_confirmed"] = true
			v["privacy_version"] = "2026-11"
			v["terms_version"] = "2026-11"
		}
		var out app.Tokens
		call("POST", "auth/login", "", v, status, &out)
		return out
	}
	login(proof("apple", first), false, 400)
	a := login(proof("apple", first), true, 200)
	var rights app.Entitlements
	call("GET", "entitlements", "", nil, 401, nil)
	call("GET", "entitlements", a.AccessToken, nil, 200, &rights)
	if rights.Tier != "free" || len(rights.Allowances) != 3 || rights.AutoWatchAlertAvailable {
		t.Fatalf("unexpected initial rights: %+v", rights)
	}
	for _, allowance := range rights.Allowances {
		if allowance.Remaining == nil || *allowance.Remaining != 3 {
			t.Fatal(allowance)
		}
	}
	b := login(proof("wechat", other), true, 200)
	if a.UserId == b.UserId {
		t.Fatal("merged accounts")
	}
	bind := func(current, next any, status int) {
		call("POST", "me/bindings", a.AccessToken, map[string]any{"current_proof": current, "credential": next}, status, nil)
	}
	bind(proof("apple", first), proof("wechat", other), 409)
	bind(proof("wechat", other), proof("wechat", "unowned"), 401)
	var me app.Account
	call("GET", "me", a.AccessToken, nil, 200, &me)
	if len(me.Bindings) != 1 || me.UserId != a.UserId {
		t.Fatal("conflict changed ownership")
	}
	var switched app.Tokens
	call("POST", "auth/switch", a.AccessToken, map[string]any{"credential": proof("wechat", other)}, 200, &switched)
	if switched.UserId != b.UserId {
		t.Fatal("wrong switch")
	}
	phone := "+8613800000000"
	sms := func(status int) { call("POST", "auth/sms", "", map[string]any{"phone": phone}, status, nil) }
	sms(200)
	// A locked-up challenge is not a reusable password, even in the simulator.
	sms(429)
	phoneCred := map[string]any{"provider": "phone", "phone": phone, "proof": "000000"}
	bind(proof("apple", first), phoneCred, 200)
	login(phoneCred, false, 401)
	var phoneKey []byte
	if e := s.db.QueryRow(ctx, `select subject_hmac from login_identities where user_id=$1 and provider='phone'`, a.UserId).Scan(&phoneKey); e != nil {
		t.Fatal(e)
	}
	advance := func() {
		t.Helper()
		if _, e := s.db.Exec(ctx, "update sms_challenges set sent_at=clock_timestamp()-interval '61 seconds' where phone_hmac=$1", phoneKey); e != nil {
			t.Fatal(e)
		}
	}
	for i := 1; i < 10; i++ {
		advance()
		sms(200)
	}
	advance()
	sms(429)
	device := login(phoneCred, false, 200)
	if device.UserId != a.UserId {
		t.Fatal("device changed user")
	}
	var rot app.Tokens
	call("POST", "auth/refresh", "", map[string]any{"refresh_token": device.RefreshToken}, 200, &rot)
	call("POST", "auth/refresh", "", map[string]any{"refresh_token": device.RefreshToken}, 401, nil)
	call("POST", "auth/logout", a.AccessToken, map[string]any{"refresh_token": rot.RefreshToken}, 401, nil)
	call("POST", "auth/logout", rot.AccessToken, map[string]any{"refresh_token": rot.RefreshToken}, 200, nil)
	call("GET", "me", rot.AccessToken, nil, 401, nil)
	call("PATCH", "me", a.AccessToken, map[string]string{"timezone": "America/Chicago"}, 200, &me)
	if me.Timezone != "America/Chicago" {
		t.Fatal(me)
	}
	// Each page contains current decisions, never old versions of a purpose.
	current := func(tok string) map[app.ConsentPurpose]app.Consent {
		t.Helper()
		result := map[app.ConsentPurpose]app.Consent{}
		path := "me/consents?limit=1"
		for {
			var page app.ListConsentsResult
			call("GET", path, tok, nil, 200, &page)
			for _, v := range page.Items {
				if _, ok := result[v.Purpose]; ok {
					t.Fatalf("duplicate purpose: %s", v.Purpose)
				}
				result[v.Purpose] = v
			}
			if page.NextCursor == nil {
				break
			}
			path = "me/consents?limit=1&cursor=" + *page.NextCursor
		}
		return result
	}
	for _, step := range []struct {
		v     string
		grant bool
	}{{"one", true}, {"one", false}, {"two", true}} {
		var c app.Consent
		call("PUT", "me/consents/health", a.AccessToken, map[string]any{"version": step.v, "granted": step.grant}, 200, &c)
		decisions := current(a.AccessToken)
		if len(decisions) != 3 || decisions["health"] != c || c.Granted != step.grant || c.Version != step.v || !decisions["terms"].Granted {
			t.Fatal("wrong current consent")
		}
		if len(current(b.AccessToken)) != 2 {
			t.Fatal("consent leaked between accounts")
		}
		if e := s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error {
			ok, e := accounts.Granted(ctx, tx, a.UserId, "health")
			if ok != step.grant {
				t.Fatal("wrong collection permission")
			}
			return e
		}); e != nil {
			t.Fatal(e)
		}
	}
	call("PUT", "me/consents/health", a.AccessToken, map[string]any{"version": "one"}, 400, nil)
	// Reconcile optional retention without manufacturing a consent decision.
	{
		const version = "2026-11"
		const route = "me/consents/audio_retention"
		withdraw := map[string]any{"version": version, "granted": false}
		for i := 0; i < 2; i++ {
			var receipt app.Consent
			call("PUT", route, b.AccessToken, withdraw, 200, &receipt)
			if receipt.Purpose != app.ConsentPurposeAudioRetention || receipt.Version != version || receipt.Granted || receipt.UpdatedAt.IsZero() {
				t.Fatalf("invalid no-op withdrawal receipt: %+v", receipt)
			}
		}
		if _, exists := current(b.AccessToken)[app.ConsentPurposeAudioRetention]; exists {
			t.Fatal("withdrawing a never-granted purpose created a decision")
		}

		call("PUT", route, b.AccessToken, map[string]any{"version": "", "granted": false}, 400, nil)
		call("PUT", "me/consents/voice", b.AccessToken, withdraw, 400, nil)
		call("PUT", route, b.AccessToken, map[string]any{"version": version, "granted": true}, 200, nil)
		call("PUT", route, b.AccessToken, map[string]any{"version": "stale", "granted": false}, 400, nil)
		if !current(b.AccessToken)[app.ConsentPurposeAudioRetention].Granted {
			t.Fatal("a mismatched withdrawal changed an active grant")
		}
		var first, retry app.Consent
		call("PUT", route, b.AccessToken, withdraw, 200, &first)
		call("PUT", route, b.AccessToken, withdraw, 200, &retry)
		record := current(b.AccessToken)[app.ConsentPurposeAudioRetention]
		if first.Granted || first != retry || first != record {
			t.Fatalf("withdrawal was not persisted idempotently: first=%+v retry=%+v current=%+v", first, retry, record)
		}
	}
	exp := privacy.ExportRequest{UserID: a.UserId, OperationID: uuid.New()}
	var buf bytes.Buffer
	if e := s.Data.Export(ctx, exp, &buf); e != nil {
		t.Fatal(e)
	}
	z, e := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if e != nil {
		t.Fatal(e)
	}
	f, e := z.Open("accounts.json")
	if e != nil {
		t.Fatal(e)
	}
	p, e := io.ReadAll(f)
	f.Close()
	if e != nil || !bytes.Contains(p, []byte(phone)) || bytes.Count(p, []byte(`"purpose":"health"`)) != 2 || !bytes.Contains(p, []byte("withdrawn_at")) || bytes.Contains(p, []byte(other)) || bytes.Contains(p, []byte(a.RefreshToken)) {
		t.Fatal("unexpected accounts export")
	}
	freeze := func(tok string) {
		call("POST", "me/closure", tok, map[string]any{"proof": proof("apple", first)}, 200, nil)
	}
	freeze(a.AccessToken)
	if e := s.Data.Export(ctx, exp, io.Discard); e == nil {
		t.Fatal("frozen account exported")
	}
	call("DELETE", "me/closure", a.AccessToken, nil, 401, nil)
	recovery := login(proof("apple", first), false, 200)
	call("GET", "entitlements", recovery.AccessToken, nil, 401, nil)
	call("GET", "me", recovery.AccessToken, nil, 200, &me)
	if me.FrozenUntil == nil || time.Until(*me.FrozenUntil) < 359*time.Hour {
		t.Fatal("missing deadline")
	}
	call("PATCH", "me", recovery.AccessToken, map[string]string{"timezone": "UTC"}, 401, nil)
	call("DELETE", "me/closure", recovery.AccessToken, nil, 200, nil)
	freeze(recovery.AccessToken)
	var invoice, activity, source uuid.UUID
	var occurred time.Time
	e = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, e := tx.Exec(ctx, `update users set closure_requested_at=now()-interval '15 days' where id=$1`, a.UserId); e != nil {
			return e
		}
		if e := tx.QueryRow(ctx, `insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)values($1,'wechat',uuid_send(gen_random_uuid()),'m',123,'paid') returning id`, a.UserId).Scan(&invoice); e != nil {
			return e
		}
		return seedAccountScore(ctx, tx, a.UserId, &activity, &source, &occurred)
	})
	if e != nil {
		t.Fatal(e)
	}
	call("POST", "auth/switch", b.AccessToken, map[string]any{"credential": proof("apple", first)}, 401, nil)
	if e := s.Accounts.PurgeDue(ctx); e != nil {
		t.Fatal(e)
	}
	count := 0
	if e := s.db.QueryRow(ctx, `select count(*) from orders where id=$1 and user_id is null`, invoice).Scan(&count); e != nil || count != 1 {
		t.Fatal("missing anonymized order", e)
	}
	for _, table := range []string{"auth_sessions", "consents", "login_identities", "activities"} {
		if e := s.db.QueryRow(ctx, "select count(*) from "+table+" where user_id=$1", a.UserId).Scan(&count); e != nil || count != 0 {
			t.Fatal(table, e)
		}
	}
	if e := s.db.QueryRow(ctx, "select count(*) from sms_challenges where phone_hmac=$1", phoneKey).Scan(&count); e != nil || count != 0 {
		t.Fatal("SMS residual", e)
	}
	key := privacy.ScoreKey{UserID: a.UserId, ActivityID: activity, SourceID: source, OccurredAt: occurred, Kind: "review"}
	if e := s.Data.ConsumeScore(ctx, key, func(context.Context, pgx.Tx, privacy.ScoreSource) error {
		t.Fatal("deleted score replayed")
		return nil
	}); e == nil {
		t.Fatal("replay accepted")
	}
	if e := s.db.QueryRow(ctx, `select (select count(*) from scores where id=$1)+(select count(*) from growth_scores where score_id=$1)+(select count(*) from ai_calls where score_id=$1)`, source).Scan(&count); e != nil || count != 0 {
		t.Fatal("personal copies remain after purge", e)
	}
	if e := s.Data.Export(ctx, exp, io.Discard); e == nil {
		t.Fatal("deleted account exported")
	}
	// Simulate the stale expiry scan: the sweeper sees the old committed deadline
	// while a pre-deadline cancellation is finishing. It must recheck after locking.
	var dueAt time.Time
	if e := s.db.QueryRow(ctx, `update users set closure_requested_at=clock_timestamp()-interval '360 hours'+interval '4 seconds' where id=$1 returning closure_requested_at+interval '360 hours'`, b.UserId).Scan(&dueAt); e != nil {
		t.Fatal(e)
	}
	tx, e := s.db.Begin(ctx)
	if e != nil {
		t.Fatal(e)
	}
	defer tx.Rollback(ctx)
	var pid int
	if e := tx.QueryRow(ctx, "select pg_backend_pid()").Scan(&pid); e != nil {
		t.Fatal(e)
	}
	if _, e := tx.Exec(ctx, "update users set closure_requested_at=null where id=$1", b.UserId); e != nil {
		t.Fatal(e)
	}
	time.Sleep(time.Until(dueAt) + 50*time.Millisecond) // the old committed row is now eligible
	done := make(chan error, 1)
	go func() { done <- s.Accounts.PurgeDue(ctx) }()
	deadline := time.Now().Add(20 * time.Second)
	for {
		var waiting bool
		if e := s.db.QueryRow(ctx, `select exists(select from pg_stat_activity where $1=any(pg_blocking_pids(pid)))`, pid).Scan(&waiting); e != nil {
			t.Fatal(e)
		}
		if waiting {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("sweeper did not wait for cancellation")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if e := tx.Commit(ctx); e != nil {
		t.Fatal(e)
	}
	if e := <-done; e != nil {
		t.Fatal(e)
	}
	call("GET", "me", b.AccessToken, nil, 200, nil)
	if !strings.Contains(a.AccessToken, ".") {
		t.Fatal("not JWT")
	}
}
func seedAccountScore(ctx context.Context, tx pgx.Tx, user uuid.UUID, a, s *uuid.UUID, at *time.Time) error {
	if e := tx.QueryRow(ctx, `insert into activities(user_id,kind,state) values($1,'review','complete') returning id,source_id`, user).Scan(a, s); e != nil {
		return e
	}
	if e := tx.QueryRow(ctx, `insert into scores values($1,$2,'review','fixture',now()) returning occurred_at`, *s, *a).Scan(at); e != nil {
		return e
	}
	if _, e := tx.Exec(ctx, `insert into growth_scores values($1,'review','fixture','fixture')`, *s); e != nil {
		return e
	}
	_, e := tx.Exec(ctx, `with model as (insert into model_configs(name,endpoint,api_key_enc) values('fixture','https://invalid.example','fixture') returning id) insert into ai_calls(activity_id,user_id,score_id,model_id,task,outcome) select $1,$2,$3,id,'scoring','ok' from model`, *a, user, *s)
	return e
}
