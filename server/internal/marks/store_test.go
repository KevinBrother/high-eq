package marks

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/fieldcrypt"
)

func TestPatchPreservesOmittedAndClearsNull(t *testing.T) {
	id := uuid.New()
	scene := "work"
	v := app.Mark{Id: uuid.New(), MarkedAt: time.Now(), ContactId: &id, Scene: &scene}
	var p Patch
	if e := json.Unmarshal([]byte(`{"scene":null}`), &p); e != nil {
		t.Fatal(e)
	}
	if e := p.apply(&v); e != nil || v.Scene != nil || v.ContactId == nil || *v.ContactId != id {
		t.Fatal(v, e)
	}
}

func TestExistingMarkEnvelope(t *testing.T) {
	f, e := fieldcrypt.New(1, map[uint32][]byte{1: make([]byte, 32)})
	if e != nil {
		t.Fatal(e)
	}
	u, id, contact := uuid.New(), uuid.New(), uuid.New()
	b, e := f.Seal([]byte(`{"marked_at":"2026-11-21T10:45:00Z","scene":"friends"}`), []byte("mark/"+u.String()+"/"+id.String()))
	if e != nil {
		t.Fatal(e)
	}
	s := Service{Fields: f}
	m, e := s.decode(u, id, &contact, b)
	if e != nil || m.Id != id || m.ContactId == nil || *m.ContactId != contact || m.MarkedAt.IsZero() || m.Scene == nil || *m.Scene != "friends" {
		t.Fatal("existing envelope not readable", e)
	}
	if _, e = s.decode(uuid.New(), id, nil, b); e == nil {
		t.Fatal("accepted wrong owner")
	}
	if _, e = s.decode(u, uuid.New(), nil, b); e == nil {
		t.Fatal("accepted wrong source")
	}
}
