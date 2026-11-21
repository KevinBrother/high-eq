package payments

import (
	"bytes"
	"testing"
	"time"
)

func TestLedgerTransitions(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	at := now.Add(-time.Hour)
	f := receipt{}
	key := []byte("transaction")
	v := evidence{start: at}
	if e := f.merge(key, v); e != nil {
		t.Fatal(e)
	}
	if e := f.merge(key, v); e != nil || !f.start.Equal(at) {
		t.Fatal("repeat payment changed start")
	}
	if e := f.merge(key, evidence{refund: now}); e != nil {
		t.Fatal(e)
	}
	if e := f.merge(key, v); e != nil || !f.refund.Equal(now) {
		t.Fatal("stale paid undid refund")
	}
	for _, bad := range []evidence{{start: now}, {refund: at}, {start: now.Add(time.Second)}} {
		copy := f
		if copy.merge(key, bad) == nil {
			t.Fatal("accepted inconsistent evidence")
		}
	}
	if f.merge([]byte("second transaction"), v) == nil {
		t.Fatal("replaced provider identity")
	}
	beforePaid := receipt{}
	if e := beforePaid.merge(key, evidence{refund: now}); e != nil {
		t.Fatal(e)
	}
	if e := beforePaid.merge(key, v); e != nil || !beforePaid.refund.Equal(now) || !bytes.Equal(beforePaid.key, key) {
		t.Fatal("out of order refund")
	}
}
