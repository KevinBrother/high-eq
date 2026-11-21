// Package fieldcrypt encodes a four-byte big-endian key version followed by a
// random 96-bit nonce and authenticated ciphertext (including the GCM tag).
package fieldcrypt

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"errors"
)

var errEnvelope = errors.New("invalid encrypted field")

type Cipher struct {
	current uint32
	keys    map[uint32]cipher.AEAD
}

func New(current uint32, keys map[uint32][]byte) (*Cipher, error) {
	c := &Cipher{current: current, keys: make(map[uint32]cipher.AEAD)}
	for v, k := range keys {
		if v == 0 || len(k) != 32 {
			return nil, errEnvelope
		}
		b, e := aes.NewCipher(k)
		if e != nil {
			return nil, e
		}
		a, e := cipher.NewGCMWithRandomNonce(b)
		if e != nil {
			return nil, e
		}
		c.keys[v] = a
	}
	if c.keys[current] == nil {
		return nil, errEnvelope
	}
	return c, nil
}
func (c *Cipher) Seal(data, aad []byte) ([]byte, error) {
	if len(aad) == 0 {
		return nil, errEnvelope
	}
	v := binary.BigEndian.AppendUint32(nil, c.current)
	return c.keys[c.current].Seal(v, nil, data, append(v[:4:4], aad...)), nil
}
func (c *Cipher) Open(data, aad []byte) ([]byte, error) {
	if len(data) < 4 || len(aad) == 0 {
		return nil, errEnvelope
	}
	a := c.keys[binary.BigEndian.Uint32(data)]
	if a == nil {
		return nil, errEnvelope
	}
	return a.Open(nil, nil, data[4:], append(data[:4:4], aad...))
}
