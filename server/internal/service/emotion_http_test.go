package service

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestEmotionRequiresAuthenticatedSession(t *testing.T) {
	r := (&Runtime{}).Router()
	for _, op := range [][2]string{
		{"POST", "signal-windows"}, {"GET", "signal-baselines"}, {"GET", "signal-baselines?for_window=2026-11-21T01:00:30Z"},
		{"DELETE", "signal-windows?channel=voice&starts_at=" + time.Now().UTC().Format(time.RFC3339)},
		{"POST", "signal-events"}, {"GET", "signal-events"}, {"PATCH", "signal-events/" + uuid.NewString()},
	} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(op[0], "/v1/"+op[1], nil))
		if w.Code != 401 {
			t.Errorf("%v: %d", op, w.Code)
		}
	}
}

func TestParseBaselineWindow(t *testing.T) {
	want := time.Date(2026, 11, 21, 1, 0, 30, 0, time.UTC)
	for _, value := range []string{"2026-11-21T01:00:30Z", "2026-11-21T09:00:30.000+08:00", "2026-11-21t01:00:30z"} {
		at, err := parseBaselineWindow("", &value)
		if err != nil || at == nil || *at != want {
			t.Errorf("parse %q = %v, %v, want %v", value, at, err, want)
		}
	}
	for _, value := range []string{
		"", "2026-11-21T01:00:30", "2026-11-21T1:00:30Z", "2026-11-21T01:00:00+08:60",
		"2026-11-21T01:00:30+24:00", "2026-11-21T01:00:30,0Z", "2026-11-21T01:00:30.0000000001Z",
		"2026-11-21T01:00:29Z", "2026-02-30T01:00:30Z",
	} {
		if _, err := parseBaselineWindow("", &value); err == nil {
			t.Errorf("accepted %q", value)
		}
	}
	for _, raw := range []string{"for_window=%ZZ", "for%5Fwindow=%ZZ", "for_window=2026-11-21T01:00:30Z;broken"} {
		if _, err := parseBaselineWindow(raw, nil); err == nil {
			t.Errorf("treated %q as ordinary GET", raw)
		}
	}
	if at, err := parseBaselineWindow("unrelated=%ZZ", nil); at != nil || err != nil {
		t.Errorf("ordinary GET affected by unknown query parameter: %v, %v", at, err)
	}
}
