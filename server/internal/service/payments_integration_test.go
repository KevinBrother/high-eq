//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/payments"
	"high-eq/server/internal/payments/testkit"
	"high-eq/server/internal/privacy"
)

// Exercises the generated API, session/erasure barrier, PostgreSQL facts and
// the unmodified T06 reader. All platform signers are ephemeral, offline keys.
func TestPaymentLifecycle(t *testing.T) {
	t.Setenv("PAYMENT_MODE", "disabled")
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	day := 24 * time.Hour
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	pki := testkit.Chain(t, now)
	pk := testkit.RSA(t)
	ch := &payments.AndroidChannel{NotifyBase: "https://merchant.invalid", App: "test-app", Merchant: "test-mch", Serial: "synthetic", PlatformKey: &pk.PublicKey, MerchantKey: testkit.RSA(t), APIv3Key: []byte("0123456789abcdef0123456789abcdef")}
	ch.Prepay = func(_ context.Context, r payments.PrepayRequest) (string, error) {
		var b struct {
			Order string `json:"out_trade_no"`
		}
		e := json.Unmarshal(r.Body, &b)
		return "sandbox_" + b.Order, e
	}
	catalog := payments.Catalog{"monthly": {SKU: "test.month", Days: 30, Fen: 1200}, "yearly": {SKU: "test.year", Days: 365, Fen: 8800}}
	cfg.PaymentChannels = payments.Channels{Apple: &payments.Apple{Environment: "Sandbox", Bundle: "test.bundle", Roots: pki.Pool, Products: catalog}, Android: map[string]*payments.AndroidChannel{"alipay": ch, "wechat": ch}, Products: catalog}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	router := s.Router()
	call := func(method, path, token, media string, body []byte, h map[string]string, status int) []byte {
		t.Helper()
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		r.Header.Set("Content-Type", media)
		for k, v := range h {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != status {
			t.Errorf("%s: got %d want %d: %s", path, w.Code, status, w.Body.String())
		}
		return w.Body.Bytes()
	}
	post := func(path, token string, body any, status int, out any) {
		t.Helper()
		b, e := json.Marshal(body)
		if e != nil {
			t.Fatal(e)
		}
		b = call("POST", path, token, "application/json", b, nil, status)
		if out != nil {
			if e = json.Unmarshal(b, out); e != nil {
				t.Fatal(e)
			}
		}
	}
	login := func(subject string) app.Tokens {
		ticket := uuid.NewString()
		if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, subject, time.Minute).Err(); e != nil {
			t.Fatal(e)
		}
		var tok app.Tokens
		post("auth/login", "", map[string]any{"credential": map[string]any{"provider": "apple", "proof": ticket}, "age_confirmed": true, "terms_version": "2026-11", "privacy_version": "2026-11"}, 200, &tok)
		return tok
	}
	aSub := uuid.NewString()
	a, b := login(aSub), login(uuid.NewString())
	rights := func(who app.Tokens, end time.Time) {
		t.Helper()
		var got app.Entitlements
		raw := call("GET", "entitlements", who.AccessToken, "application/json", nil, nil, 200)
		if e := json.Unmarshal(raw, &got); e != nil {
			t.Fatal(e)
		}
		if end.IsZero() {
			if got.Tier != "free" || got.ExpiresAt != nil {
				t.Fatal(got)
			}
			return
		}
		if got.Tier != "member" || got.ExpiresAt == nil || !got.ExpiresAt.Equal(end) {
			t.Fatalf("want member to %s got %+v", end, got)
		}
	}
	token := func(a app.Tokens) string {
		var out app.GetPurchaseTokenResult
		post("purchases/token", a.AccessToken, nil, 200, &out)
		return out.AppAccountToken.String()
	}
	at := token(a)
	if at == token(b) || at != token(a) {
		t.Fatal("unstable account token")
	}
	post("purchases/token", "", nil, 401, nil)
	rights(a, time.Time{})
	create := func(platform, product string, req uuid.UUID, status int) payments.Order {
		var o payments.Order
		post("purchases", a.AccessToken, map[string]any{"platform": platform, "product": product, "request_id": req}, status, &o)
		return o
	}
	req := uuid.New()
	original := ch.Prepay
	calls := 0
	var attempted string
	ch.Prepay = func(ctx context.Context, r payments.PrepayRequest) (string, error) {
		calls++
		var b struct {
			Order string `json:"out_trade_no"`
		}
		if e := json.Unmarshal(r.Body, &b); e != nil {
			return "", e
		}
		if calls == 1 {
			attempted = b.Order
			return "", payments.ErrGateway
		}
		if attempted != b.Order {
			t.Fatal("timeout created another merchant order")
		}
		return original(ctx, r)
	}
	create("wechat", "monthly", req, 500)
	wx := create("wechat", "monthly", req, 200)
	if wx.ID == uuid.Nil || wx != create("wechat", "monthly", req, 200) || calls != 2 {
		t.Fatal("non-idempotent checkout")
	}
	create("alipay", "yearly", req, 400)
	rights(a, time.Time{})
	tx := uuid.NewString()
	r := map[string]any{"appid": ch.App, "mchid": ch.Merchant, "transaction_id": tx, "out_trade_no": strings.ReplaceAll(wx.ID.String(), "-", ""), "trade_type": "APP", "trade_state": "SUCCESS", "success_time": now, "amount": map[string]any{"total": 1199, "currency": "CNY"}}
	notify := func(kind string, status int) {
		body, h := testkit.Wx(t, pk, ch.APIv3Key, kind, uuid.NewString(), r, now)
		call("POST", "payment-notifications/wechat", "", "application/json", body, h, status)
	}
	notify("TRANSACTION.SUCCESS", 400)
	rights(a, time.Time{})
	r["amount"] = map[string]any{"total": 1200, "currency": "CNY"}
	body, h := testkit.Wx(t, pk, ch.APIv3Key, "TRANSACTION.SUCCESS", uuid.NewString(), r, now)
	call("POST", "payment-notifications/wechat", "", "application/json", append(append([]byte{}, body...), ' '), h, 400)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if len(call("POST", "payment-notifications/wechat", "", "application/json", body, h, 200)) != 0 {
				t.Error("expected empty ack")
			}
		}()
	}
	wg.Wait()
	rights(a, now.Add(30*day))
	retry, _ := json.Marshal(map[string]any{"platform": "wechat", "product": "monthly", "request_id": req})
	if body := call("POST", "purchases", a.AccessToken, "application/json", retry, nil, 409); !bytes.Contains(body, []byte("已支付")) {
		t.Fatalf("paid retry was not actionable: %s", body)
	}
	if calls != 2 {
		t.Fatal("paid retry crossed the provider boundary")
	}
	rights(b, time.Time{})
	chain := uuid.NewString()
	purchase := testkit.TransactionSignedAt(at, uuid.NewString(), chain, now.Add(-day), now, now.Add(day))
	restore := func(who app.Tokens, claims map[string]any, status int) {
		t.Helper()
		post("purchases/restore", who.AccessToken, map[string]string{"signed_transaction": pki.Sign(t, claims)}, status, nil)
	}
	restore(b, purchase, 409)
	rights(b, time.Time{})
	a = login(aSub)
	if token(a) != at {
		t.Fatal("reinstall changed token")
	}
	restore(a, purchase, 200)
	restore(a, purchase, 200)
	rights(a, now.Add(31*day))
	renew := testkit.TransactionSignedAt(at, uuid.NewString(), chain, now, now, now.Add(3*day))
	appleNotice := func(kind string, claims map[string]any, status int) {
		n := pki.Sign(t, testkit.NoticeAt(kind, uuid.NewString(), pki.Sign(t, claims), now))
		for i := 0; i < 2; i++ {
			post("payment-notifications/apple", "", map[string]string{"signedPayload": n}, status, nil)
		}
	}
	appleNotice("DID_RENEW", renew, 200)
	rights(a, now.Add(33*day))
	badOwner := testkit.TransactionSignedAt(token(b), uuid.NewString(), chain, now, now, now.Add(day))
	restore(b, badOwner, 409)
	rights(b, time.Time{})
	renew["revocationDate"] = now.UnixMilli()
	appleNotice("REFUND", renew, 200)
	delete(renew, "revocationDate")
	restore(a, renew, 200)
	rights(a, now.Add(31*day))
	purchase["revocationDate"] = now.UnixMilli()
	purchase["signedDate"] = now.UnixMilli()
	appleNotice("REFUND", purchase, 200)
	rights(a, now.Add(30*day))
	r["refund_status"] = "SUCCESS"
	r["amount"] = map[string]any{"total": 1200, "refund": 1200}
	notify("REFUND.SUCCESS", 200)
	rights(a, time.Time{})
	expired := testkit.TransactionSignedAt(at, uuid.NewString(), uuid.NewString(), now.Add(-2*day), now, now.Add(-day))
	appleNotice("EXPIRED", expired, 200)
	rights(a, time.Time{})
	ali := create("alipay", "yearly", uuid.New(), 200)
	f := url.Values{"app_id": {ch.App}, "seller_id": {ch.Merchant}, "out_trade_no": {ali.ID.String()}, "trade_no": {uuid.NewString()}, "trade_status": {"TRADE_SUCCESS"}, "notify_id": {uuid.NewString()}, "total_amount": {"88.00"}, "gmt_payment": {now.In(time.FixedZone("CST", 8*3600)).Format(time.DateTime)}}
	aliNotice := func(status int) {
		t.Helper()
		res := call("POST", "payment-notifications/alipay", "", "application/x-www-form-urlencoded", testkit.Ali(t, pk, f), nil, status)
		if status == 200 && string(res) != "success" {
			t.Fatal("bad Alipay ACK")
		}
	}
	aliNotice(200)
	aliNotice(200)
	rights(a, now.Add(365*day))
	f.Set("trade_status", "TRADE_CLOSED")
	f.Set("refund_fee", "88.00")
	f.Set("gmt_refund", f.Get("gmt_payment"))
	aliNotice(400)
	rights(a, now.Add(365*day))
	f.Set("notify_id", uuid.NewString())
	aliNotice(200)
	rights(a, time.Time{})
	var buf bytes.Buffer
	e = s.Data.Export(ctx, privacy.ExportRequest{OperationID: uuid.New(), UserID: a.UserId}, &buf)
	if e != nil {
		t.Fatal(e)
	}
	z, e := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if e != nil {
		t.Fatal(e)
	}
	part, e := z.Open("payments.json")
	if e != nil {
		t.Fatal(e)
	}
	export, e := io.ReadAll(part)
	part.Close()
	if e != nil || !bytes.Contains(export, []byte(wx.ID.String())) || bytes.Contains(export, []byte(at)) || bytes.Contains(export, []byte(tx)) {
		t.Fatal("invalid payment export")
	}
	e = s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: a.UserId, Scope: "account"})
	if e != nil {
		t.Fatal(e)
	}
	aliNotice(400)
	restore(b, purchase, 409)
	var anonymous bool
	if e = s.db.QueryRow(ctx, "select user_id is null from orders where id=$1", wx.ID).Scan(&anonymous); e != nil || !anonymous {
		t.Fatal("financial stub not anonymized", e)
	}
	rights(b, time.Time{})
}

