// Package testkit generates short-lived, synthetic platform material in memory.
// It is imported only by tests. Never load credentials from the filesystem.
package testkit

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"testing"
	"time"
)

type PKI struct {
	Pool  *x509.CertPool
	Chain []string
	key   *ecdsa.PrivateKey
}

func Chain(t testing.TB, at time.Time) *PKI {
	t.Helper()
	p := &PKI{Pool: x509.NewCertPool()}
	var parent *x509.Certificate
	var signer *ecdsa.PrivateKey
	for i := 1; i <= 3; i++ {
		k, e := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if e != nil {
			t.Fatal(e)
		}
		c := &x509.Certificate{SerialNumber: big.NewInt(int64(i)), Subject: pkix.Name{CommonName: "synthetic"}, NotBefore: at.Add(-time.Hour), NotAfter: at.Add(time.Hour), BasicConstraintsValid: true, IsCA: i < 3, KeyUsage: x509.KeyUsageDigitalSignature}
		if i < 3 {
			c.KeyUsage |= x509.KeyUsageCertSign
		}
		if i > 1 {
			oid := asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
			if i == 3 {
				oid = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
			}
			c.ExtraExtensions = []pkix.Extension{{Id: oid, Value: []byte{5, 0}}}
		}
		if i == 1 {
			parent = c
			signer = k
		}
		b, e := x509.CreateCertificate(rand.Reader, c, parent, k.Public(), signer)
		if e != nil {
			t.Fatal(e)
		}
		parent, e = x509.ParseCertificate(b)
		if e != nil {
			t.Fatal(e)
		}
		if i == 1 {
			p.Pool.AddCert(parent)
		}
		signer = k
		p.Chain = append([]string{base64.StdEncoding.EncodeToString(b)}, p.Chain...)
	}
	p.key = signer
	return p
}
func (p *PKI) Sign(t testing.TB, claims any) string {
	t.Helper()
	enc := func(x any) string {
		b, e := json.Marshal(x)
		if e != nil {
			t.Fatal(e)
		}
		return base64.RawURLEncoding.EncodeToString(b)
	}
	data := enc(map[string]any{"alg": "ES256", "x5c": p.Chain}) + "." + enc(claims)
	hash := sha256.Sum256([]byte(data))
	r, s, e := ecdsa.Sign(rand.Reader, p.key, hash[:])
	if e != nil {
		t.Fatal(e)
	}
	b := make([]byte, 64)
	r.FillBytes(b[:32])
	s.FillBytes(b[32:])
	return data + "." + base64.RawURLEncoding.EncodeToString(b)
}
func Transaction(token, tx, chain string, at, end time.Time) map[string]any {
	return TransactionSignedAt(token, tx, chain, at, at, end)
}
func TransactionSignedAt(token, tx, chain string, purchasedAt, signedAt, end time.Time) map[string]any {
	return map[string]any{"bundleId": "test.bundle", "environment": "Sandbox", "productId": "test.month", "type": "Auto-Renewable Subscription", "inAppOwnershipType": "PURCHASED", "appAccountToken": token, "transactionId": tx, "originalTransactionId": chain, "purchaseDate": purchasedAt.UnixMilli(), "signedDate": signedAt.UnixMilli(), "expiresDate": end.UnixMilli(), "price": 12000, "currency": "CNY"}
}
func Notice(kind, id, jws string) map[string]any {
	return NoticeAt(kind, id, jws, time.Now())
}
func NoticeAt(kind, id, jws string, at time.Time) map[string]any {
	return map[string]any{"version": "2.0", "notificationType": kind, "notificationUUID": id, "signedDate": at.UnixMilli(), "data": map[string]any{"bundleId": "test.bundle", "environment": "Sandbox", "signedTransactionInfo": jws}}
}
