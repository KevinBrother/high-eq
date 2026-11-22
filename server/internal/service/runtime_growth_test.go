package service

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/training"
)

func TestStartupReplayIsBestEffort(t *testing.T) {
	var called []string
	failure := errors.New("pending delivery")
	replayStartupPending(context.Background(),
		startupReplay{module: "practice", replay: func(context.Context) error {
			called = append(called, "practice")
			return failure
		}},
		startupReplay{module: "reviews", replay: func(context.Context) error {
			called = append(called, "reviews")
			return failure
		}},
		startupReplay{module: "assessments", replay: func(context.Context) error {
			called = append(called, "assessments")
			return nil
		}},
	)
	if len(called) != 3 || called[0] != "practice" || called[1] != "reviews" || called[2] != "assessments" {
		t.Fatalf("replay calls=%v", called)
	}
}

func TestTrainingPlanLevelsUsesRealCatalog(t *testing.T) {
	levels, err := (trainingPlanLevels{}).PlanLevels(context.Background(), nil, uuid.New(), "observation", "work")
	if err != nil {
		t.Fatal(err)
	}
	got, err := training.Levels(app.ListLevelsParams{})
	if err != nil {
		t.Fatal(err)
	}
	byID := make(map[uuid.UUID]app.Level, len(got.Items))
	for _, level := range got.Items {
		byID[level.Id] = level
	}
	s, ok := byID[levels.Single]
	if !ok || s.Mode != "single_skill" || s.TargetItem == nil || *s.TargetItem != "observation" || s.Scene != "work" {
		t.Fatalf("single=%+v present=%v", s, ok)
	}
	f, ok := byID[levels.Full]
	if !ok || f.Mode != "full_session" || f.Scene != "work" {
		t.Fatalf("full=%+v present=%v", f, ok)
	}
}
