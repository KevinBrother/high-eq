package emotion

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAggregateAllowlist(t *testing.T) {
	base := `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice","voiced_seconds":1,"volume":{"mean":-40,"maximum":-20,"sample_count":2,"valid_seconds":1}}`
	for i, s := range []string{base, strings.Replace(base, `"exercise":false,`, "", 1), strings.Replace(base, `"sample_count":2`, `"readings":[1,2]`, 1), strings.Replace(base, `"valid_seconds":1`, `"valid_seconds":2`, 1), strings.Replace(base, `"volume":`, `"audio":"x","volume":`, 1), strings.Replace(base, `"mean":-40,`, "", 1)} {
		var w Window
		e := json.Unmarshal([]byte(s), &w)
		if e == nil {
			e = w.validate()
		}
		if (e == nil) != (i == 0) {
			t.Fatalf("case %d: %v", i, e)
		}
	}
}

func TestRejectForeignChannelFieldsEvenIfEmpty(t *testing.T) {
	for _, field := range []string{`"source":"",`, `"heart_rate":null,`, `"hrv":null,`, `"volume":null,`} {
		var w Window
		if json.Unmarshal([]byte(`{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice",`+field+`"voiced_seconds":0}`), &w) == nil {
			t.Errorf("accepted %s", field)
		}
	}
}
