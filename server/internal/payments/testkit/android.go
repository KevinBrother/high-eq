package testkit

import (
	"crypto"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func RSA(t testing.TB) *rsa.PrivateKey {
	t.Helper()
	k, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	return k
}
func Signature(t testing.TB, k *rsa.PrivateKey, msg string) string {
	sum := sha256.Sum256([]byte(msg))
	b, e := rsa.SignPKCS1v15(rand.Reader, k, crypto.SHA256, sum[:])
	if e != nil {
		t.Fatal(e)
	}
	return base64.StdEncoding.EncodeToString(b)
}
func Ali(t testing.TB, k *rsa.PrivateKey, f url.Values) []byte {
	var parts []string
	for key := range f {
		if key != "sign" && key != "sign_type" {
			parts = append(parts, key+"="+f.Get(key))
		}
	}
	sort.Strings(parts)
	f.Set("sign_type", "RSA2")
	f.Set("sign", Signature(t, k, strings.Join(parts, "&")))
	return []byte(f.Encode())
}
func Wx(t testing.TB, k *rsa.PrivateKey, key []byte, event, id string, resource any, now time.Time) ([]byte, map[string]string) {
	block, e := aes.NewCipher(key)
	if e != nil {
		t.Fatal(e)
	}
	g, e := cipher.NewGCM(block)
	if e != nil {
		t.Fatal(e)
	}
	nonce := uuid.NewString()[:12]
	plain, e := json.Marshal(resource)
	if e != nil {
		t.Fatal(e)
	}
	ct := g.Seal(nil, []byte(nonce), plain, []byte("metadata"))
	raw, e := json.Marshal(map[string]any{"id": id, "event_type": event, "resource": map[string]any{"algorithm": "AEAD_AES_256_GCM", "nonce": nonce, "associated_data": "metadata", "ciphertext": base64.StdEncoding.EncodeToString(ct)}})
	if e != nil {
		t.Fatal(e)
	}
	ts := strconv.FormatInt(now.Unix(), 10)
	return raw, map[string]string{"Wechatpay-Serial": "synthetic", "Wechatpay-Timestamp": ts, "Wechatpay-Nonce": nonce, "Wechatpay-Signature": Signature(t, k, ts+"\n"+nonce+"\n"+string(raw)+"\n")}
}
