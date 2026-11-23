package emotion

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

const voiceWindowWithSpeech = `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice","voiced_seconds":21,"speech_rate":{"mean":4,"maximum":5,"sample_count":1,"valid_seconds":18}}`

func withUnit(raw string, unit string) string {
	return strings.Replace(raw, `"speech_rate":`, `"speech_rate_unit":"`+unit+`","speech_rate":`, 1)
}

func TestSpeechRatePresenceAndUnit(t *testing.T) {
	withSpeech := voiceWindowWithSpeech
	withSpeechAndUnit := withUnit(voiceWindowWithSpeech, SpeechRateUnitCharactersPerSecond)
	withoutSpeech := `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice","voiced_seconds":0}`
	cases := []struct {
		name     string
		raw      string
		decodeOK bool
		uploadOK bool
	}{
		{"current speech and unit", withSpeechAndUnit, true, true},
		{"no speech or unit", withoutSpeech, true, true},
		{"legacy speech without unit", withSpeech, true, false},
		{"current unit without speech", `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice","voiced_seconds":21,"speech_rate_unit":"characters_per_second"}`, false, false},
		{"empty unit with speech", withUnit(voiceWindowWithSpeech, ""), false, false},
		{"empty unit alone", `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice","voiced_seconds":0,"speech_rate_unit":""}`, false, false},
		{"non-enum unit with speech", withUnit(voiceWindowWithSpeech, "syllables_per_minute"), false, false},
		{"health with valid unit", `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"health","source":"watch_live","speech_rate_unit":"characters_per_second","heart_rate":{"mean":72,"maximum":78,"sample_count":5,"valid_seconds":24}}`, false, false},
		{"health with empty unit", `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"health","source":"watch_live","speech_rate_unit":"","heart_rate":{"mean":72,"maximum":78,"sample_count":5,"valid_seconds":24}}`, false, false},
		{"null speech", `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice","voiced_seconds":0,"speech_rate":null}`, false, false},
		{"null unit", `{"starts_at":"2026-11-21T12:00:00Z","duration_seconds":30,"exercise":false,"channel":"voice","voiced_seconds":0,"speech_rate_unit":null}`, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var w Window
			e := json.Unmarshal([]byte(tc.raw), &w)
			if (e == nil) != tc.decodeOK {
				t.Fatalf("decode result %v, want ok=%v", e, tc.decodeOK)
			}
			if e == nil && ((w.validateForUpload() == nil) != tc.uploadOK) {
				t.Fatalf("upload result %v, want ok=%v", w.validateForUpload(), tc.uploadOK)
			}
		})
	}
}

func TestLegacyEncryptedWindowRemainsReadable(t *testing.T) {
	var w Window
	if e := json.Unmarshal([]byte(voiceWindowWithSpeech), &w); e != nil {
		t.Fatalf("legacy encrypted aggregate cannot be opened: %v", e)
	}
	if w.Speech == nil || w.SpeechRateUnit != "" {
		t.Fatalf("legacy window changed during decode: %+v", w)
	}
}

func TestStructBuiltCurrentWindowCanUpload(t *testing.T) {
	mean, maximum, seconds := 4.0, 5.0, 17
	exercise, voiced := false, 21
	w := Window{
		At:             time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC),
		Channel:        "voice",
		Duration:       30,
		Exercise:       &exercise,
		Voiced:         &voiced,
		Speech:         &Stat{Mean: &mean, Maximum: &maximum, Count: 17, Seconds: &seconds},
		SpeechRateUnit: SpeechRateUnitCharactersPerSecond,
	}
	if e := w.validateForUpload(); e != nil {
		t.Fatalf("struct-built current window rejected: %v", e)
	}
}

func TestWindowUnmarshalResetsPresenceState(t *testing.T) {
	var w Window
	if e := json.Unmarshal([]byte(withUnit(voiceWindowWithSpeech, SpeechRateUnitCharactersPerSecond)), &w); e != nil {
		t.Fatalf("current window decode: %v", e)
	}
	if e := json.Unmarshal([]byte(voiceWindowWithSpeech), &w); e != nil {
		t.Fatalf("legacy window decode after current window: %v", e)
	}
	if w.speechRateUnitPresent {
		t.Fatal("unit presence leaked from a previous decode")
	}
}

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
