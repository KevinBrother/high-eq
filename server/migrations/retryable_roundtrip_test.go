package migrations

import (
	"strings"
	"testing"
)

// This local contract test guards the data-preserving rollback shape. The
// integration suite repeats the down/up transition against real business rows.
func TestRetryableMigrationUsesReversibleMarker(t *testing.T) {
	up, err := files.ReadFile("20261124000001_profile_inference_retryable.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	down, err := files.ReadFile("20261124000001_profile_inference_retryable.down.sql")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(down), "state='invalidated'") {
		t.Fatal("rollback permanently invalidates retryable business requests")
	}
	if !strings.Contains(string(down), "updated_at='infinity'") {
		t.Fatal("rollback does not leave a marker that the retry state existed")
	}
	if !strings.Contains(string(up), "updated_at='infinity'") {
		t.Fatal("upgrade does not restore only rows parked by this rollback")
	}
}
