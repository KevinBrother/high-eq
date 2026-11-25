package privacy

import (
	"bytes"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestWindowReplayIDUsesExactPublicIdentity(t *testing.T) {
	key := bytes.Repeat([]byte{1}, 32)
	online := NewCoordinator(nil, nil, nil, WithWindowReplayKey(key))
	recovery := NewCoordinator(nil, nil, nil, WithWindowReplayKey(key))
	otherKey := NewCoordinator(nil, nil, nil, WithWindowReplayKey(bytes.Repeat([]byte{2}, 32)))
	user := uuid.New()
	at := time.Date(2026, 11, 21, 1, 0, 30, 0, time.UTC)
	alias := func(c *Coordinator, owner uuid.UUID, channel string, instant time.Time) uuid.UUID {
		t.Helper()
		id, err := c.signalWindowReplayID(owner, channel, instant)
		if err != nil || id == uuid.Nil {
			t.Fatalf("replay identifier unavailable: %v", err)
		}
		return id
	}
	want := alias(online, user, "health", at)
	if got := alias(recovery, user, "health", at.In(time.FixedZone("UTC+8", 8*3600))); got != want {
		t.Fatal("different timezone or process changed the replay identifier")
	}
	for _, got := range []uuid.UUID{
		alias(online, uuid.New(), "health", at),
		alias(online, user, "voice", at),
		alias(online, user, "health", at.Add(30*time.Second)),
		alias(otherKey, user, "health", at),
	} {
		if got == want {
			t.Fatal("replay identifiers overlap across distinct inputs")
		}
	}
	for _, invalid := range []time.Time{at.Add(time.Nanosecond), at.Add(time.Second)} {
		if _, err := online.signalWindowReplayID(user, "health", invalid); err == nil {
			t.Fatalf("derived a replay identifier for an unaligned time: %v", invalid)
		}
	}
}
