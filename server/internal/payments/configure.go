package payments

import (
	"bytes"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"net/url"
	"strconv"
	"strings"
)

// Configure reads *only enabled* channels from a deployment secret injector.
// No file paths, fallback keys, HTTP endpoints or secrets in error messages.
func Configure(get func(string) string) (Channels, error) {
	var out Channels
	bad := func() (Channels, error) { return Channels{}, ErrClosed }
	mode := get("PAYMENT_MODE")
	if mode == "" || mode == "disabled" {
		return out, nil
	}
	out.Android = map[string]*AndroidChannel{}
	for _, mode := range strings.Split(mode, ",") {
		switch mode {
		case "apple-sandbox", "apple-production":
			if out.Apple != nil {
				return bad()
			}
			env := "Sandbox"
			if mode == "apple-production" {
				env = "Production"
			}
			roots, e := appleRoots(get("PAYMENT_APPLE_ROOT_CA_PEM"))
			if e != nil {
				return bad()
			}
			a := &Apple{Environment: env, Roots: roots, Bundle: get("PAYMENT_APPLE_BUNDLE"), Products: Catalog{"monthly": {SKU: get("PAYMENT_APPLE_MONTH_SKU")}, "yearly": {SKU: get("PAYMENT_APPLE_YEAR_SKU")}}}
			if env == "Production" {
				a.AppAppleID, e = strconv.ParseInt(get("PAYMENT_APPLE_ID"), 10, 64)
				if e != nil {
					return bad()
				}
			}
			if !a.configured() || a.Products["monthly"].SKU == "" || a.Products["yearly"].SKU == "" || a.Products["monthly"].SKU == a.Products["yearly"].SKU {
				return bad()
			}
			out.Apple = a
		case "wechat", "alipay":
			if out.Android[mode] != nil {
				return bad()
			}
			base, e := callbackBase(get("PAYMENT_NOTIFY_BASE"))
			if e != nil {
				return bad()
			}
			prefix := "PAYMENT_" + strings.ToUpper(mode) + "_"
			key, e := privateRSA(get(prefix + "SIGNING_KEY_PEM"))
			if e != nil {
				return bad()
			}
			pub, e := platformRSA(get(prefix + "PLATFORM_PUBLIC_KEY_PEM"))
			if e != nil || key.PublicKey.Equal(pub) {
				return bad()
			}
			c := &AndroidChannel{NotifyBase: base, App: get(prefix + "APP_ID"), Merchant: get(prefix + "MERCHANT_ID"), MerchantKey: key, PlatformKey: pub}
			if mode == "wechat" {
				c.Serial = get(prefix + "PLATFORM_KEY_ID")
				c.APIv3Key, e = base64.StdEncoding.DecodeString(get(prefix + "APIV3_KEY_BASE64"))
				if e != nil || c.connectWechat(get(prefix+"MERCHANT_SERIAL")) != nil {
					return bad()
				}
			}
			if !c.ready(mode) {
				return bad()
			}
			out.Android[mode] = c
		default:
			return bad()
		}
	}
	if len(out.Android) > 0 {
		out.Products = Catalog{}
		for plan, days := range map[string]int{"monthly": 30, "yearly": 365} {
			fen, e := strconv.Atoi(get("PAYMENT_" + strings.ToUpper(plan) + "_FEN"))
			if e != nil || fen <= 0 || fen > 999999999 {
				return bad()
			}
			out.Products[plan] = Product{Fen: fen, Days: days}
		}
	}
	return out, nil
}

func callbackBase(raw string) (string, error) {
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || strings.Contains(raw, "#") || (u.Path != "" && u.Path != "/") {
		return "", ErrClosed
	}
	return "https://" + u.Host, nil
}
func single(raw string) (*pem.Block, error) {
	s := strings.TrimSpace(raw)
	if !strings.HasPrefix(s, "-----BEGIN ") {
		return nil, ErrClosed
	}
	b, rest := pem.Decode([]byte(s))
	if b == nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, ErrClosed
	}
	return b, nil
}
func privateRSA(raw string) (*rsa.PrivateKey, error) {
	b, e := single(raw)
	if e != nil {
		return nil, e
	}
	var key *rsa.PrivateKey
	switch b.Type {
	case "RSA PRIVATE KEY":
		key, e = x509.ParsePKCS1PrivateKey(b.Bytes)
	case "PRIVATE KEY":
		var anyKey any
		anyKey, e = x509.ParsePKCS8PrivateKey(b.Bytes)
		key, _ = anyKey.(*rsa.PrivateKey)
	default:
		return nil, ErrClosed
	}
	if e != nil || key == nil || key.N.BitLen() != 2048 || key.Validate() != nil {
		return nil, ErrClosed
	}
	return key, nil
}
func platformRSA(raw string) (*rsa.PublicKey, error) {
	b, e := single(raw)
	if e != nil || b.Type != "PUBLIC KEY" {
		return nil, ErrClosed
	}
	v, e := x509.ParsePKIXPublicKey(b.Bytes)
	k, ok := v.(*rsa.PublicKey)
	if e != nil || !ok || k.N.BitLen() != 2048 {
		return nil, ErrClosed
	}
	return k, nil
}
func appleRoots(raw string) (*x509.CertPool, error) {
	data := bytes.TrimSpace([]byte(raw))
	if len(data) == 0 {
		return nil, ErrClosed
	}
	pool := x509.NewCertPool()
	for len(data) > 0 {
		b, rest := pem.Decode(data)
		if b == nil || b.Type != "CERTIFICATE" {
			return nil, ErrClosed
		}
		crt, e := x509.ParseCertificate(b.Bytes)
		if e != nil || !crt.IsCA || crt.CheckSignatureFrom(crt) != nil {
			return nil, ErrClosed
		}
		pool.AddCert(crt)
		data = bytes.TrimSpace(rest)
	}
	return pool, nil
}
