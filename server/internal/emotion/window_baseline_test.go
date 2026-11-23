package emotion

import (
	"math"
	"testing"
	"time"
)

func TestWindowBaselineThresholdTiming(t *testing.T) {
	target := time.Date(2026, 11, 22, 8, 0, 30, 0, time.UTC)
	for _, tc := range []struct {
		name         string
		lastDay      int
		newerFirst   bool
		wantCurrent  float64
		wantDecision string
	}{
		{"same_slot_after_commit", 60, false, -29.985748218527316, Rhythm},
		{"seventh_day_after_commit", 59, false, -29.985714285714288, None},
		{"late_with_newer_history", 60, true, -29.942992874109262, Rhythm},
	} {
		t.Run(tc.name, func(t *testing.T) {
			history := []Window{}
			exercise, seconds := false, 30
			voice := func(at time.Time, speech, volume float64) Window {
				stat := func(v float64) *Stat { return &Stat{Mean: &v, Maximum: &v, Count: 30, Seconds: &seconds} }
				return Window{At: at, Channel: "voice", Exercise: &exercise, Duration: 30,
					Voiced: &seconds, Speech: stat(speech), SpeechRateUnit: SpeechRateUnitCharactersPerSecond, Volume: stat(volume)}
			}
			for d := 6; d >= 0; d-- {
				n := 60
				if d == 0 {
					n = tc.lastDay
				}
				first := target.AddDate(0, 0, -d).Add(-30 * time.Minute)
				for i := range n {
					history = append(history, voice(first.Add(time.Duration(i)*30*time.Second), 4, -36))
				}
			}
			atTarget := voice(target, 5, -30)
			newer := voice(target.Add(30*time.Second), 4, -12)
			fold := func(end time.Time, forWindow, targetCommitted bool) (Baselines, Frame) {
				t.Helper()
				rows := append([]Window(nil), history...)
				if targetCommitted {
					rows = append(rows, atTarget)
				}
				if tc.newerFirst {
					rows = append(rows, newer)
				}
				a, f, err := reduceWindows(time.UTC, end, forWindow, func(visit func(Window) error) error {
					for _, w := range rows {
						if w.At.After(end) {
							break
						}
						if err := visit(w); err != nil {
							return err
						}
					}
					return nil
				})
				if err != nil {
					t.Fatal(err)
				}
				return a.progress(end, nil), f
			}
			b, _ := fold(target.Add(time.Minute), false, !tc.newerFirst)
			if !b.Volume.Ready || b.Volume.Days != 7 || b.Volume.Threshold == nil ||
				math.Abs(*b.Volume.Threshold-tc.wantCurrent) > 1e-10 {
				t.Fatalf("current volume = %+v, want threshold %v", b.Volume, tc.wantCurrent)
			}
			b, f := fold(target, true, true)
			if !f.VoiceAt.Equal(target) || f.SpeechRateUnit != SpeechRateUnitCharactersPerSecond ||
				f.Means["speech_rate"] == nil || *f.Means["speech_rate"] != 5 ||
				f.Means["volume"] == nil || *f.Means["volume"] != -30 {
				t.Fatalf("target missing from decision frame: %+v", f)
			}
			if tc.lastDay == 59 {
				for _, p := range []Progress{b.Speech, b.Volume} {
					if p.Ready || p.Days != 6 || p.Today != 1770 || p.Baseline != nil || p.Threshold != nil {
						t.Fatalf("target completed its own seventh day: %+v", p)
					}
				}
			} else if !b.Speech.Ready || !b.Volume.Ready || b.Speech.Threshold == nil || b.Volume.Threshold == nil ||
				*b.Speech.Threshold != 5 || *b.Volume.Threshold != -30 {
				t.Fatalf("window thresholds differ from 5 characters/s and -30 dB: %+v", b)
			}
			f.Thresholds = map[string]*float64{"speech_rate": b.Speech.Threshold, "volume": b.Volume.Threshold}
			if got := Decide(f).Kind; got != tc.wantDecision {
				t.Fatalf("T30 classified target as %s, want %s", got, tc.wantDecision)
			}
		})
	}
}

func TestWindowBaselineExcludesTargetHealthButKeepsDecisionFrame(t *testing.T) {
	at := time.Date(2026, 11, 22, 8, 0, 30, 0, time.UTC)
	exercise, active, seconds := false, true, 30
	heart, hrv, cadence, speech := 120., 42., 110., 5.
	duration := func(value *float64) *Stat {
		return &Stat{Mean: value, Maximum: value, Count: 2, Seconds: &seconds}
	}
	history := Window{At: at.Add(-30 * time.Second), Channel: "health", Exercise: &exercise,
		Heart: duration(&heart), HRV: &Stat{Count: 2}, Cadence: duration(&cadence)}
	health := Window{At: at, Channel: "health", Exercise: &active, Source: "watch_live",
		Heart: duration(&heart), HRV: &Stat{Mean: &hrv, Maximum: &hrv, Count: 3}}
	voice := Window{At: at, Channel: "voice", Exercise: &exercise, Speech: duration(&speech), SpeechRateUnit: SpeechRateUnitCharactersPerSecond}
	read := func(visit func(Window) error) error {
		for _, w := range []Window{history, health, voice} {
			if err := visit(w); err != nil {
				return err
			}
		}
		return nil
	}
	a, frame, err := reduceWindows(time.UTC, at, true, read)
	if err != nil {
		t.Fatal(err)
	}
	b := a.progress(at, nil)
	if b.HRV.Readings != 2 || b.HRV.Days != 1 || b.HRV.Ready {
		t.Fatalf("window HRV includes the target slot: %+v", b.HRV)
	}
	if !frame.HealthAt.Equal(at) || !frame.VoiceAt.Equal(at) || !frame.Exercise ||
		frame.Source != "watch_live" || frame.Cadence != 110 ||
		frame.Means["heart_rate"] != &heart || frame.Means["speech_rate"] != &speech {
		t.Fatalf("decision frame lost same-slot or cadence inputs: %+v", frame)
	}
	current, _, err := reduceWindows(time.UTC, at, false, read)
	if err != nil {
		t.Fatal(err)
	}
	if got := current.progress(at, nil).HRV.Readings; got != 5 {
		t.Fatalf("ordinary HRV readings = %d, want 5", got)
	}
}
