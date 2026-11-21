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
