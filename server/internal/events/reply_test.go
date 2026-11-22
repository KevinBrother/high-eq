package events

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestReplyOutcomeWireShape(t *testing.T) {
	v := ReplyOutcome{
		FeedbackID: uuid.New(),
		UserID:     uuid.New(),
		SourceID:   uuid.New(),
		SourceKind: "reply",
		OccurredAt: time.Date(2026, 11, 22, 10, 0, 0, 0, time.UTC),
	}
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	if err = json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{
		"feedback_id": true,
		"user_id":     true,
		"source_id":   true,
		"source_kind": true,
		"occurred_at": true,
	}
	if len(got) != len(want) {
		t.Fatalf("outcome shape = %s", b)
	}
	for key := range want {
		if _, ok := got[key]; !ok {
			t.Fatalf("missing %s in %s", key, b)
		}
	}
}
