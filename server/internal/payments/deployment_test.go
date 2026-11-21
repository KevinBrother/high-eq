package payments

import (
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/payments/testkit"
)

func TestProductionNotificationRequiresAppAppleID(t *testing.T) {
	now := time.Now()
	chain := testkit.Chain(t, now)
	a := Apple{Roots: chain.Pool, Bundle: "test.bundle", Products: Catalog{"monthly": {SKU: "test.month"}}, Environment: "Production", AppAppleID: 123}
	claims := testkit.Transaction(uuid.NewString(), "tx", "orig", now, now.Add(time.Hour))
	claims["environment"] = "Production"
	n := testkit.Notice("SUBSCRIBED", uuid.NewString(), chain.Sign(t, claims))
	d := n["data"].(map[string]any)
	d["environment"] = "Production"
	for _, id := range []int{0, 124, 123} {
		d["appAppleId"] = id
		_, e := a.notification(chain.Sign(t, n), now)
		if (e == nil) != (id == 123) {
			t.Fatalf("id %d: %v", id, e)
		}
	}
	d["environment"] = "Sandbox"
	if _, e := a.notification(chain.Sign(t, n), now); e == nil {
		t.Fatal("cross-environment notification")
	}
	claims["environment"] = "Sandbox"
	if _, e := a.transaction(chain.Sign(t, claims), now); e == nil {
		t.Fatal("cross-environment restore")
	}
}

// Frozen public-only vector: generated once with an ephemeral RSA key. No
// private fixture and no call to a signing helper can mask canonicalization drift.
func TestFixedWechatResponseVector(t *testing.T) {
	var f struct {
		Key       string `json:"public_key"`
		Signature string
	}
	if json.Unmarshal(publicVector, &f) != nil {
		t.Fatal("fixture")
	}
	pub, e := platformRSA(f.Key)
	if e != nil {
		t.Fatal(e)
	}
	c := AndroidChannel{Serial: "PUB_KEY_ID_FIXTURE", PlatformKey: pub}
	raw := []byte(`{"prepay_id":"wx_fixture"}`)
	h := WechatHeaders{c.Serial, "1750000000", "fixture-response", f.Signature}
	if !c.validWechat(h, raw, time.Unix(1750000000, 0)) || c.validWechat(h, append(raw, '\n'), time.Unix(1750000000, 0)) {
		t.Fatal("canonical response bytes")
	}
}

//go:embed testdata/wechat_response.json
var publicVector []byte

func TestChannelConfigurationRejectsIncompleteCredentials(t *testing.T) {
	for _, mode := range []string{"", "disabled"} {
		out, e := Configure(func(k string) string {
			if k != "PAYMENT_MODE" {
				t.Fatal("disabled config requested material")
			}
			return mode
		})
		if e != nil || out.Apple != nil || len(out.Android) != 0 {
			t.Fatal(e)
		}
	}
	f := merchantFixture(t)
	for k, v := range map[string]string{"PAYMENT_WECHAT_APIV3_KEY_BASE64": "AA==", "PAYMENT_WECHAT_MERCHANT_SERIAL": "\"", "PAYMENT_WECHAT_PLATFORM_KEY_ID": "", "PAYMENT_WECHAT_SIGNING_KEY_PEM": "no key", "PAYMENT_ALIPAY_PLATFORM_PUBLIC_KEY_PEM": "", "PAYMENT_MONTHLY_FEN": "0", "PAYMENT_MODE": "alipay,unknown", "PAYMENT_ALIPAY_MERCHANT_ID": ""} {
		out, e := Configure(func(key string) string {
			if key == k {
				return v
			}
			return f.env[key]
		})
		if e == nil || out.Apple != nil || len(out.Android) != 0 {
			t.Fatal(k)
		}
	}
	for _, raw := range []string{"http://merchant.example", "https://a:b@merchant.example", "https://merchant.example/?next=x", "https://merchant.example/wrong", "https://merchant.example/#fragment"} {
		if _, e := callbackBase(raw); e == nil {
			t.Fatal(raw)
		}
	}
}

func TestAppleDeploymentEnvironment(t *testing.T) {
	chain := testkit.Chain(t, time.Now())
	der, e := base64.StdEncoding.DecodeString(chain.Chain[2])
	if e != nil {
		t.Fatal(e)
	}
	env := map[string]string{"PAYMENT_MODE": "apple-production", "PAYMENT_APPLE_BUNDLE": "test.bundle", "PAYMENT_APPLE_MONTH_SKU": "test.month", "PAYMENT_APPLE_YEAR_SKU": "test.year", "PAYMENT_APPLE_ROOT_CA_PEM": string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))}
	load := func() (Channels, error) { return Configure(func(k string) string { return env[k] }) }
	if _, e := load(); e == nil {
		t.Fatal("missing production app ID")
	}
	env["PAYMENT_APPLE_ID"] = "101"
	out, e := load()
	if e != nil || out.Apple.Environment != "Production" || out.Apple.AppAppleID != 101 {
		t.Fatal(e)
	}
	env["PAYMENT_MODE"] = "apple-sandbox"
	delete(env, "PAYMENT_APPLE_ID")
	out, e = load()
	if e != nil || out.Apple.Environment != "Sandbox" {
		t.Fatal(e)
	}
	env["PAYMENT_MODE"] = "apple-sandbox,apple-production"
	if _, e = load(); e == nil {
		t.Fatal("mixed environments")
	}
}
