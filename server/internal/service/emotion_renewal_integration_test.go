//go:build integration

package service

import (
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/payments"
	"high-eq/server/internal/payments/testkit"
)

func TestT32BMotionAcrossMembershipRenewalHTTP(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Millisecond)
	target := now.Truncate(30 * time.Second).Add(-12 * time.Minute)
	earliest, cut := target.Add(-90*time.Second), target.Add(-time.Minute)
	previousStart, currentEnd := target.Add(-30*24*time.Hour), target.Add(30*24*time.Hour)
	pki := testkit.Chain(t, now)
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	products := payments.Catalog{
		"monthly": {SKU: "test.month", Days: 30, Fen: 1200},
		"yearly":  {SKU: "test.year", Days: 365, Fen: 8800},
	}
	cfg.PaymentChannels = payments.Channels{Apple: &payments.Apple{
		Environment: "Sandbox", Bundle: "test.bundle", Roots: pki.Pool, Products: products,
	}, Products: products}
	root := setupSignalsWithConfig(t, cfg)
	motion := provideRhythmMotion(root.s)
	server := httptest.NewServer(root.s.Router())
	t.Cleanup(server.Close)

	for _, tc := range []struct {
		name       string
		gap        time.Duration
		oldState   string
		newState   string
		wantStatus int
		unverified bool
	}{
		{name: "seamless", oldState: "expired", newState: "paid", wantStatus: 200},
		{name: "one_second_gap", gap: time.Second, oldState: "expired", newState: "paid", wantStatus: 403},
		{name: "refunded_predecessor", oldState: "refunded", newState: "paid", wantStatus: 403},
		{name: "pending_predecessor", oldState: "pending", newState: "paid", wantStatus: 403},
		{name: "unverified_expired_predecessor", oldState: "pending", newState: "paid", wantStatus: 403, unverified: true},
		{name: "refunded_current", oldState: "expired", newState: "refunded", wantStatus: 403},
		{name: "naturally_expired_current", oldState: "expired", newState: "expired", wantStatus: 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := motionHTTPFixture(t, root, server)
			user := f.user()
			var token app.GetPurchaseTokenResult
			f.call("POST", "purchases/token", user.AccessToken, nil, 200, &token)
			chain := uuid.NewString()
			signed := func(start, end time.Time) map[string]any {
				return testkit.TransactionSignedAt(token.AppAccountToken.String(), uuid.NewString(), chain, start, now, end)
			}
			notice := func(kind string, claims map[string]any) {
				f.call("POST", "payment-notifications/apple", "", map[string]string{
					"signedPayload": pki.Sign(t, testkit.NoticeAt(kind, uuid.NewString(), pki.Sign(t, claims), now)),
				}, 200, nil)
			}
			previous := signed(previousStart, cut)
			if tc.oldState == "pending" {
				f.exec(`with pending as (
					insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
					values($1,'wechat',$2,'fixture',1,'pending') returning id,user_id
				) insert into payment_facts(order_id,user_id,request_id,card_days)
				select id,user_id,$3,30 from pending`, user.UserId, []byte(uuid.NewString()), uuid.New())
			} else {
				f.call("POST", "purchases/restore", user.AccessToken,
					map[string]string{"signed_transaction": pki.Sign(t, previous)}, 200, nil)
			}
			start, end := cut.Add(tc.gap), currentEnd
			if tc.newState == "expired" {
				end = target.Add(time.Minute)
			}
			current := signed(start, end)
			if tc.oldState == "pending" {
				// With no prior Apple purchase there is no bound renewal chain yet.
				f.call("POST", "purchases/restore", user.AccessToken,
					map[string]string{"signed_transaction": pki.Sign(t, current)}, 200, nil)
			} else {
				notice("DID_RENEW", current)
			}
			refund := func(claims map[string]any) {
				claims["revocationDate"] = now.UnixMilli()
				notice("REFUND", claims)
			}
			if tc.oldState == "refunded" {
				refund(previous)
			}
			if tc.newState == "refunded" {
				refund(current)
			}

			checkRenewalProjection(f, user, tc.oldState, previousStart, cut)
			checkRenewalProjection(f, user, tc.newState, start, end)
			if tc.unverified {
				// An entitlement with no payment fact cannot supply historical coverage.
				f.exec(`with unverified as (
					insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
					values($1,'apple',$2,'fixture',1,'expired') returning id,user_id
				) insert into entitlements(order_id,user_id,starts_at,ends_at)
				select id,user_id,$3,$4 from unverified`,
					user.UserId, []byte(uuid.NewString()), previousStart, cut)
			}
			var rights app.Entitlements
			f.call("GET", "entitlements", user.AccessToken, nil, 200, &rights)
			if tc.newState == "paid" {
				if rights.Tier != "member" || rights.ExpiresAt == nil || !rights.ExpiresAt.Equal(end) {
					t.Fatalf("unexpected current membership: %+v", rights)
				}
			} else if rights.Tier != "free" || rights.ExpiresAt != nil {
				t.Fatalf("inactive membership still grants rights: %+v", rights)
			}

			seedMotionVoiceHistory(f, user, target)
			f.must(f.s.Data.Access(f.ctx, user.UserId, func(tx pgx.Tx) error {
				return f.s.Emotion.Upload(f.ctx, tx, user.UserId, synthetic(target, "voice", true), now)
			}))
			key := syntheticMotionKey{user.UserId, target}
			motion[key] = syntheticRhythmMotion(f, user.UserId, target, 0)
			event := motionEvent(target)
			delta := 0
			if tc.wantStatus == 200 {
				delta = 1
				unknown := motion[key]
				unknown.Exercise = nil
				motion[key] = unknown
				checkMotionReport(f, server, user, event, 400, 0)
				motion[key] = syntheticRhythmMotion(f, user.UserId, target, 0)
			}
			checkMotionReport(f, server, user, event, tc.wantStatus, delta)
			f.call("POST", "signal-windows", user.AccessToken, synthetic(earliest, "voice", false), tc.wantStatus, nil)
			var uploaded int
			f.must(f.s.db.QueryRow(f.ctx, `select count(*) from signal_windows
				where user_id=$1 and channel='voice' and starts_at=$2`, user.UserId, earliest).Scan(&uploaded))
			f.Logf("PG backfill rows=%d at %s", uploaded, earliest)
			if uploaded != delta {
				t.Fatalf("backfill committed %d rows, want %d", uploaded, delta)
			}
			f.call("GET", "signal-baselines?for_window="+url.QueryEscape(earliest.Format(time.RFC3339)),
				user.AccessToken, nil, tc.wantStatus, nil)
			if delta == 1 {
				delete(motion, key)
				checkMotionReport(f, server, user, event, 200, 0)
				f.call("PUT", "me/consents/health", user.AccessToken, map[string]any{"version": "v1", "granted": false}, 200, nil)
				checkMotionReport(f, server, user, event, 200, 0)
			}
		})
	}
}

func checkRenewalProjection(f *signalFixture, user app.Tokens, state string, start, end time.Time) {
	f.Helper()
	var count int
	f.must(f.s.db.QueryRow(f.ctx, `select count(*) from orders o
		join payment_facts p on p.order_id=o.id
		left join entitlements e on e.order_id=o.id
		where o.user_id=$1 and o.state=$2 and (
			($2='pending' and p.paid_at is null and p.refunded_at is null and e.order_id is null)
			or ($2='refunded' and p.paid_at=$3 and p.refunded_at is not null and e.order_id is null)
			or ($2 in ('paid','expired') and p.paid_at=$3 and p.refunded_at is null and e.starts_at=$3 and e.ends_at=$4)
		)`, user.UserId, state, start, end).Scan(&count))
	if count != 1 {
		f.Fatalf("payment projection state=%s interval=[%s,%s) matches=%d, want 1", state, start, end, count)
	}
	f.Logf("PG payment projection state=%s fixture_interval=[%s,%s) matches=%d", state, start, end, count)
}
