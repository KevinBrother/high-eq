package service

import (
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/payments"
)

func paymentError(c *gin.Context, e error) {
	switch {
	case errors.Is(e, payments.ErrOwner):
		problem(c, 409, "conflict", "此交易属于其他账号。请验证并切换原购买账号，当前账号权益不会改变。", false)
	case errors.Is(e, payments.ErrPaid):
		problem(c, 409, "conflict", "该订单已支付或已结束，请刷新会员权益；如需再次购买请新建订单", false)
	case errors.Is(e, payments.ErrEvidence), errors.Is(e, payments.ErrOrder):
		problem(c, 400, "invalid_argument", "未能核验交易或订单，请核对支付信息", false)
	case errors.Is(e, payments.ErrGateway):
		problem(c, 500, "internal_error", "暂未取得可验证的支付参数，请重试原订单或刷新会员状态。", true)
	case errors.Is(e, payments.ErrClosed):
		problem(c, 500, "internal_error", "支付渠道尚未开放，暂不能核验或开通会员", false)
	default:
		accountError(c, e)
	}
}
func (a appAPI) GetPurchaseToken(c *gin.Context) {
	if !a.payments.AppleReady() {
		paymentError(c, payments.ErrClosed)
		return
	}
	var out app.GetPurchaseTokenResult
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		var e error
		out.AppAccountToken, e = payments.Token(c.Request.Context(), tx, principal(c).User)
		return e
	})
	if e != nil {
		paymentError(c, e)
		return
	}
	c.JSON(200, out)
}
func (a appAPI) CreateOrder(c *gin.Context) {
	var in app.CreateOrderInput
	if !input(c, &in) {
		return
	}
	var out payments.Order
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		var e error
		out, e = a.payments.Reserve(c.Request.Context(), tx, principal(c).User, in.RequestId, string(in.Platform), string(in.Product))
		return e
	})
	// Commit the pending order before crossing the network. Even on an ambiguous
	// timeout a retry reuses the exact same merchant out_trade_no.
	if e == nil {
		e = a.withRights(c, "", func(tx pgx.Tx) error {
			var err error
			out.Payload, err = a.payments.Checkout(c.Request.Context(), tx, principal(c).User, out.ID)
			return err
		})
	}

	if e != nil {
		paymentError(c, e)
		return
	}
	c.JSON(200, out)
}
func (a appAPI) RestorePurchase(c *gin.Context) {
	var in app.RestorePurchaseInput
	if !input(c, &in) {
		return
	}
	ctx := c.Request.Context()
	u := principal(c).User
	var out app.Entitlements
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		if e := a.payments.Restore(ctx, tx, u, in.SignedTransaction); e != nil {
			return e
		}
		var e error
		out, e = a.membership.Entitlements(ctx, tx, u)
		return e
	})
	if e != nil {
		paymentError(c, e)
		return
	}
	c.JSON(200, out)
}
func noticeError(c *gin.Context, e error) {
	if errors.Is(e, payments.ErrOwner) {
		e = payments.ErrEvidence
	}
	paymentError(c, e)
}
func (a appAPI) ReceiveAppleNotification(c *gin.Context) {
	b, ok := rawPayment(c, "application/json")
	if !ok {
		return
	}
	var in app.ReceiveAppleNotificationInput
	if json.Unmarshal(b, &in) != nil || in.SignedPayload == "" {
		noticeError(c, payments.ErrEvidence)
		return
	}
	if e := a.payments.AppleNotice(c.Request.Context(), in.SignedPayload); e != nil {
		noticeError(c, e)
		return
	}
	c.JSON(200, ack)
}
func rawPayment(c *gin.Context, content string) ([]byte, bool) {
	media, _, e := mime.ParseMediaType(c.GetHeader("Content-Type"))
	if e != nil || media != content {
		paymentError(c, payments.ErrEvidence)
		return nil, false
	}
	b, e := io.ReadAll(http.MaxBytesReader(c.Writer, c.Request.Body, 96<<10))
	if e != nil {
		paymentError(c, payments.ErrEvidence)
		return nil, false
	}
	return b, true
}
func (a appAPI) ReceiveWechatNotification(c *gin.Context, p app.ReceiveWechatNotificationParams) {
	b, ok := rawPayment(c, "application/json")
	if !ok {
		return
	}
	h := payments.WechatHeaders{Serial: p.WechatpaySerial, Nonce: p.WechatpayNonce, Signature: p.WechatpaySignature, Timestamp: p.WechatpayTimestamp}
	if e := a.payments.WechatNotice(c.Request.Context(), h, b); e != nil {
		noticeError(c, e)
		return
	}
	c.Status(200)
}
func (a appAPI) ReceiveAlipayNotification(c *gin.Context) {
	b, ok := rawPayment(c, "application/x-www-form-urlencoded")
	if !ok {
		return
	}
	if e := a.payments.AlipayNotice(c.Request.Context(), b); e != nil {
		noticeError(c, e)
		return
	}
	c.String(200, "success")
}
