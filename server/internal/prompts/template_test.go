package prompts

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
)

func TestLiteralRender(t *testing.T) {
	vars := map[string]string{"scene": "{{other}}", "other": "合成"}
	got, e := Render(`{ "scene": "{{ scene }}" }/{{other}}/{{scene}}`, vars)
	if e != nil || got != `{ "scene": "{{other}}" }/合成/{{other}}` {
		t.Fatal("substitution is not literal")
	}
	for _, s := range []string{" ", "{{}}", "{{ scene", "oops }}", "{{.field}}", "{{call x}}", "{{a-b}}"} {
		if Validate(s) == nil {
			t.Error("accepted malformed template")
		}
	}
	if v, e := Render("private {{missing}}", nil); v != "" || !errors.Is(e, ErrVariable) {
		t.Fatal("missing variable sent or leaked")
	}
	if _, e := Render("{{x}}{{x}}", map[string]string{"x": strings.Repeat("a", maxRendered)}); !errors.Is(e, ErrVariable) {
		t.Fatal("unbounded output")
	}
}
func TestModelScopedBucket(t *testing.T) {
	a, b := uuid.UUID{1}, uuid.UUID{2}
	var n, diff int
	for i := range 10000 {
		var u uuid.UUID
		binary.BigEndian.PutUint64(u[8:], uint64(i))
		k := bucket("scoring", a, u)
		if k < 0 || k >= 100 || k != bucket("scoring", a, u) {
			t.Fatal("unstable bucket")
		}
		if k < 25 {
			n++
		}
		if k != bucket("scoring", b, u) {
			diff++
		}
	}
	if n < 2200 || n > 2800 || diff < 9500 {
		t.Fatal(n, diff)
	}
}

// Real model cohorts must both see approximately the configured prompt percentage;
// reusing T10's user-only hash would exclude one arm from one of these cohorts.
func TestSplitWithinEachModel(t *testing.T) {
	var totals, hits [2]int
	for i := range 100000 {
		var u uuid.UUID
		binary.BigEndian.PutUint64(u[8:], uint64(i))
		h := sha256.Sum256(u[:])
		var m byte
		if binary.BigEndian.Uint64(h[:8])%100 < 20 {
			m = 1
		}
		totals[m]++
		if bucket("scoring", uuid.UUID{m + 1}, u) < 30 {
			hits[m]++
		}
	}
	for m, n := range totals {
		pct := float64(hits[m]) * 100 / float64(n)
		if pct < 29 || pct > 31 {
			t.Fatalf("model %d: %.2f%%", m, pct)
		}
	}
}
