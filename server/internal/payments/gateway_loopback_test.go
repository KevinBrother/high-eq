package payments

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/payments/testkit"
)

type credentials struct {
	merchant, platform *rsa.PrivateKey
	env                map[string]string
}

func merchantFixture(t *testing.T) credentials {
	t.Helper()
	merchant, platform := testkit.RSA(t), testkit.RSA(t)
	pub, e := x509.MarshalPKIXPublicKey(&platform.PublicKey)
	if e != nil {
		t.Fatal(e)
	}
	m := map[string]string{"PAYMENT_MODE": "wechat,alipay", "PAYMENT_NOTIFY_BASE": "https://pay.example.test", "PAYMENT_MONTHLY_FEN": "1234", "PAYMENT_YEARLY_FEN": "8888", "PAYMENT_WECHAT_PLATFORM_KEY_ID": "PUB_KEY_ID_SYNTHETIC", "PAYMENT_WECHAT_MERCHANT_SERIAL": "FFA1", "PAYMENT_WECHAT_APIV3_KEY_BASE64": base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))}
	for _, p := range []string{"WECHAT", "ALIPAY"} {
		prefix := "PAYMENT_" + p + "_"
		m[prefix+"APP_ID"] = "fixture-app"
		m[prefix+"MERCHANT_ID"] = "fixture-merchant"
		m[prefix+"PLATFORM_PUBLIC_KEY_PEM"] = string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: pub}))
		m[prefix+"SIGNING_KEY_PEM"] = string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(merchant)}))
	}
	return credentials{merchant, platform, m}
}

// Real TLS, X.509 hostname verification, HTTP/1.1 parser and serialized wire
// bytes. Only net.Pipe is dialed; this runs where even bind(127.0.0.1) is banned.
func pipeTransport(t *testing.T, reply func(*http.Request) (int, http.Header, string)) *http.Transport {
	t.Helper()
	key := testkit.RSA(t)
	crt := &x509.Certificate{SerialNumber: big.NewInt(1), DNSNames: []string{"api.mch.weixin.qq.com"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, e := x509.CreateCertificate(rand.Reader, crt, crt, &key.PublicKey, key)
	if e != nil {
		t.Fatal(e)
	}
	cert, e := x509.ParseCertificate(der)
	if e != nil {
		t.Fatal(e)
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	return &http.Transport{DisableKeepAlives: true, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool}, DialContext: func(_ context.Context, _ string, addr string) (net.Conn, error) {
		if addr != "api.mch.weixin.qq.com:443" {
			return nil, fmt.Errorf("unexpected destination")
		}
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			b.SetDeadline(time.Now().Add(3 * time.Second))
			conn := tls.Server(b, &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}})
			r, e := http.ReadRequest(bufio.NewReader(conn))
			if e != nil {
				return
			}
			status, h, body := reply(r)
			w := http.Response{StatusCode: status, ProtoMajor: 1, ProtoMinor: 1, Header: h, ContentLength: int64(len(body)), Body: io.NopCloser(strings.NewReader(body)), Close: true}
			_ = w.Write(conn)
		}()
		return a, nil
	}}
}

