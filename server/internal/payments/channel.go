package payments

import (
	"errors"
	"time"

	"github.com/google/uuid"
)

var (
	ErrGateway  = errors.New("payment provider unavailable")
	ErrClosed   = errors.New("payment channel disabled")
	ErrEvidence = errors.New("invalid payment evidence")
	ErrOwner    = errors.New("purchase owner conflict")
	ErrOrder    = errors.New("order mismatch")
	ErrPaid     = errors.New("order already paid")
)

// Evidence is only constructed by a verified channel, never bound from client JSON.
type evidence struct {
	platform, product, transaction, chain, notification string
	order, token                                        uuid.UUID
	amount                                              int
	start, end, refund                                  time.Time
}
type Product struct {
	SKU       string
	Fen, Days int
}
type Catalog map[string]Product

func (c Catalog) product(name string) (Product, error) {
	p := c[name]
	if (name != "monthly" && name != "yearly") || p.Fen <= 0 || p.Days <= 0 || p.Days > 366 {
		return Product{}, ErrOrder
	}
	return p, nil
}
