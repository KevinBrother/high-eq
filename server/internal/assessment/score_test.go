package assessment

import (
	"math"
	"testing"
)

func TestBandsBeforeDisplay(t *testing.T) {
	for _, c := range []struct {
		p       float64
		level   string
		display int
	}{{0, "L1", 0}, {39.9, "L1", 40}, {40, "L2", 40}, {40.1, "L2", 40}, {59.9, "L2", 60}, {60, "L3", 60}, {60.1, "L3", 60}, {74.9, "L3", 75}, {75, "L4", 75}, {75.1, "L4", 75}, {89.9, "L4", 90}, {90, "L5", 90}, {90.1, "L5", 90}, {100, "L5", 100}} {
		d := dimension(1+c.p*6/100, c.p)
		if d.Level != c.level || d.Display != c.display {
			t.Errorf("%g: %+v", c.p, d)
		}
	}
}

func TestInstrumentScoring(t *testing.T) {
	b, err := Load("")
	if err != nil {
		t.Fatal(err)
	}
	answers := []int{1, 1, 1, 1, 7, 7, 7, 7, 5, 6, 5, 6, 1, 1, 1, 2}
	s, err := b.Score(b.Version, answers)
	if err != nil {
		t.Fatal(err)
	}
	if s.Dimensions["SEA"].Percent != 0 || s.Dimensions["OEA"].Percent != 100 || s.Dimensions["UOE"].Level != "L4" || math.Abs(s.Dimensions["ROE"].Percent-100.0/24) > 1e-12 || s.Total.Mean != 3.6875 {
		t.Fatal(s)
	}
	for _, a := range [][]int{nil, answers[:15], append(append([]int{}, answers...), 1), append([]int{8}, answers[1:]...), append([]int{0}, answers[1:]...)} {
		if _, e := b.Score(b.Version, a); e == nil {
			t.Fatal("invalid answers")
		}
	}
	if _, e := b.Score("obsolete", answers); e == nil {
		t.Fatal("stale version")
	}
}
