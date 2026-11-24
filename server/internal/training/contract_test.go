package training

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

func TestPracticeEnvelopeAndScoreProjection(t *testing.T) {
	f, e := fieldcrypt.New(1, map[uint32][]byte{1: bytes.Repeat([]byte{42}, 32)})
	if e != nil {
		t.Fatal(e)
	}
	s := Service{Fields: f}
	key := privacy.ScoreKey{UserID: uuid.New(), SourceID: uuid.New(), Kind: "practice"}
	score := scoring.Full{NVC: scoring.NVC{Need: scoring.Item{Score: 15, Reason: "private reason"}, Total: 15}}
	b, e := s.seal(key.UserID, key.SourceID, "score", score)
	if e != nil {
		t.Fatal(e)
	}
	src := privacy.ScoreSource{ScoreKey: key, Detail: b}
	decode := Decoder(f, nil)
	v, e := decode(src)
	if e != nil || v != score.Values() {
		t.Fatal("source projection", e)
	}
	out, _ := json.Marshal(v)
	if bytes.Contains(out, []byte("private")) || bytes.Contains(b, []byte("reason")) {
		t.Fatal("plaintext leak")
	}
	if e = s.open(key.UserID, key.SourceID, "progress", b, &score); e == nil {
		t.Fatal("field swap")
	}
	src.SourceID = uuid.New()
	if _, e = decode(src); e == nil {
		t.Fatal("source swap")
	}
	src.SourceID = key.SourceID
	src.UserID = uuid.New()
	if _, e = decode(src); e == nil {
		t.Fatal("cross account")
	}
	src.Kind = "review"
	called := false
	_, e = Decoder(f, func(privacy.ScoreSource) (events.ScoreValues, error) { called = true; return events.ScoreValues{}, nil })(src)
	if e != nil || !called {
		t.Fatal("other decoder lost")
	}
}

func TestCreateBranchesAndCatalogCursor(t *testing.T) {
	id := uuid.New()
	scene, text := "work", "合成会议"
	nul, blank := "合成\x00会议", " \t\n"
	l := catalog[0]
	for _, bad := range []Input{{}, {ID: id}, {ID: id, Level: &l.Id, Scenario: &text}, {ID: id, Scene: &scene}, {ID: id, Scene: &scene, Scenario: &nul}, {ID: id, Scene: &scene, Scenario: &blank}, {ID: id, Level: &uuid.Nil}, {ID: id, Scenario: &text, Scene: &scene, Contact: &uuid.Nil}} {
		if _, _, _, _, e := bad.describe(); e == nil {
			t.Fatal("invalid creation accepted")
		}
	}
	_, m, k, v, e := (Input{ID: id, Scene: &scene, Scenario: &text}).describe()
	if e != nil || m != "full_session" || k != "practice" || v != nil {
		t.Fatal("custom mode")
	}
	n := 2
	a, e := Levels(app.ListLevelsParams{Limit: &n})
	if e != nil || a.NextCursor == nil {
		t.Fatal(e)
	}
	b, e := Levels(app.ListLevelsParams{Limit: &n, Cursor: a.NextCursor})
	if e != nil || len(b.Items) != 2 || b.Items[0].Id != catalog[2].Id {
		t.Fatal("page overlap")
	}
	sc := app.ListLevelsParamsScene("invalid")
	if _, e = Levels(app.ListLevelsParams{Scene: &sc}); e == nil {
		t.Fatal("bad filter")
	}
}
