package payments

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/payments/testkit"
)

func TestAndroidWire(t *testing.T) {
	now := time.Now().Truncate(time.Second)
	id := uuid.New()
	platform := testkit.RSA(t)
	merchant := testkit.RSA(t)
	c := AndroidChannel{"test-app", "test-mch", "synthetic", &platform.PublicKey, merchant, []byte("0123456789abcdef0123456789abcdef"), func(_ context.Context, r PrepayRequest) (string, error) {
		if !valid(&merchant.PublicKey, r.signingInput(), r.Signature) {
			return "", ErrEvidence
		}
		return "fixture-prepay", nil
	}, "https://merchant.invalid"}
	for _, ch := range []string{"alipay", "wechat"} {
		p, e := c.checkout(context.Background(), ch, id, "monthly", 1201, now)
		if e != nil {
			t.Fatal(e)
		}
		if ch == "wechat" {
			var f map[string]string
			if json.Unmarshal([]byte(p), &f) != nil || f["package"] != "Sign=WXPay" || !valid(&merchant.PublicKey, f["appid"]+"\n"+f["timestamp"]+"\n"+f["noncestr"]+"\n"+f["prepayid"]+"\n", f["sign"]) {
				t.Fatal("bad APP arguments")
			}
		} else {
			f, e := url.ParseQuery(p)
			sig := f.Get("sign")
			f.Del("sign")
			if e != nil || f.Get("method") != "alipay.trade.app.pay" || !valid(&merchant.PublicKey, canonical(f), sig) {
				t.Fatal("bad order string")
			}
		}
	}
	r := map[string]any{"mchid": c.Merchant, "appid": c.App, "trade_state": "SUCCESS", "trade_type": "APP", "out_trade_no": id.String(), "transaction_id": "wx-tx", "success_time": now, "amount": map[string]any{"currency": "CNY", "total": 1201}}
	wx := func(kind string) ([]byte, WechatHeaders) {
		b, h := testkit.Wx(t, platform, c.APIv3Key, kind, uuid.NewString(), r, now)
		return b, WechatHeaders{h["Wechatpay-Serial"], h["Wechatpay-Timestamp"], h["Wechatpay-Nonce"], h["Wechatpay-Signature"]}
	}
	b, h := wx("TRANSACTION.SUCCESS")
	if v, e := c.wechat(h, b, now); e != nil || v.order != id || v.amount != 1201 {
		t.Fatal(v, e)
	}
	if _, e := c.wechat(h, append(b, ' '), now); e == nil {
		t.Fatal("raw bytes not verified")
	}
	if _, e := c.wechat(h, b, now.Add(6*time.Minute)); e == nil {
		t.Fatal("stale header")
	}
	r["appid"] = "other"
	b, h = wx("TRANSACTION.SUCCESS")
	if _, e := c.wechat(h, b, now); e == nil {
		t.Fatal("wrong app")
	}
	delete(r, "appid")
	r["refund_status"] = "SUCCESS"
	r["amount"] = map[string]any{"refund": 1201, "total": 1201}
	b, h = wx("REFUND.SUCCESS")
	if v, e := c.wechat(h, b, now); e != nil || v.refund.IsZero() {
		t.Fatal(v, e)
	}
	f := url.Values{"app_id": {c.App}, "seller_id": {c.Merchant}, "trade_status": {"TRADE_SUCCESS"}, "notify_id": {"notice"}, "trade_no": {"ali-tx"}, "out_trade_no": {id.String()}, "total_amount": {"12.01"}, "gmt_payment": {now.In(shanghai).Format(time.DateTime)}, "extra": {"a+b&é"}}
	raw := testkit.Ali(t, platform, f)
	if v, e := c.alipay(raw, now); e != nil || v.amount != 1201 || v.order != id {
		t.Fatal(v, e)
	}
	for _, b := range [][]byte{append(append([]byte{}, raw...), []byte("&seller_id=other")...), testkit.Ali(t, merchant, f)} {
		if _, e := c.alipay(b, now); e == nil {
			t.Fatal("invalid form accepted")
		}
	}
	f.Set("gmt_refund", f.Get("gmt_payment"))
	f.Set("refund_fee", "12.01")
	if v, e := c.alipay(testkit.Ali(t, platform, f), now); e != nil || v.refund.IsZero() {
		t.Fatal(v, e)
	}
	f.Set("refund_fee", "1.10")
	if _, e := c.alipay(testkit.Ali(t, platform, f), now); e == nil {
		t.Fatal("partial refund credited")
	}
	if _, e := (*AndroidChannel)(nil).checkout(context.Background(), "wechat", id, "monthly", 1, now); e != ErrClosed {
		t.Fatal(e)
	}
}

func TestPrepayUsesCatalogAmountAndRequiresChannel(t *testing.T) {
	k := testkit.RSA(t)
	p := testkit.RSA(t)
	c := AndroidChannel{NotifyBase: "https://merchant.invalid", App: "a", Merchant: "m", Serial: "synthetic", MerchantKey: k, PlatformKey: &p.PublicKey, APIv3Key: make([]byte, 32)}
	id := uuid.New()
	if _, e := c.checkout(context.Background(), "wechat", id, "yearly", 8800, time.Now()); e != ErrClosed {
		t.Fatal(e)
	}
	called := false
	c.Prepay = func(_ context.Context, r PrepayRequest) (string, error) {
		called = true
		var b struct {
			Merchant string `json:"mchid"`
			Amount   struct {
				Total    int
				Currency string
			}
		}
		if json.Unmarshal(r.Body, &b) != nil || b.Merchant != "m" || b.Amount.Total != 8800 || b.Amount.Currency != "CNY" || !valid(&k.PublicKey, r.signingInput(), r.Signature) {
			t.Fatal("invalid prepay")
		}
		return "", ErrClosed
	}
	if _, e := c.checkout(context.Background(), "wechat", id, "yearly", 8800, time.Now()); !called || e != ErrClosed {
		t.Fatal("did not propagate channel refusal", e)
	}
}

type checkoutRow struct{ state string }

func (r checkoutRow) Scan(dst ...any) error {
	*dst[0].(*string) = "wechat"
	*dst[1].(*string) = "monthly"
	*dst[2].(*int) = 1200
	*dst[3].(*string) = r.state
	*dst[4].(*[]byte) = nil
	*dst[5].(**time.Time) = nil
	return nil
}

type checkoutTx struct {
	pgx.Tx
	state string
}

func (t checkoutTx) QueryRow(context.Context, string, ...any) pgx.Row { return checkoutRow{t.state} }

func TestCheckoutPaidRetryIsActionable(t *testing.T) {
	s := &Service{}
	for _, state := range []string{"paid", "expired"} {
		if _, e := s.Checkout(context.Background(), checkoutTx{state: state}, uuid.New(), uuid.New()); !errors.Is(e, ErrPaid) {
			t.Fatalf("%s retry was not actionable: %v", state, e)
		}
	}
	if _, e := s.Checkout(context.Background(), checkoutTx{state: "refunded"}, uuid.New(), uuid.New()); !errors.Is(e, ErrOrder) {
		t.Fatalf("refunded order was not rejected as an order mismatch: %v", e)
	}
}
