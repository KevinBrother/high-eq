package payments

import (
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

var decimal = regexp.MustCompile(`^(0|[1-9][0-9]{0,6})(\.[0-9]{1,2})?$`)

func cents(raw string) (int, error) {
	if !decimal.MatchString(raw) {
		return 0, ErrEvidence
	}
	whole, frac, _ := strings.Cut(raw, ".")
	a, _ := strconv.Atoi(whole)
	b, _ := strconv.Atoi((frac + "00")[:2])
	return a*100 + b, nil
}
func (c *AndroidChannel) alipay(raw []byte, now time.Time) (v evidence, err error) {
	if !c.ready("alipay") {
		return v, ErrClosed
	}
	f, e := url.ParseQuery(string(raw))
	if e != nil {
		return v, ErrEvidence
	}
	for k, vs := range f {
		if k == "" || len(vs) != 1 {
			return v, ErrEvidence
		}
	}
	sig := f.Get("sign")
	if f.Get("sign_type") != "RSA2" {
		return v, ErrEvidence
	}
	f.Del("sign")
	f.Del("sign_type")
	if !valid(c.PlatformKey, canonical(f), sig) || f.Get("app_id") != c.App || f.Get("seller_id") != c.Merchant || f.Get("notify_id") == "" || f.Get("trade_no") == "" {
		return v, ErrEvidence
	}
	v.order, e = uuid.Parse(f.Get("out_trade_no"))
	if e != nil || v.order == uuid.Nil {
		return v, ErrEvidence
	}
	v.amount, e = cents(f.Get("total_amount"))
	if e != nil || v.amount <= 0 {
		return v, ErrEvidence
	}
	status := f.Get("trade_status")
	stamp := f.Get("gmt_payment")
	refund := f.Get("refund_fee") != "" || f.Get("gmt_refund") != ""
	if refund {
		amt, e := cents(f.Get("refund_fee"))
		if e != nil || amt != v.amount || (status != "TRADE_CLOSED" && status != "TRADE_SUCCESS") {
			return v, ErrEvidence
		}
		stamp = f.Get("gmt_refund")
	} else if status != "TRADE_SUCCESS" && status != "TRADE_FINISHED" {
		return v, ErrEvidence
	}
	at, e := time.ParseInLocation(time.DateTime, stamp, shanghai)
	if e != nil || at.After(now.Add(5*time.Minute)) {
		return v, ErrEvidence
	}
	if refund {
		v.refund = at
	} else {
		v.start = at
	}
	v.platform = "alipay"
	v.notification = f.Get("notify_id")
	v.transaction = f.Get("trade_no")
	return v, nil
}
