package payments

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
)

type Channels struct {
	Apple    *Apple
	Android  map[string]*AndroidChannel
	Products Catalog
}
type Service struct {
	db       *pgxpool.Pool
	data     *privacy.Coordinator
	key      []byte
	channels Channels
	now      func() time.Time
	fields   *fieldcrypt.Cipher
}

func New(db *pgxpool.Pool, data *privacy.Coordinator, master []byte, channels Channels) (*Service, error) {
	if len(master) < 32 {
		return nil, ErrClosed
	}
	h := hmac.New(sha256.New, master)
	h.Write([]byte("high-eq/payments/v1"))
	key := h.Sum(nil)
	enc := hmac.New(sha256.New, key)
	enc.Write([]byte("checkout-cache"))
	fields, e := fieldcrypt.New(1, map[uint32][]byte{1: enc.Sum(nil)})
	if e != nil {
		return nil, e
	}
	return &Service{db, data, key, channels, time.Now, fields}, nil
}
func (s *Service) mac(parts ...string) []byte {
	h := hmac.New(sha256.New, s.key)
	for _, p := range parts {
		h.Write(binary.BigEndian.AppendUint64(nil, uint64(len(p))))
		h.Write([]byte(p))
	}
	return h.Sum(nil)
}

// AppleReady gates T17's pre-purchase token, not only the later signed proof.
func (s *Service) AppleReady() bool {
	if s == nil {
		return false
	}
	a := s.channels.Apple
	return a.configured() && a.Products["monthly"].SKU != "" && a.Products["yearly"].SKU != "" && a.Products["monthly"].SKU != a.Products["yearly"].SKU
}
func Token(ctx context.Context, tx pgx.Tx, user uuid.UUID) (id uuid.UUID, e error) {
	e = tx.QueryRow(ctx, "select app_account_token from users where id=$1", user).Scan(&id)
	return
}

type Order struct {
	ID      uuid.UUID `json:"order_id"`
	Payload string    `json:"payment_payload"`
}

func (s *Service) Reserve(ctx context.Context, tx pgx.Tx, user, req uuid.UUID, platform, product string) (Order, error) {
	var out Order
	if req == uuid.Nil || (platform != "wechat" && platform != "alipay") || (product != "monthly" && product != "yearly") {
		return out, ErrOrder
	}
	c := s.channels.Android[platform]
	if !c.ready(platform) {
		return out, ErrClosed
	}
	var ch, sku string
	var fen int
	e := tx.QueryRow(ctx, `select o.id,platform,product_code,amount_fen from orders o join payment_facts f on o.id=f.order_id where f.user_id=$1 and request_id=$2`, user, req).Scan(&out.ID, &ch, &sku, &fen)
	switch {
	case e == nil:
		if platform != ch || product != sku {
			return out, ErrOrder
		}
	case errors.Is(e, pgx.ErrNoRows):
		p, e := s.channels.Products.product(product)
		if e != nil {
			return out, e
		}
		fen = p.Fen
		out.ID = uuid.New()
		_, e = tx.Exec(ctx, `insert into orders(id,user_id,platform,product_code,amount_fen,transaction_hmac,state) values($1,$2,$3,$4,$5,$6,'pending')`, out.ID, user, platform, product, fen, s.mac("order", out.ID.String()))
		if e != nil {
			return out, e
		}
		_, e = tx.Exec(ctx, `insert into payment_facts(order_id,user_id,request_id,card_days) values($1,$2,$3,$4)`, out.ID, user, req, p.Days)
		if e != nil {
			return out, e
		}
	default:
		return out, e
	}
	return out, nil
}
func (s *Service) Restore(ctx context.Context, tx pgx.Tx, user uuid.UUID, raw string) error {
	v, e := s.channels.Apple.transaction(raw, s.now())
	if e != nil {
		return e
	}
	return s.apply(ctx, tx, user, v)
}
func (s *Service) AppleNotice(ctx context.Context, raw string) error {
	v, e := s.channels.Apple.notification(raw, s.now())
	if e != nil {
		return e
	}
	return s.notify(ctx, v)
}
func (s *Service) WechatNotice(ctx context.Context, h WechatHeaders, raw []byte) error {
	v, e := s.channels.Android["wechat"].wechat(h, raw, s.now())
	if e != nil {
		return e
	}
	return s.notify(ctx, v)
}
func (s *Service) AlipayNotice(ctx context.Context, raw []byte) error {
	v, e := s.channels.Android["alipay"].alipay(raw, s.now())
	if e != nil {
		return e
	}
	return s.notify(ctx, v)
}
func (s *Service) notify(ctx context.Context, v evidence) error {
	var user uuid.UUID
	var e error
	if v.platform == "apple" {
		e = s.db.QueryRow(ctx, "select id from users where app_account_token=$1", v.token).Scan(&user)
	} else {
		e = s.db.QueryRow(ctx, "select user_id from payment_facts where order_id=$1", v.order).Scan(&user)
	}
	if errors.Is(e, pgx.ErrNoRows) {
		return ErrOrder
	}
	if e != nil {
		return e
	}
	return pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if e := s.data.GuardTx(ctx, tx, user); e != nil {
			return e
		}
		var due bool
		if e := tx.QueryRow(ctx, `select coalesce(closure_requested_at <= clock_timestamp()-interval '360 hours', false) from users where id=$1`, user).Scan(&due); e != nil {
			return e
		}
		if due {
			return privacy.ErrHidden
		}
		return s.apply(ctx, tx, user, v)
	})
}