// A verified event may settle while the account is in the 15-day closure
// grace period. Cancellation must expose the already-recorded fact without a
// replay or reconciliation request from the user.
func TestPaymentNotificationDuringClosureGrace(t *testing.T) {
	t.Setenv("PAYMENT_MODE", "disabled")
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	pki := testkit.Chain(t, now)
	catalog := payments.Catalog{"monthly": {SKU: "test.month", Days: 30, Fen: 1200}, "yearly": {SKU: "test.year", Days: 365, Fen: 8800}}
	cfg.PaymentChannels = payments.Channels{Apple: &payments.Apple{Environment: "Sandbox", Bundle: "test.bundle", Roots: pki.Pool, Products: catalog}, Products: catalog}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	router := s.Router()
	call := func(method, path, token, media string, body []byte, h map[string]string, status int) []byte {
		t.Helper()
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(body))
		if token != "" {
			r.Header.Set("Authorization", "Bearer "+token)
		}
		r.Header.Set("Content-Type", media)
		for k, v := range h {
			r.Header.Set(k, v)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s: got %d want %d: %s", path, w.Code, status, w.Body.String())
		}
		return w.Body.Bytes()
	}
	post := func(path, token string, body any, status int, out any) {
		t.Helper()
		b, e := json.Marshal(body)
		if e != nil {
			t.Fatal(e)
		}
		b = call("POST", path, token, "application/json", b, nil, status)
		if out != nil {
			if e = json.Unmarshal(b, out); e != nil {
				t.Fatal(e)
			}
		}
	}
	proof := func(subject string) map[string]any {
		ticket := uuid.NewString()
		if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, subject, time.Minute).Err(); e != nil {
			t.Fatal(e)
		}
		return map[string]any{"provider": "apple", "proof": ticket}
	}
	login := func(subject string) app.Tokens {
		var tok app.Tokens
		post("auth/login", "", map[string]any{"credential": proof(subject), "age_confirmed": true, "terms_version": "2026-11", "privacy_version": "2026-11"}, 200, &tok)
		return tok
	}
	subject := uuid.NewString()
	a := login(subject)
	var purchaseToken app.GetPurchaseTokenResult
	post("purchases/token", a.AccessToken, nil, 200, &purchaseToken)
	purchase := testkit.Transaction(purchaseToken.AppAccountToken.String(), uuid.NewString(), uuid.NewString(), now.Add(-time.Hour), now.Add(time.Hour))
	post("purchases/restore", a.AccessToken, map[string]string{"signed_transaction": pki.Sign(t, purchase)}, 200, nil)
	post("me/closure", a.AccessToken, map[string]any{"proof": proof(subject)}, 200, nil)
	// Freeze invalidates the old session but permits login during grace.
	a = login(subject)
	purchase["revocationDate"] = now.UnixMilli()
	purchase["signedDate"] = now.UnixMilli()
	notice := pki.Sign(t, testkit.NoticeAt("REFUND", uuid.NewString(), pki.Sign(t, purchase), now))
	post("payment-notifications/apple", "", map[string]string{"signedPayload": notice}, 200, nil)
	if _, e := s.db.Exec(ctx, `update users set closure_requested_at=now()-interval '361 hours' where id=$1`, a.UserId); e != nil {
		t.Fatal(e)
	}
	due := pki.Sign(t, testkit.NoticeAt("REFUND", uuid.NewString(), pki.Sign(t, purchase), now))
	post("payment-notifications/apple", "", map[string]string{"signedPayload": due}, 401, nil)
	if _, e := s.db.Exec(ctx, `update users set closure_requested_at=now() where id=$1`, a.UserId); e != nil {
		t.Fatal(e)
	}
	call("DELETE", "me/closure", a.AccessToken, "application/json", nil, nil, 200)
	var rights app.Entitlements
	call("GET", "entitlements", a.AccessToken, "application/json", nil, nil, 200)
	if e := json.Unmarshal(call("GET", "entitlements", a.AccessToken, "application/json", nil, nil, 200), &rights); e != nil {
		t.Fatal(e)
	}
	if rights.Tier != "free" || rights.ExpiresAt != nil {
		t.Fatalf("grace-period refund was not projected: %+v", rights)
	}

	// Renewal follows the same notify path but must be exercised independently:
	// a valid DID_RENEW during grace has to be recorded and become visible after
	// cancellation, without a user-triggered replay.
	renewSubject := uuid.NewString()
	renewUser := login(renewSubject)
	var renewToken app.GetPurchaseTokenResult
	post("purchases/token", renewUser.AccessToken, nil, 200, &renewToken)
	chain := uuid.NewString()
	initial := testkit.Transaction(renewToken.AppAccountToken.String(), uuid.NewString(), chain, now.Add(-time.Hour), now.Add(time.Hour))
	post("purchases/restore", renewUser.AccessToken, map[string]string{"signed_transaction": pki.Sign(t, initial)}, 200, nil)
	post("me/closure", renewUser.AccessToken, map[string]any{"proof": proof(renewSubject)}, 200, nil)
	renewUser = login(renewSubject)
	renewEnd := now.Add(72 * time.Hour)
	renewal := testkit.Transaction(renewToken.AppAccountToken.String(), uuid.NewString(), chain, now, renewEnd)
	renewNotice := pki.Sign(t, testkit.NoticeAt("DID_RENEW", uuid.NewString(), pki.Sign(t, renewal), now))
	post("payment-notifications/apple", "", map[string]string{"signedPayload": renewNotice}, 200, nil)
	call("DELETE", "me/closure", renewUser.AccessToken, "application/json", nil, nil, 200)
	var renewed app.Entitlements
	if e := json.Unmarshal(call("GET", "entitlements", renewUser.AccessToken, "application/json", nil, nil, 200), &renewed); e != nil {
		t.Fatal(e)
	}
	if renewed.Tier != "member" || renewed.ExpiresAt == nil || !renewed.ExpiresAt.Equal(renewEnd) {
		t.Fatalf("grace-period renewal was not projected: %+v", renewed)
	}
}

