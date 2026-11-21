package service

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/payments"
)

func TestPaymentPaidRetryMapsToConflict(t *testing.T) {
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	paymentError(c, payments.ErrPaid)
	if w.Code != 409 || !strings.Contains(w.Body.String(), `"code":"conflict"`) || !strings.Contains(w.Body.String(), "已支付") || !strings.Contains(w.Body.String(), "已结束") {
		t.Fatalf("paid retry response was not actionable: %d %s", w.Code, w.Body.String())
	}
}

func TestPaymentCredentialsFailClosed(t *testing.T) {
	t.Setenv("APP_ENV", "development")
	for _, mode := range []string{"production", "apple-sandbox"} {
		t.Setenv("PAYMENT_MODE", mode)
		t.Setenv("PAYMENT_APPLE_ROOT_CA_PEM", "")
		if _, e := paymentChannels(); e == nil {
			t.Fatal("accepted incomplete credentials")
		}
	}
	t.Setenv("PAYMENT_MODE", "")
	channels, e := paymentChannels()
	if e != nil {
		t.Fatal(e)
	}
	pay, e := payments.New(nil, nil, make([]byte, 32), channels)
	if e != nil {
		t.Fatal(e)
	}
	r := gin.New()
	app.RegisterHandlers(r, appAPI{payments: pay})
	// T17 obtains this token *before* it can launch StoreKit. Disabled
	// verification must stop the purchase, not just fail on the later restore.
	w := httptest.NewRecorder()
	r.ServeHTTP(w, httptest.NewRequest("POST", "/v1/purchases/token", nil))
	if w.Code != 500 || strings.Contains(w.Body.String(), "app_account_token") {
		t.Fatal("disabled StoreKit preflight")
	}
	for _, tc := range []struct{ path, media, body string }{{"apple", "application/json", `{"signedPayload":"untrusted"}`}, {"wechat", "application/json", `{}`}, {"alipay", "application/x-www-form-urlencoded", "sign_type=RSA2"}} {
		req := httptest.NewRequest("POST", "/v1/payment-notifications/"+tc.path, strings.NewReader(tc.body))
		req.Header.Set("Content-Type", tc.media)
		for _, h := range []string{"Nonce", "Signature", "Serial", "Timestamp"} {
			req.Header.Set("Wechatpay-"+h, "synthetic")
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != 500 || !strings.Contains(w.Body.String(), "internal_error") {
			t.Fatalf("disabled %s: %d %s", tc.path, w.Code, w.Body.String())
		}
	}
}
