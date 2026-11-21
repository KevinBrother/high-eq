package payments

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Trust anchors come from the operator, never from x5c.
type Apple struct {
	Roots       *x509.CertPool
	Bundle      string
	Products    Catalog
	Environment string
	AppAppleID  int64
}

var leafOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
var caOID = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}

func marker(c *x509.Certificate, id asn1.ObjectIdentifier) bool {
	for _, x := range c.Extensions {
		if x.Id.Equal(id) {
			return true
		}
	}
	return false
}
func (a *Apple) open(raw string, dst any, now time.Time) error {
	if !a.configured() {
		return ErrClosed
	}
	p := strings.Split(raw, ".")
	if len(p) != 3 || len(raw) > 96<<10 {
		return ErrEvidence
	}
	dec := base64.RawURLEncoding.DecodeString
	h, e := dec(p[0])
	var hdr struct {
		Alg  string
		X5c  []string
		Crit []string
	}
	if e != nil || json.Unmarshal(h, &hdr) != nil || hdr.Alg != "ES256" || len(hdr.Crit) != 0 || len(hdr.X5c) != 3 {
		return ErrEvidence
	}
	body, e := dec(p[1])
	if e != nil {
		return ErrEvidence
	}
	var payload struct {
		SignedDate int64 `json:"signedDate"`
	}
	if json.Unmarshal(body, &payload) != nil || payload.SignedDate <= 0 || payload.SignedDate > now.Add(5*time.Minute).UnixMilli() {
		return ErrEvidence
	}
	var chain []*x509.Certificate
	for _, enc := range hdr.X5c {
		b, e := base64.StdEncoding.DecodeString(enc)
		if e != nil {
			return ErrEvidence
		}
		cert, e := x509.ParseCertificate(b)
		if e != nil {
			return ErrEvidence
		}
		chain = append(chain, cert)
	}
	leaf, inter := chain[0], chain[1]
	pool := x509.NewCertPool()
	pool.AddCert(inter)
	paths, e := leaf.Verify(x509.VerifyOptions{Roots: a.Roots, Intermediates: pool, CurrentTime: time.UnixMilli(payload.SignedDate).UTC(), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageAny}})
	if e != nil || !marker(leaf, leafOID) || !marker(inter, caOID) || leaf.IsCA || leaf.KeyUsage&x509.KeyUsageDigitalSignature == 0 {
		return ErrEvidence
	}
	trusted := false
	for _, path := range paths {
		if len(path) == 3 && path[1].Equal(inter) && path[2].Equal(chain[2]) {
			trusted = true
		}
	}
	if !trusted {
		return ErrEvidence
	}
	key, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	sig, e := dec(p[2])
	sum := sha256.Sum256([]byte(p[0] + "." + p[1]))
	if !ok || key.Curve != elliptic.P256() || e != nil || len(sig) != 64 || !ecdsa.Verify(key, sum[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return ErrEvidence
	}
	if e != nil || json.Unmarshal(body, dst) != nil {
		return ErrEvidence
	}
	return nil
}
func (a *Apple) transaction(raw string, now time.Time) (v evidence, err error) {
	var t struct {
		BundleId, Environment, ProductId, TransactionId, OriginalTransactionId, AppAccountToken, Type, InAppOwnershipType, Currency string
		PurchaseDate, ExpiresDate, SignedDate, RevocationDate                                                                       int64
		Price                                                                                                                       *int64
		IsUpgraded                                                                                                                  bool
	}
	if err = a.open(raw, &t, now); err != nil {
		return
	}
	token, e := uuid.Parse(t.AppAccountToken)
	if e != nil || token == uuid.Nil || t.BundleId != a.Bundle || t.Environment != a.Environment || t.Type != "Auto-Renewable Subscription" || t.InAppOwnershipType != "PURCHASED" || t.IsUpgraded || t.TransactionId == "" || t.OriginalTransactionId == "" || t.PurchaseDate <= 0 || t.ExpiresDate <= t.PurchaseDate || t.SignedDate < t.PurchaseDate || t.SignedDate > now.Add(5*time.Minute).UnixMilli() || t.RevocationDate < 0 || (t.RevocationDate != 0 && (t.RevocationDate < t.PurchaseDate || t.RevocationDate > t.SignedDate)) {
		return v, ErrEvidence
	}
	for name, p := range a.Products {
		if p.SKU != "" && p.SKU == t.ProductId {
			if v.product != "" {
				return evidence{}, ErrEvidence
			}
			v.product = name
		}
	}
	if v.product == "" {
		return v, ErrEvidence
	}
	v.platform = "apple"
	v.transaction = t.TransactionId
	v.chain = t.OriginalTransactionId
	v.token = token
	v.start = time.UnixMilli(t.PurchaseDate).UTC()
	v.end = time.UnixMilli(t.ExpiresDate).UTC()
	if t.RevocationDate != 0 {
		v.refund = time.UnixMilli(t.RevocationDate).UTC()
	}
	if t.Price == nil || *t.Price < 0 || *t.Price > 21474836470 || t.Currency != "CNY" || *t.Price%10 != 0 {
		return v, ErrEvidence
	}
	v.amount = int(*t.Price / 10)
	return v, nil
}
func (a *Apple) notification(raw string, now time.Time) (evidence, error) {
	var n struct {
		NotificationType, NotificationUUID, Version string
		Data                                        struct {
			BundleId, Environment, SignedTransactionInfo string
			AppAppleId                                   int64
		}
	}
	if e := a.open(raw, &n, now); e != nil {
		return evidence{}, e
	}
	id, e := uuid.Parse(n.NotificationUUID)
	if e != nil || id == uuid.Nil || n.Version != "2.0" || n.Data.BundleId != a.Bundle || n.Data.Environment != a.Environment || (a.Environment == "Production" && n.Data.AppAppleId != a.AppAppleID) {
		return evidence{}, ErrEvidence
	}
	v, e := a.transaction(n.Data.SignedTransactionInfo, now)
	if e != nil {
		return v, e
	}
	switch n.NotificationType {
	case "SUBSCRIBED", "DID_RENEW", "DID_CHANGE_RENEWAL_STATUS", "DID_FAIL_TO_RENEW":
	case "EXPIRED":
		if v.end.After(now) {
			return v, ErrEvidence
		}
	case "REFUND", "REVOKE":
		if v.refund.IsZero() {
			return v, ErrEvidence
		}
	default:
		return v, ErrEvidence
	}
	v.notification = id.String()
	return v, nil
}

func (a *Apple) configured() bool {
	return a != nil && a.Roots != nil && a.Bundle != "" && (a.Environment == "Sandbox" || (a.Environment == "Production" && a.AppAppleID > 0))
}
