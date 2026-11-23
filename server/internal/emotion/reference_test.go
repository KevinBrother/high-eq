package emotion

import (
	"encoding/json"
	"math"
	"os"
	"testing"
	"time"
)

func TestDecisionVectors(t *testing.T) {
	b, e := os.ReadFile("testdata/decisions.json")
	if e != nil {
		t.Fatal(e)
	}
	var cases []struct {
		Name  string
		Input Frame
		Want  string
	}
	if e = json.Unmarshal(b, &cases); e != nil {
		t.Fatal(e)
	}
	if len(cases) < 12 {
		t.Fatal("missing vectors")
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			if got := Decide(c.Input); got.Kind != c.Want {
				t.Fatalf("got %+v want %s", got, c.Want)
			}
		})
	}
}
func TestIndependentProgress(t *testing.T) {
	now := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	a := newAccumulator(time.UTC)
	for d := 0; d < 7; d++ {
		for n := 0; n < 60; n++ {
			at := now.AddDate(0, 0, -d).Add(-time.Duration(n) * 30 * time.Second)
			a.add(at, "speech_rate", 120, 30)
			a.add(at, "heart_rate", 80, 29)
			a.add(at, "pitch", 240, 1)
		}
	}
	p := a.progress(now, nil)
	if !p.Speech.Ready || *p.Speech.Threshold != 150 || p.Heart.Ready || p.Heart.Today != 1740 || p.Pitch.Today != 60 || p.Volume.Today != 0 || p.HRV.Readings != 0 || p.HRV.Ready {
		t.Fatalf("%+v", p)
	}
}

func TestFalsePositiveAdjustsOnlyTriggeredThreshold(t *testing.T) {
	a := newAccumulator(time.UTC)
	now := time.Now()
	for d := 0; d < 7; d++ {
		t0 := now.AddDate(0, 0, -d)
		a.add(t0, "heart_rate", 80, 1800)
		a.add(t0, "speech_rate", 120, 1800)
		a.add(t0, "volume", -40, 1800)
	}
	p := a.progress(now, map[string]int{"heart_rate": 1, "volume": 100})
	if math.Abs(*p.Heart.Threshold-96*1.05) > 1e-9 || *p.Volume.Threshold != -31 || *p.Speech.Threshold != 150 {
		t.Fatalf("heart=%g volume=%g speech=%g", *p.Heart.Threshold, *p.Volume.Threshold, *p.Speech.Threshold)
	}
	p = a.progress(now, map[string]int{"heart_rate": 20})
	if *p.Heart.Threshold != 144 {
		t.Fatal("cap")
	}
}

func TestProgressVectors(t *testing.T) {
	b, e := os.ReadFile("testdata/progress.json")
	if e != nil {
		t.Fatal(e)
	}
	var cases []struct {
		Name    string
		Now     time.Time
		Zone    string
		Windows []Window
		Want    Baselines
	}
	if e = json.Unmarshal(b, &cases); e != nil {
		t.Fatal(e)
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			loc, e := time.LoadLocation(c.Zone)
			if e != nil {
				t.Fatal(e)
			}
			a, _, e := reduceWindows(loc, c.Now, false, func(visit func(Window) error) error {
				for _, w := range c.Windows {
					if e := visit(w); e != nil {
						return e
					}
				}
				return nil
			})
			if e != nil {
				t.Fatal(e)
			}
			got := a.progress(c.Now, nil)
			if got.Heart.Today != c.Want.Heart.Today || got.Volume.Today != c.Want.Volume.Today || got.Speech.Today != c.Want.Speech.Today || got.Pitch.Today != c.Want.Pitch.Today || got.HRV.Readings != c.Want.HRV.Readings || got.HRV.Days != c.Want.HRV.Days || got.HRV.Ready {
				t.Fatalf("%+v", got)
			}
		})
	}
}

