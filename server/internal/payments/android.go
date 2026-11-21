package payments

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Merchant signing material and independently pinned platform verification key.
type AndroidChannel struct {
	App, Merchant, Serial string
	PlatformKey           *rsa.PublicKey
	MerchantKey           *rsa.PrivateKey
	APIv3Key              []byte
	Prepay                PrepayFunc
	NotifyBase            string
}

func (c *AndroidChannel) ready(platform string) bool {
	return c != nil && c.NotifyBase != "" && c.App != "" && c.Merchant != "" && c.PlatformKey != nil && c.PlatformKey.Size() >= 256 && c.MerchantKey != nil && c.MerchantKey.Size() >= 256 && ((platform == "wechat" && c.Serial != "" && len(c.APIv3Key) == 32) || platform == "alipay")
}
func signed(k *rsa.PrivateKey, msg string) (string, error) {
	sum := sha256.Sum256([]byte(msg))
	s, e := rsa.SignPKCS1v15(rand.Reader, k, crypto.SHA256, sum[:])
	return base64.StdEncoding.EncodeToString(s), e
}
func valid(k *rsa.PublicKey, msg, sig string) bool {
	s, e := base64.StdEncoding.DecodeString(sig)
	sum := sha256.Sum256([]byte(msg))
	return e == nil && rsa.VerifyPKCS1v15(k, crypto.SHA256, sum[:], s) == nil
}
func canonical(v url.Values) string {
	var keys []string
	for k := range v {
		if v.Get(k) == "" {
			continue
		}
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var fields []string
	for _, k := range keys {
		fields = append(fields, k+"="+v.Get(k))
	}
	return strings.Join(fields, "&")
}

var shanghai = time.FixedZone("CST", 8*3600)

func (c *AndroidChannel) checkout(ctx context.Context, platform string, id uuid.UUID, product string, fen int, at time.Time) (string, error) {
	if !c.ready(platform) {
		return "", ErrClosed
	}
	order := strings.ReplaceAll(id.String(), "-", "")
	if platform == "wechat" {
		if c.Prepay == nil {
			return "", ErrClosed
		}
		prepay, e := c.prepay(ctx, order, product, fen, at)
		if e != nil {
			return "", e
		}
		stamp := strconv.FormatInt(at.Unix(), 10)
		nonce := strings.ReplaceAll(uuid.NewString(), "-", "")
		sig, e := signed(c.MerchantKey, c.App+"\n"+stamp+"\n"+nonce+"\n"+prepay+"\n")
		if e != nil {
			return "", e
		}
		b, e := json.Marshal(map[string]string{"appid": c.App, "partnerid": c.Merchant, "prepayid": prepay, "package": "Sign=WXPay", "noncestr": nonce, "timestamp": stamp, "sign": sig})
		return string(b), e
	}
	biz, _ := json.Marshal(map[string]string{"out_trade_no": order, "product_code": "QUICK_MSECURITY_PAY", "total_amount": strconv.Itoa(fen/100) + "." + two(fen%100), "subject": cardDescription(product)})
	v := url.Values{}
	for k, x := range map[string]string{"app_id": c.App, "method": "alipay.trade.app.pay", "notify_url": c.NotifyBase + "/v1/payment-notifications/alipay", "charset": "utf-8", "format": "JSON", "sign_type": "RSA2", "version": "1.0", "timestamp": at.In(shanghai).Format(time.DateTime), "biz_content": string(biz)} {
		v.Set(k, x)
	}
	sig, e := signed(c.MerchantKey, canonical(v))
	v.Set("sign", sig)
	return v.Encode(), e
}
func two(n int) string { return strconv.Itoa(100 + n)[1:] }

func cardDescription(product string) string {
	if product == "yearly" {
		return "高情商会员年卡"
	}
	return "高情商会员月卡"
}
