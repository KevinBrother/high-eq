package payments

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Called under the account lock *after* Reserve has committed. Concurrent
// retries share a short-lived encrypted payload; the provider timeout bounds
// lock duration. Cache expiry never changes the merchant order number.
func (s *Service) Checkout(ctx context.Context, tx pgx.Tx, user, id uuid.UUID) (string, error) {
	var platform, product, state string
	var fen int
	var enc []byte
	var expires *time.Time
	e := tx.QueryRow(ctx, `select platform,product_code,amount_fen,state,checkout_enc,checkout_expires_at from orders o join payment_facts f on o.id=f.order_id where o.id=$1 and o.user_id=$2`, id, user).Scan(&platform, &product, &fen, &state, &enc, &expires)
	if e != nil {
		return "", e
	}
	switch state {
	case "pending":
	case "paid", "expired":
		return "", ErrPaid
	default:
		return "", ErrOrder
	}
	c := s.channels.Android[platform]
	if !c.ready(platform) {
		return "", ErrClosed
	}
	now := s.now()
	aad := []byte("payment_facts.checkout_enc/" + user.String() + "/" + id.String())
	if expires != nil && now.Before(*expires) {
		b, e := s.fields.Open(enc, aad)
		return string(b), e
	}
	payload, e := c.checkout(ctx, platform, id, product, fen, now)
	if e != nil {
		return "", e
	}
	enc, e = s.fields.Seal([]byte(payload), aad)
	if e != nil {
		return "", e
	}
	_, e = tx.Exec(ctx, "update payment_facts set checkout_enc=$2,checkout_expires_at=$3 where order_id=$1", id, enc, now.Add(5*time.Minute))
	return payload, e
}
