package payments

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"time"
)

const wechatOrigin = "https://api.mch.weixin.qq.com"

var authToken = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// The production endpoint is not an application setting. No caller-controlled
// URL, redirect, ambient proxy or insecure TLS mode can redirect signed orders.
func (c *AndroidChannel) connectWechat(merchantSerial string) error {
	if !c.ready("wechat") || !authToken.MatchString(merchantSerial) || !authToken.MatchString(c.Merchant) || !authToken.MatchString(c.Serial) {
		return ErrClosed
	}
	client := wechatClient()
	c.Prepay = c.gateway(client, merchantSerial, time.Now)
	return nil
}

func (c *AndroidChannel) gateway(client *http.Client, merchantSerial string, now func() time.Time) PrepayFunc {
	return func(ctx context.Context, p PrepayRequest) (string, error) {
		req, e := http.NewRequestWithContext(ctx, http.MethodPost, wechatOrigin+prepayPath, bytes.NewReader(p.Body))
		if e != nil {
			return "", ErrClosed
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json")
		req.Header.Set("Wechatpay-Serial", c.Serial)
		req.Header.Set("Authorization", fmt.Sprintf(`WECHATPAY2-SHA256-RSA2048 mchid="%s",nonce_str="%s",timestamp="%s",serial_no="%s",signature="%s"`, c.Merchant, p.Nonce, p.Timestamp, merchantSerial, p.Signature))
		res, e := client.Do(req)
		if e != nil {
			return "", ErrGateway
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK {
			return "", ErrGateway
		}
		const limit = 16 << 10
		b, e := io.ReadAll(io.LimitReader(res.Body, limit+1))
		if e != nil || len(b) > limit {
			return "", ErrGateway
		}
		one := func(k string) string {
			v := res.Header.Values("Wechatpay-" + k)
			if len(v) != 1 {
				return ""
			}
			return v[0]
		}
		h := WechatHeaders{one("Serial"), one("Timestamp"), one("Nonce"), one("Signature")}
		if !c.validWechat(h, b, now()) {
			return "", ErrGateway
		}
		var out struct {
			ID string `json:"prepay_id"`
		}
		if json.Unmarshal(b, &out) != nil || !authToken.MatchString(out.ID) {
			return "", ErrGateway
		}
		return out.ID, nil
	}
}

func wechatClient() *http.Client {
	transport := &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, MaxIdleConnsPerHost: 8, IdleConnTimeout: 60 * time.Second}
	return &http.Client{Transport: transport, Timeout: 8 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }}
}
