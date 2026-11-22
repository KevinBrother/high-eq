package training

import (
	"testing"

	"high-eq/server/internal/api/app"
)

func TestLevelsAndBoundaries(t *testing.T) {
	p, e := Levels(app.ListLevelsParams{})
	if e != nil || len(p.Items) != 10 {
		t.Fatal("expected ten levels", e)
	}
	seen := map[string]bool{}
	targets := map[string]bool{}
	for _, l := range p.Items {
		if seen[l.Id.String()] || l.Difficulty < 1 || l.Difficulty > 3 || (l.Mode == "full_session") != (l.TargetItem == nil) {
			t.Fatal(l)
		}
		seen[l.Id.String()] = true
		if l.TargetItem != nil {
			targets[*l.TargetItem] = true
		}
	}
	if len(targets) != 4 {
		t.Fatal(targets)
	}
	if fits(30, 0, 1) || fits(1, 29999, 2) || !fits(29, 29999, 1) {
		t.Fatal("turn/token boundary")
	}
}
