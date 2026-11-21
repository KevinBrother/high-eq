package payments

import (
	"context"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Only a verified response may provide the prepay ID passed to the phone.
type PrepayRequest struct {
	Body                        []byte
	Timestamp, Nonce, Signature string
}
type PrepayFunc func(context.Context, PrepayRequest) (string, error)

const prepayPath = "/v3/pay/transactions/app"

func (p PrepayRequest) signingInput() string {
	return "POST\n" + prepayPath + "\n" + p.Timestamp + "\n" + p.Nonce + "\n" + string(p.Body) + "\n"
}
func (c *AndroidChannel) prepay(ctx context.Context, order, product string, fen int, at time.Time) (string, error) {
	body, e := json.Marshal(map[string]any{"appid": c.App, "mchid": c.Merchant, "description": cardDescription(product), "out_trade_no": order, "notify_url": c.NotifyBase + "/v1/payment-notifications/wechat", "amount": map[string]any{"total": fen, "currency": "CNY"}})
	if e != nil {
		return "", e
	}
	req := PrepayRequest{Body: body, Timestamp: strconv.FormatInt(at.Unix(), 10), Nonce: strings.ReplaceAll(uuid.NewString(), "-", "")}
	req.Signature, e = signed(c.MerchantKey, req.signingInput())
	if e != nil {
		return "", e
	}
	id, e := c.Prepay(ctx, req)
	if e != nil {
		return "", e
	}
	if id == "" || len(id) > 128 {
		return "", ErrEvidence
	}
	return id, nil
}
