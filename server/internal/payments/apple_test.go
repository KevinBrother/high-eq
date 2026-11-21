package payments

import (
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/payments/testkit"
)

func TestSignedStoreKitAndNotification(t *testing.T) {
	now := time.Now().UTC()
	p := testkit.Chain(t, now)
	a := Apple{Roots: p.Pool, Bundle: "test.bundle", Products: Catalog{"monthly": {SKU: "test.month"}}, Environment: "Sandbox"}
	token := uuid.NewString()
	// The signer certificate expires after one hour, but this annual purchase
	// remains active. Recovery after certificate expiry must not discard it.
	claims := testkit.Transaction(token, "10", "1", now, now.Add(24*time.Hour))
	raw := p.Sign(t, claims)
	v, e := a.transaction(raw, now)
	if e != nil || v.token.String() != token || v.amount != 1200 {
		t.Fatal(v, e)
	}
	other := testkit.Chain(t, now)
	bad := other.Sign(t, claims)
	for _, j := range []string{"not.a.transaction", bad, strings.Replace(raw, ".", ".A", 1)} {
		if _, e := a.transaction(j, now); e == nil {
			t.Fatal("accepted invalid chain or signature")
		}
	}
	recoveredAt := now.Add(2 * time.Hour)
	if v, e = a.transaction(raw, recoveredAt); e != nil || !v.end.After(recoveredAt) {
		t.Fatal("active subscription signed before certificate expiry was rejected", v, e)
	}
	claims["signedDate"] = now.Add(2 * time.Hour).UnixMilli()
	if _, e := a.transaction(p.Sign(t, claims), now.Add(3*time.Hour)); e == nil {
		t.Fatal("accepted signature after certificate expiry")
	}
	claims["signedDate"] = now.UnixMilli()
	future := testkit.Transaction(token, "11", "1", now, now.Add(24*time.Hour))
	future["signedDate"] = now.Add(6 * time.Minute).UnixMilli()
	if _, e := a.transaction(p.Sign(t, future), now); e == nil {
		t.Fatal("accepted signedDate beyond the clock-skew allowance")
	}
	future["signedDate"] = int64(0)
	if _, e := a.transaction(p.Sign(t, future), now); e == nil {
		t.Fatal("accepted missing signedDate")
	}
	for key, value := range map[string]any{"environment": "Production", "productId": "unknown", "bundleId": "other", "appAccountToken": "", "type": "Consumable", "inAppOwnershipType": "FAMILY_SHARED", "isUpgraded": true} {
		old := claims[key]
		claims[key] = value
		if _, e := a.transaction(p.Sign(t, claims), now); e == nil {
			t.Fatal(key)
		}
		delete(claims, key)
		if old != nil {
			claims[key] = old
		}
	}
	n := testkit.NoticeAt("DID_RENEW", uuid.NewString(), raw, now)
	if _, e = a.notification(p.Sign(t, n), now.Add(2*time.Hour)); e != nil {
		t.Fatal("historical notification rejected after certificate expiry", e)
	}
	n = testkit.NoticeAt("DID_RENEW", uuid.NewString(), raw, now.Add(2*time.Hour))
	if _, e = a.notification(p.Sign(t, n), now.Add(3*time.Hour)); e == nil {
		t.Fatal("accepted outer signedDate after certificate expiry")
	}
	n = testkit.Notice("DID_RENEW", uuid.NewString(), bad)
	if _, e = a.notification(p.Sign(t, n), now); e == nil {
		t.Fatal("unverified nested transaction")
	}
	n = testkit.Notice("REFUND", uuid.NewString(), raw)
	if _, e = a.notification(p.Sign(t, n), now); e == nil {
		t.Fatal("refund without revocation")
	}
	claims["revocationDate"] = now.UnixMilli()
	n = testkit.Notice("REFUND", uuid.NewString(), p.Sign(t, claims))
	if v, e = a.notification(p.Sign(t, n), now); e != nil || v.refund.IsZero() {
		t.Fatal(v, e)
	}
	if _, e = (*Apple)(nil).transaction(raw, now); e != ErrClosed {
		t.Fatal(e)
	}
}

func TestSyntheticAppleTransactionSeparatesPurchaseAndSigningTime(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Millisecond)
	purchasedAt := now.Add(-24 * time.Hour)
	signedAt := now
	expiresAt := now.Add(24 * time.Hour)
	token := uuid.NewString()
	// The purchase and expiry are historical, but the JWS is signed while the
	// synthetic certificate chain is valid.
	claims := testkit.TransactionSignedAt(token, "13", "2", purchasedAt, signedAt, expiresAt)
	if got := claims["purchaseDate"]; got != purchasedAt.UnixMilli() {
		t.Fatalf("purchaseDate = %v, want %d", got, purchasedAt.UnixMilli())
	}
	if got := claims["signedDate"]; got != signedAt.UnixMilli() {
		t.Fatalf("signedDate = %v, want %d", got, signedAt.UnixMilli())
	}
	if got := claims["expiresDate"]; got != expiresAt.UnixMilli() {
		t.Fatalf("expiresDate = %v, want %d", got, expiresAt.UnixMilli())
	}
	p := testkit.Chain(t, now)
	a := Apple{Roots: p.Pool, Bundle: "test.bundle", Products: Catalog{"monthly": {SKU: "test.month"}}, Environment: "Sandbox"}
	if _, e := a.transaction(p.Sign(t, claims), now); e != nil {
		t.Fatalf("historical purchase signed now was rejected: %v", e)
	}

	renewalEnd := now.Add(72 * time.Hour)
	renewal := testkit.TransactionSignedAt(token, "14", "2", now, signedAt, renewalEnd)
	notice := testkit.NoticeAt("DID_RENEW", uuid.NewString(), p.Sign(t, renewal), signedAt)
	if got := notice["signedDate"]; got != signedAt.UnixMilli() {
		t.Fatalf("notice signedDate = %v, want %d", got, signedAt.UnixMilli())
	}
	if v, e := a.notification(p.Sign(t, notice), now); e != nil || !v.end.Equal(renewalEnd) {
		t.Fatalf("renewal notice = %+v, %v", v, e)
	}

	expired := testkit.TransactionSignedAt(token, "15", "2", now.Add(-48*time.Hour), signedAt, now.Add(-24*time.Hour))
	expiredRaw := p.Sign(t, expired)
	if v, e := a.transaction(expiredRaw, now); e != nil || !v.end.Before(now) {
		t.Fatalf("expired fact signed now = %+v, %v", v, e)
	}
	expiredNotice := p.Sign(t, testkit.NoticeAt("EXPIRED", uuid.NewString(), expiredRaw, signedAt))
	if v, e := a.notification(expiredNotice, now); e != nil || !v.end.Before(now) {
		t.Fatalf("expired notice = %+v, %v", v, e)
	}
}

func TestAppleAmountAndExpiredNotice(t *testing.T) {
	now := time.Now()
	p := testkit.Chain(t, now)
	a := Apple{Roots: p.Pool, Bundle: "test.bundle", Products: Catalog{"monthly": {SKU: "test.month"}}, Environment: "Sandbox"}
	c := testkit.Transaction(uuid.NewString(), "12", "1", now, now.Add(time.Hour))
	if _, e := a.notification(p.Sign(t, testkit.Notice("EXPIRED", uuid.NewString(), p.Sign(t, c))), now); e != ErrEvidence {
		t.Fatal("future expiry accepted", e)
	}
	delete(c, "price")
	if _, e := a.transaction(p.Sign(t, c), now); e != ErrEvidence {
		t.Fatal("absent price recorded as zero", e)
	}
}
