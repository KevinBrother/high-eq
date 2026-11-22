package growth

import (
	"bytes"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/scoring"
)

func testCipher(t *testing.T) *fieldcrypt.Cipher {
	t.Helper()
	f, err := fieldcrypt.New(1, map[uint32][]byte{1: bytes.Repeat([]byte{0x42}, 32)})
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func sealSource(t *testing.T, f *fieldcrypt.Cipher, user, source uuid.UUID, kind string, full scoring.Full) []byte {
	t.Helper()
	raw, err := json.Marshal(full)
	if err != nil {
		t.Fatal(err)
	}
	var aad []byte
	switch kind {
	case "practice":
		aad = []byte("practice/score/" + user.String() + "/" + source.String())
	case "review":
		aad = []byte("review/v1/" + user.String() + "/" + source.String() + "/score")
	default:
		t.Fatalf("unsupported kind %q", kind)
	}
	sealed, err := f.Seal(raw, aad)
	if err != nil {
		t.Fatal(err)
	}
	return sealed
}

func fullScore(values events.ScoreValues) scoring.Full {
	var full scoring.Full
	full.NVC.Observation.Score = values.NVC.Observation
	full.NVC.Feeling.Score = values.NVC.Feeling
	full.NVC.Need.Score = values.NVC.Need
	full.NVC.Request.Score = values.NVC.Request
	full.NVC.Total = values.NVC.Total
	full.Emotion.ReadOthers.Level = values.Emotion.ReadOthers
	full.Emotion.SelfManagement.Level = values.Emotion.SelfManagement
	full.Emotion.Relationship.Level = values.Emotion.Relationship
	return full
}
