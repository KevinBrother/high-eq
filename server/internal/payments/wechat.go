package payments

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"strconv"
	"time"

	"github.com/google/uuid"
)

type WechatHeaders struct{ Serial, Timestamp, Nonce, Signature string }

func (c *AndroidChannel) wechat(h WechatHeaders, raw []byte, now time.Time) (v evidence, err error) {
	if !c.ready("wechat") {
		return v, ErrClosed
	}
	if !c.validWechat(h, raw, now) {
		return v, ErrEvidence
	}
	var n struct {
		ID       string
		Event    string `json:"event_type"`
		Resource struct {
			Algorithm, Ciphertext, Nonce string
			AAD                          string `json:"associated_data"`
		}
	}
	if json.Unmarshal(raw, &n) != nil || n.ID == "" || n.Resource.Algorithm != "AEAD_AES_256_GCM" {
		return v, ErrEvidence
	}
	block, e := aes.NewCipher(c.APIv3Key)
	if e != nil {
		return v, ErrClosed
	}
	g, e := cipher.NewGCM(block)
	if e != nil {
		return v, e
	}
	ct, e := base64.StdEncoding.DecodeString(n.Resource.Ciphertext)
	if e != nil || len(n.Resource.Nonce) != g.NonceSize() {
		return v, ErrEvidence
	}
	plain, e := g.Open(nil, []byte(n.Resource.Nonce), ct, []byte(n.Resource.AAD))
	if e != nil {
		return v, ErrEvidence
	}
	var r struct {
		Mchid, Appid string
		Trade        string    `json:"trade_state"`
		Kind         string    `json:"trade_type"`
		Refund       string    `json:"refund_status"`
		Order        string    `json:"out_trade_no"`
		Tx           string    `json:"transaction_id"`
		Success      time.Time `json:"success_time"`
		Amount       struct {
			Currency      string
			Total, Refund int
		}
	}
	if json.Unmarshal(plain, &r) != nil || r.Mchid != c.Merchant || r.Tx == "" || r.Success.IsZero() || r.Success.After(now.Add(5*time.Minute)) || r.Amount.Total <= 0 {
		return v, ErrEvidence
	}
	v.order, e = uuid.Parse(r.Order)
	if e != nil || v.order == uuid.Nil {
		return v, ErrEvidence
	}
	switch n.Event {
	case "TRANSACTION.SUCCESS":
		if r.Kind != "APP" || r.Appid != c.App || r.Trade != "SUCCESS" || r.Amount.Currency != "CNY" {
			return v, ErrEvidence
		}
		v.start = r.Success
	case "REFUND.SUCCESS":
		if r.Refund != "SUCCESS" || r.Amount.Total != r.Amount.Refund || (r.Appid != "" && r.Appid != c.App) || (r.Amount.Currency != "" && r.Amount.Currency != "CNY") {
			return v, ErrEvidence
		}
		v.refund = r.Success
	default:
		return v, ErrEvidence
	}
	v.amount = r.Amount.Total
	v.transaction = r.Tx
	v.notification = n.ID
	v.platform = "wechat"
	return v, nil
}

func (c *AndroidChannel) validWechat(h WechatHeaders, raw []byte, now time.Time) bool {
	sec, e := strconv.ParseInt(h.Timestamp, 10, 64)
	return e == nil && sec >= now.Unix()-300 && sec <= now.Unix()+300 && h.Serial == c.Serial && h.Nonce != "" && valid(c.PlatformKey, h.Timestamp+"\n"+h.Nonce+"\n"+string(raw)+"\n", h.Signature)
}
