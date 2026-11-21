package fieldcrypt

import (
	"bytes"
	"testing"
)

func TestEnvelope(t *testing.T) {
	k, err := New(7, map[uint32][]byte{7: bytes.Repeat([]byte{42}, 32)})
	if err != nil {
		t.Fatal(err)
	}
	a := []byte("account/field")
	p := []byte("private")
	x, e := k.Seal(p, a)
	if e != nil {
		t.Fatal(e)
	}
	y, _ := k.Seal(p, a)
	if bytes.Equal(x, y) {
		t.Fatal("reused nonce")
	}
	out, e := k.Open(x, a)
	if e != nil || !bytes.Equal(p, out) {
		t.Fatal(e)
	}
	for _, bad := range [][]byte{x[:4], append([]byte{9}, x[1:]...), append(x, 0)} {
		if _, e := k.Open(bad, a); e == nil {
			t.Fatal("corruption accepted")
		}
	}
	if _, e := k.Open(x, nil); e == nil {
		t.Fatal("context swap")
	}
}