// Idempotence and projection share the account lock AND the same SQL transaction.
func (s *Service) apply(ctx context.Context, tx pgx.Tx, user uuid.UUID, v evidence) error {
	if v.platform == "apple" {
		id, e := Token(ctx, tx, user)
		if e != nil {
			return e
		}
		if id != v.token {
			return ErrOwner
		}
	}
	if v.notification != "" {
		k := s.mac("notice", v.platform, v.notification)
		stamp := func(t time.Time) string { return t.UTC().Format(time.RFC3339Nano) }
		digest := s.mac("facts", user.String(), v.order.String(), v.transaction, v.chain, v.product, strconv.Itoa(v.amount), stamp(v.start), stamp(v.end), stamp(v.refund))
		tag, e := tx.Exec(ctx, `insert into payment_notices(notice_hmac,evidence_hmac,user_id) values($1,$2,$3) on conflict do nothing`, k, digest, user)
		if e != nil {
			return e
		}
		if tag.RowsAffected() == 0 {
			var got []byte
			e = tx.QueryRow(ctx, `select evidence_hmac from payment_notices where notice_hmac=$1`, k).Scan(&got)
			if e != nil {
				return e
			}
			if !hmac.Equal(got, digest) {
				return ErrEvidence
			}
			return nil
		}
	}
	var e error
	if v.platform == "apple" {
		v.order, e = s.appleOrder(ctx, tx, user, v)
		if e != nil {
			return e
		}
	}
	if e := s.settle(ctx, tx, user, v); e != nil {
		return e
	}
	return rebuild(ctx, tx, user, s.now())
}
func nullTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}
func (s *Service) appleOrder(ctx context.Context, tx pgx.Tx, user uuid.UUID, v evidence) (id uuid.UUID, err error) {
	// On conflict never overwrite the stored owner, even if the order is anonymized.
	var owner *uuid.UUID
	var sku string
	fp := s.mac("provider", "apple", v.transaction)
	e := tx.QueryRow(ctx, `insert into orders(user_id,platform,product_code,amount_fen,transaction_hmac,state) values($1,'apple',$2,$3,$4,'pending') on conflict(platform,transaction_hmac) do update set transaction_hmac=excluded.transaction_hmac returning id,user_id,product_code`, user, v.product, v.amount, fp).Scan(&id, &owner, &sku)
	if e != nil {
		return id, e
	}
	if owner == nil || *owner != user {
		return id, ErrOwner
	}
	if sku != v.product {
		return id, ErrOrder
	}
	chain := s.mac("apple-chain", v.chain)
	_, e = tx.Exec(ctx, `insert into apple_purchase_chains values($1,$2) on conflict do nothing`, chain, id)
	if e != nil {
		return id, e
	}
	e = tx.QueryRow(ctx, `select user_id from orders o join apple_purchase_chains c on o.id=c.first_order_id where chain_hmac=$1`, chain).Scan(&owner)
	if e != nil {
		return id, e
	}
	if owner == nil || *owner != user {
		return id, ErrOwner
	}
	tag, e := tx.Exec(ctx, `insert into payment_facts(order_id,user_id,card_days,apple_chain_hmac) values($1,$2,0,$3)
             on conflict(order_id) do update set apple_chain_hmac=excluded.apple_chain_hmac
             where payment_facts.apple_chain_hmac=excluded.apple_chain_hmac`, id, user, chain)
	if e == nil && tag.RowsAffected() != 1 {
		return id, ErrOrder
	}
	return id, e
}