func TestWechatGatewayOverLoopbackTLS(t *testing.T) {
	f := merchantFixture(t)
	ch, e := Configure(func(k string) string { return f.env[k] })
	if e != nil {
		t.Fatal(e)
	}
	c := ch.Android["wechat"]
	now := time.Unix(1750000000, 0)
	stamp := strconv.FormatInt(now.Unix(), 10)
	id := uuid.MustParse("12345678-1234-4123-8123-123456789abc")
	body := `{"appid":"fixture-app","mchid":"fixture-merchant","out_trade_no":"12345678123441238123123456789abc","notify_url":"https://pay.example.test/v1/payment-notifications/wechat","description":"yearly","amount":{"currency":"CNY","total":8888}}`
	req := PrepayRequest{Body: []byte(body), Timestamp: stamp, Nonce: "fixture-request"}
	req.Signature = testkit.Signature(t, f.merchant, "POST\n/v3/pay/transactions/app\n"+stamp+"\nfixture-request\n"+body+"\n")
	for _, scenario := range []string{"ok", "tamper", "key-id", "stale", "unsigned", "duplicate", "missing-id", "upstream-error", "redirect", "untrusted-tls"} {
		t.Run(scenario, func(t *testing.T) {
			client := wechatClient()
			client.Transport = pipeTransport(t, func(r *http.Request) (int, http.Header, string) {
				raw, e := io.ReadAll(r.Body)
				if e != nil || r.Method != "POST" || r.URL.RequestURI() != "/v3/pay/transactions/app" || r.Host != "api.mch.weixin.qq.com" || r.Header.Get("Wechatpay-Serial") != "PUB_KEY_ID_SYNTHETIC" || r.Header.Get("Content-Type") != "application/json" {
					t.Error("wrong request")
				}
				auth := r.Header.Get("Authorization")
				if !strings.HasPrefix(auth, "WECHATPAY2-SHA256-RSA2048 ") {
					t.Error("wrong scheme")
				}
				fields := map[string]string{}
				for _, kv := range regexp.MustCompile(`([a-z_]+)="([^"]*)"`).FindAllStringSubmatch(auth, -1) {
					fields[kv[1]] = kv[2]
				}
				if len(fields) != 5 || fields["mchid"] != "fixture-merchant" || fields["serial_no"] != "FFA1" || fields["timestamp"] != stamp || !valid(&f.merchant.PublicKey, "POST\n"+r.URL.RequestURI()+"\n"+fields["timestamp"]+"\n"+fields["nonce_str"]+"\n"+string(raw)+"\n", fields["signature"]) {
					t.Error("merchant signature mismatch")
				}
				var data struct {
					Notify string `json:"notify_url"`
					Order  string `json:"out_trade_no"`
					Amount struct{ Total int }
				}
				if json.Unmarshal(raw, &data) != nil || data.Notify != "https://pay.example.test/v1/payment-notifications/wechat" || data.Amount.Total != 8888 || data.Order != strings.ReplaceAll(id.String(), "-", "") {
					t.Error("wrong charge or callback")
				}
				b := `{ "prepay_id": "wx_synthetic" }`
				h := make(http.Header)
				ts := stamp
				serial := "PUB_KEY_ID_SYNTHETIC"
				if scenario == "stale" {
					ts = "1749999000"
				}
				if scenario == "key-id" {
					serial = "OTHER"
				}
				if scenario == "missing-id" {
					b = `{}`
				}
				h.Set("Wechatpay-Serial", serial)
				h.Set("Wechatpay-Timestamp", ts)
				h.Set("Wechatpay-Nonce", "fixture-response")
				h.Set("Wechatpay-Signature", testkit.Signature(t, f.platform, ts+"\nfixture-response\n"+b+"\n"))
				switch scenario {
				case "tamper":
					b += " "
				case "unsigned":
					h.Del("Wechatpay-Signature")
				case "duplicate":
					h.Add("Wechatpay-Serial", serial)
				case "redirect":
					h.Set("Location", "https://other.invalid/")
					return 307, h, b
				case "upstream-error":
					return 502, h, b
				}
				return 200, h, b
			})
			if scenario == "untrusted-tls" {
				client.Transport.(*http.Transport).TLSClientConfig.RootCAs = x509.NewCertPool()
			}
			c.Prepay = c.gateway(client, "FFA1", func() time.Time { return now })
			got, e := c.Prepay(context.Background(), req)
			if scenario == "ok" {
				if e != nil || got != "wx_synthetic" {
					t.Fatalf("unexpected result %q %v", got, e)
				}
				sdk, e := c.checkout(context.Background(), "wechat", id, "yearly", 8888, now)
				var p map[string]string
				if e != nil || json.Unmarshal([]byte(sdk), &p) != nil || !valid(&f.merchant.PublicKey, p["appid"]+"\n"+p["timestamp"]+"\n"+p["noncestr"]+"\nwx_synthetic\n", p["sign"]) {
					t.Fatal("unsuitable APP signature", e)
				}
			} else if e == nil || got != "" {
				t.Fatal("released unverified prepay_id")
			}
		})
	}
}

func TestConfiguredAlipayOrderAndCallback(t *testing.T) {
	f := merchantFixture(t)
	f.env["PAYMENT_MODE"] = "alipay"
	ch, e := Configure(func(k string) string { return f.env[k] })
	if e != nil {
		t.Fatal(e)
	}
	c := ch.Android["alipay"]
	id := uuid.New()
	now := time.Unix(1750000000, 0)
	order, e := c.checkout(context.Background(), "alipay", id, "monthly", ch.Products["monthly"].Fen, now)
	if e != nil {
		t.Fatal(e)
	}
	q, e := url.ParseQuery(order)
	sig := q.Get("sign")
	q.Del("sign")
	if e != nil || q.Get("notify_url") != "https://pay.example.test/v1/payment-notifications/alipay" || !valid(&f.merchant.PublicKey, canonical(q), sig) || !strings.Contains(q.Get("biz_content"), `"total_amount":"12.34"`) {
		t.Fatal("wrong signed order")
	}
	form := url.Values{"app_id": {c.App}, "seller_id": {c.Merchant}, "trade_status": {"TRADE_SUCCESS"}, "trade_no": {"synthetic"}, "notify_id": {"n1"}, "out_trade_no": {id.String()}, "total_amount": {"12.34"}, "gmt_payment": {now.In(shanghai).Format(time.DateTime)}}
	v, e := c.alipay(append(testkit.Ali(t, f.platform, form), []byte("&empty_optional=")...), now)
	if e != nil || v.amount != 1234 {
		t.Fatal(e)
	}
	if _, e = c.alipay(testkit.Ali(t, f.merchant, form), now); e == nil {
		t.Fatal("accepted merchant-signed callback")
	}
}