func TestLegacySpeechRateDoesNotEnterBaselineButOtherVoiceFeaturesDo(t *testing.T) {
	now := time.Date(2026, 11, 21, 23, 30, 0, 0, time.UTC)
	var windows []Window
	ex := false
	legacy := func(at time.Time) Window {
		seconds := 30
		value := 180.0
		volume := -40.0
		pitch := 220.0
		return Window{At: at, Channel: "voice", Duration: 30, Exercise: &ex, Voiced: &seconds,
			Speech: &Stat{Mean: &value, Maximum: &value, Count: 1, Seconds: &seconds},
			Volume: &Stat{Mean: &volume, Maximum: &volume, Count: 1, Seconds: &seconds},
			Pitch:  &Stat{Mean: &pitch, Maximum: &pitch, Count: 1, Seconds: &seconds}}
	}
	for d := 7; d >= 0; d-- {
		day := now.AddDate(0, 0, -d).Truncate(24 * time.Hour).Add(12 * time.Hour)
		for i := 0; i < 60; i++ {
			windows = append(windows, legacy(day.Add(time.Duration(i)*30*time.Second)))
		}
	}
	windows = append(windows, legacy(now))
	read := func(visit func(Window) error) error {
		for _, w := range windows {
			if e := visit(w); e != nil {
				return e
			}
		}
		return nil
	}
	for _, tc := range []struct {
		name      string
		forWindow bool
		wantToday int
	}{
		{"current", false, 1830},
		{"confirmed_window", true, 1800},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a, frame, e := reduceWindows(time.UTC, now, tc.forWindow, read)
			if e != nil {
				t.Fatal(e)
			}
			p := a.progress(now, nil)
			if p.Speech.Today != 0 || p.Speech.Ready || p.Speech.Baseline != nil || p.Speech.Threshold != nil {
				t.Fatalf("legacy speech rate polluted the baseline: %+v", p.Speech)
			}
			if !p.Volume.Ready || !p.Pitch.Ready || p.Volume.Today != tc.wantToday || p.Pitch.Today != tc.wantToday ||
				*p.Volume.Threshold != -34 || *p.Pitch.Threshold != 253 {
				t.Fatalf("volume/pitch were not preserved: %+v", p)
			}
			if frame.SpeechRateUnit != "" || frame.Means["speech_rate"] != nil {
				t.Fatal("legacy speech rate leaked into the decision frame")
			}
			if frame.Means["volume"] == nil || frame.Means["pitch"] == nil {
				t.Fatalf("volume/pitch missing from the decision frame: %+v", frame.Means)
			}
		})
	}
}

func TestMixedLegacyAndCurrentSpeechRateUsesOnlyCurrentUnit(t *testing.T) {
	now := time.Date(2026, 11, 21, 23, 30, 0, 0, time.UTC)
	var windows []Window
	ex := false
	voice := func(at time.Time, speech float64, unit string) Window {
		seconds := 30
		volume := -40.0
		pitch := 220.0
		return Window{At: at, Channel: "voice", Duration: 30, Exercise: &ex, Voiced: &seconds,
			Speech: &Stat{Mean: &speech, Maximum: &speech, Count: 1, Seconds: &seconds}, SpeechRateUnit: unit,
			Volume: &Stat{Mean: &volume, Maximum: &volume, Count: 1, Seconds: &seconds},
			Pitch:  &Stat{Mean: &pitch, Maximum: &pitch, Count: 1, Seconds: &seconds}}
	}
	for d := 14; d >= 1; d-- {
		day := now.AddDate(0, 0, -d).Truncate(24 * time.Hour).Add(12 * time.Hour)
		for i := 0; i < 60; i++ {
			value, unit := 180.0, ""
			if d <= 7 {
				value, unit = 4, SpeechRateUnitCharactersPerSecond
			}
			windows = append(windows, voice(day.Add(time.Duration(i)*30*time.Second), value, unit))
		}
	}
	a, _, e := reduceWindows(time.UTC, now, false, func(visit func(Window) error) error {
		for _, w := range windows {
			if e := visit(w); e != nil {
				return e
			}
		}
		return nil
	})
	if e != nil {
		t.Fatal(e)
	}
	p := a.progress(now, nil)
	if !p.Speech.Ready || math.Abs(*p.Speech.Baseline-4) > 1e-9 || math.Abs(*p.Speech.Threshold-5) > 1e-9 {
		t.Fatalf("current baseline includes legacy values: %+v", p.Speech)
	}
	if !p.Volume.Ready || !p.Pitch.Ready {
		t.Fatalf("mixed history dropped non-speech features: %+v", p)
	}
}

func TestLegacySpeechRateCannotTriggerDecision(t *testing.T) {
	at := time.Date(2026, 11, 21, 12, 0, 0, 0, time.UTC)
	legacySpeech, volume := 180.0, -19.0
	speechThreshold, volumeThreshold := 150.0, -20.0
	f := Frame{Start: at, VoiceAt: at, Means: map[string]*float64{"speech_rate": &legacySpeech, "volume": &volume}, Thresholds: map[string]*float64{"speech_rate": &speechThreshold, "volume": &volumeThreshold}}
	if got := Decide(f); got.Kind != None {
		t.Fatalf("legacy speech rate drove a decision: %+v", got)
	}
	currentSpeech := 4.0
	currentThreshold := 3.75
	f.SpeechRateUnit = SpeechRateUnitCharactersPerSecond
	f.Means["speech_rate"], f.Thresholds["speech_rate"] = &currentSpeech, &currentThreshold
	if got := Decide(f); got.Kind != Rhythm {
		t.Fatalf("current speech rate did not drive rhythm: %+v", got)
	}
}
