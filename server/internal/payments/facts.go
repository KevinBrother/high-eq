package payments

import (
	"context"
	"crypto/hmac"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// A refund may arrive before the payment. Fill missing verified facts once;
// later deliveries cannot replace the transaction or erase its revocation.
type receipt struct {
	key                []byte
	start, end, refund time.Time
}

func (f *receipt) merge(key []byte, v evidence) error {
	next := *f
	if next.key != nil && !hmac.Equal(next.key, key) {
		return ErrOrder
	}
	next.key = key
	for _, x := range []struct {
		dst *time.Time
		src time.Time
	}{{&next.start, v.start}, {&next.end, v.end}, {&next.refund, v.refund}} {
		if x.src.IsZero() {
			continue
		}
		src := x.src.Truncate(time.Microsecond)
		if !x.dst.IsZero() && !x.dst.Equal(src) {
			return ErrOrder
		}
		*x.dst = src
	}
	if !next.start.IsZero() && !next.refund.IsZero() && next.refund.Before(next.start) {
		return ErrOrder
	}
	*f = next
	return nil
}
func (s *Service) settle(ctx context.Context, tx pgx.Tx, user uuid.UUID, v evidence) error {
	var f receipt
	var start, end, refund *time.Time
	e := tx.QueryRow(ctx, `select f.provider_hmac,f.paid_at,f.apple_until,f.refunded_at
 from payment_facts f join orders o on o.id=f.order_id
 where f.order_id=$1 and f.user_id=$2 and o.platform=$3 and o.amount_fen=$4`, v.order, user, v.platform, v.amount).Scan(&f.key, &start, &end, &refund)
	if errors.Is(e, pgx.ErrNoRows) {
		return ErrOrder
	}
	if e != nil {
		return e
	}
	if start != nil {
		f.start = *start
	}
	if end != nil {
		f.end = *end
	}
	if refund != nil {
		f.refund = *refund
	}
	if e = f.merge(s.mac("provider", v.platform, v.transaction), v); e != nil {
		return e
	}
	_, e = tx.Exec(ctx, `update payment_facts set checkout_enc=null,checkout_expires_at=null,provider_hmac=$2,paid_at=$3,apple_until=$4,refunded_at=$5 where order_id=$1`, v.order, f.key, nullTime(f.start), nullTime(f.end), nullTime(f.refund))
	var pe *pgconn.PgError
	if errors.As(e, &pe) && pe.Code == "23505" {
		return ErrOrder
	}
	return e
}
