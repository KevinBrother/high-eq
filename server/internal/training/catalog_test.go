package training

import (
	"testing"

	"github.com/google/uuid"

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

func TestPlanLevelIDsPrefersSceneAndFallsBack(t *testing.T) {
	workSingle := uuid.New()
	partnerSingle := uuid.New()
	workFull := uuid.New()
	partnerFull := uuid.New()
	lessons := []lesson{
		{Level: app.Level{Id: partnerSingle, Scene: "partner", Mode: "single_skill", TargetItem: ptr("observation")}},
		{Level: app.Level{Id: workSingle, Scene: "work", Mode: "single_skill", TargetItem: ptr("observation")}},
		{Level: app.Level{Id: partnerFull, Scene: "partner", Mode: "full_session"}},
		{Level: app.Level{Id: workFull, Scene: "work", Mode: "full_session"}},
	}

	single, full, err := planLevelIDs(lessons, "observation", "work")
	if err != nil || single != workSingle || full != workFull {
		t.Fatalf("same scene: single=%s full=%s err=%v", single, full, err)
	}
	single, full, err = planLevelIDs(lessons, "observation", "family")
	if err != nil || single != partnerSingle || full != partnerFull {
		t.Fatalf("fallback: single=%s full=%s err=%v", single, full, err)
	}
	if _, _, err = planLevelIDs(lessons, "need", "work"); err == nil {
		t.Fatal("accepted missing focus")
	}
}

func TestPlanLevelIDsValidatesInputAndUsesRealCatalog(t *testing.T) {
	if _, _, err := PlanLevelIDs("invalid", "work"); err == nil {
		t.Fatal("accepted invalid focus")
	}
	if _, _, err := PlanLevelIDs("observation", "invalid"); err == nil {
		t.Fatal("accepted invalid scene")
	}
	single, full, err := PlanLevelIDs("observation", "work")
	if err != nil {
		t.Fatal(err)
	}
	got, err := Levels(app.ListLevelsParams{})
	if err != nil {
		t.Fatal(err)
	}
	byID := make(map[uuid.UUID]app.Level, len(got.Items))
	for _, level := range got.Items {
		byID[level.Id] = level
	}
	s, ok := byID[single]
	if !ok || s.Mode != "single_skill" || s.TargetItem == nil || *s.TargetItem != "observation" || s.Scene != "work" {
		t.Fatalf("single level=%+v present=%v", s, ok)
	}
	f, ok := byID[full]
	if !ok || f.Mode != "full_session" || f.Scene != "work" {
		t.Fatalf("full level=%+v present=%v", f, ok)
	}
}

func ptr(v string) *string { return &v }
