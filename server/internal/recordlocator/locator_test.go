package recordlocator

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestCursorRoundTripsAndIsBoundToKind(t *testing.T) {
	id := uuid.MustParse("10000000-0000-4000-8000-000000000001")
	at := time.Date(2026, 11, 23, 12, 0, 0, 123456000, time.UTC)

	raw, err := EncodeCursor(KindAssessments, Key{ID: id, At: at})
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeCursor(KindAssessments, raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != id || !got.At.Equal(at) {
		t.Fatalf("cursor = %+v, want id %s at %s", got, id, at)
	}
	if _, err := DecodeCursor(KindReviews, raw); !errors.Is(err, ErrInvalidQuery) {
		t.Fatalf("cross-kind cursor error = %v, want ErrInvalidQuery", err)
	}
}

func TestCursorRejectsMalformedOrOversizedValues(t *testing.T) {
	for _, raw := range []string{"", "not-base64", string(make([]byte, MaxCursorLength+1))} {
		if _, err := DecodeCursor(KindContact, raw); !errors.Is(err, ErrInvalidQuery) {
			t.Fatalf("DecodeCursor(%q) error = %v, want ErrInvalidQuery", raw[:min(len(raw), 20)], err)
		}
	}
}

func TestParseKindAndLimit(t *testing.T) {
	for _, kind := range AllKinds() {
		if got, err := ParseKind(string(kind)); err != nil || got != kind {
			t.Fatalf("ParseKind(%q) = %q, %v", kind, got, err)
		}
	}
	if _, err := ParseKind("unknown"); !errors.Is(err, ErrInvalidQuery) {
		t.Fatalf("unknown kind error = %v, want ErrInvalidQuery", err)
	}
	if got, err := Limit(nil); err != nil || got != DefaultLimit {
		t.Fatalf("default limit = %d, %v", got, err)
	}
	for _, value := range []int{1, MaxLimit} {
		if got, err := Limit(&value); err != nil || got != value {
			t.Fatalf("limit(%d) = %d, %v", value, got, err)
		}
	}
	for _, value := range []int{0, -1, MaxLimit + 1} {
		if _, err := Limit(&value); !errors.Is(err, ErrInvalidQuery) {
			t.Fatalf("limit(%d) error = %v, want ErrInvalidQuery", value, err)
		}
	}
}

func TestWindowCursorUsesRecordedAtAndChannel(t *testing.T) {
	at := time.Date(2026, 11, 23, 12, 0, 0, 0, time.UTC)
	raw, err := EncodeCursor(KindSignalWindows, Key{At: at, Channel: ChannelHealth})
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeCursor(KindSignalWindows, raw)
	if err != nil {
		t.Fatal(err)
	}
	if !got.At.Equal(at) || got.Channel != ChannelHealth || got.ID != uuid.Nil {
		t.Fatalf("window cursor = %+v", got)
	}
	if _, err := EncodeCursor(KindSignalWindows, Key{At: at, Channel: "camera"}); !errors.Is(err, ErrInvalidQuery) {
		t.Fatalf("invalid channel error = %v, want ErrInvalidQuery", err)
	}
}
