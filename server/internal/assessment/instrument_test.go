package assessment

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/fieldcrypt"
)

func TestLoadConfiguredVersion(t *testing.T) {
	txt := string(bundled)
	p := filepath.Join(t.TempDir(), "updated.yaml")
	if e := os.WriteFile(p, []byte(strings.Replace(txt, "wleis-2026-11", "fixture-v2", 1)), 0600); e != nil {
		t.Fatal(e)
	}
	b, e := Load(p)
	if e != nil {
		t.Fatal(e)
	}
	if b.Version != "fixture-v2" || len(b.Items) != 16 || len(b.Options) != 7 {
		t.Fatal("wrong override")
	}
	wire, e := json.Marshal(b)
	if e != nil || bytes.Contains(wire, []byte(`"en"`)) || !bytes.Contains(wire, []byte(`"dimension":"SEA"`)) {
		t.Fatal("instrument wire shape")
	}
	for _, pair := range [][2]string{{"id: 2,", "id: 1,"}, {"[1, 2, 3, 4]", "[1, 2, 3, 5]"}, {"dim: SEA", "dim: OEA"}, {"reverse_scored: []", "reverse_scored: [1]"}, {"max: 7", "max: 8"}, {"zh_status: final", "zh_status: draft"}, {"说不清, 有点同意", "说不清, 说不清"}} {
		if !strings.Contains(txt, pair[0]) {
			t.Fatal("missing fixture pattern", pair[0])
		}
		if _, e := parse([]byte(strings.Replace(txt, pair[0], pair[1], 1))); e == nil {
			t.Fatalf("accepted %q", pair[1])
		}
	}
	if _, e := parse(append(bytes.Clone(bundled), []byte("\n---\nversion: other\n")...)); e == nil {
		t.Fatal("second YAML document")
	}
}

func TestEnvelopeBinding(t *testing.T) {
	f, e := fieldcrypt.New(1, map[uint32][]byte{1: make([]byte, 32)})
	if e != nil {
		t.Fatal(e)
	}
	user := uuid.New()
	r := record{ID: uuid.New(), Version: "v"}
	enc, e := r.seal(f, user, "answers_enc", []int{1, 2})
	if e != nil {
		t.Fatal(e)
	}
	var a []int
	if e = r.open(f, user, "answers_enc", enc, &a); e != nil || len(a) != 2 {
		t.Fatal(e)
	}
	other := r
	other.ID = uuid.New()
	newVersion := r
	newVersion.Version = "other"
	for _, e := range []error{r.open(f, uuid.New(), "answers_enc", enc, &a), r.open(f, user, "scores_enc", enc, &a), other.open(f, user, "answers_enc", enc, &a), newVersion.open(f, user, "answers_enc", enc, &a)} {
		if e == nil {
			t.Fatal("accepted swapped envelope")
		}
	}
}

func TestCursorAndRetestBoundary(t *testing.T) {
	at := time.Date(2026, 10, 24, 19, 30, 0, 123000, time.FixedZone("+08", 8*3600))
	r := record{ID: uuid.New(), At: at}.result(Scores{})
	v, id, e := decodeCursor(cursor(r))
	if e != nil || !v.Equal(at) || id != r.ID {
		t.Fatal("cursor round trip")
	}
	for _, s := range []string{"", "bad!", "MQ"} {
		if _, _, e := decodeCursor(s); e == nil {
			t.Fatal("invalid cursor")
		}
	}
	if wait := retest(at, r.NextEligibleAt.Add(-time.Microsecond)); wait == nil || !wait.RetryAt.Equal(at.Add(672*time.Hour)) {
		t.Fatal("early submission")
	}
	if wait := retest(at, r.NextEligibleAt); wait != nil {
		t.Fatal("inclusive deadline")
	}
}

// The Docker build context is server/ only. On a repository checkout also
// verify that the bundled, offline fallback is the authorized source verbatim.
func TestBundledBankMatchesDocument(t *testing.T) {
	doc, err := os.ReadFile("../../../docs/wleis_items.md")
	if os.IsNotExist(err) {
		t.Skip("documentation not included in server-only build context")
	}
	if err != nil {
		t.Fatal(err)
	}
	_, block, ok := strings.Cut(string(doc), "```yaml\n")
	if !ok {
		t.Fatal("missing instrument YAML")
	}
	block, _, ok = strings.Cut(block, "\n```")
	if !ok || !strings.HasPrefix(string(bundled), block+"\noptions:") {
		t.Fatal("bundled YAML differs from docs/wleis_items.md")
	}
}