// Export is an account-locked observation point. A naturally expired paid
// order must be persisted as expired before its JSON row is emitted.
func TestPaymentNaturalExpiryExport(t *testing.T) {
	t.Setenv("PAYMENT_MODE", "disabled")
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	user, order := uuid.New(), uuid.New()
	if _, e = s.db.Exec(ctx, `insert into users(id,age_confirmed_at) values($1,now())`, user); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec(ctx, `insert into orders(id,user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,$2,'wechat',$3,'monthly',1200,'paid')`, order, user, []byte("natural-expiry-"+uuid.NewString())); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec(ctx, `insert into payment_facts(order_id,user_id,request_id,paid_at,card_days) values($1,$2,$3,$4,30)`, order, user, uuid.New(), now.Add(-48*time.Hour)); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec(ctx, `insert into entitlements(order_id,user_id,starts_at,ends_at) values($1,$2,$3,$4)`, order, user, now.Add(-48*time.Hour), now.Add(-time.Hour)); e != nil {
		t.Fatal(e)
	}
	var buf bytes.Buffer
	if e = s.Data.Export(ctx, privacy.ExportRequest{OperationID: uuid.New(), UserID: user}, &buf); e != nil {
		t.Fatal(e)
	}
	var state string
	if e = s.db.QueryRow(ctx, `select state from orders where id=$1`, order).Scan(&state); e != nil || state != "expired" {
		t.Fatalf("natural expiry left order state %q: %v", state, e)
	}
	z, e := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if e != nil {
		t.Fatal(e)
	}
	part, e := z.Open("payments.json")
	if e != nil {
		t.Fatal(e)
	}
	raw, e := io.ReadAll(part)
	part.Close()
	if e != nil {
		t.Fatal(e)
	}
	var rows []struct {
		ID    uuid.UUID `json:"id"`
		State string    `json:"state"`
	}
	if e = json.Unmarshal(raw, &rows); e != nil {
		t.Fatal(e)
	}
	for _, row := range rows {
		if row.ID == order && row.State == "expired" {
			return
		}
	}
	t.Fatalf("export did not contain expired order %s: %s", order, raw)
}
