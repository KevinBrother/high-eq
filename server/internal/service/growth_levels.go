package service

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/growth"
	"high-eq/server/internal/training"
)

type trainingPlanLevels struct{}

func (trainingPlanLevels) PlanLevels(_ context.Context, _ pgx.Tx, _ uuid.UUID, focus, scene string) (growth.LevelIDs, error) {
	single, full, err := training.PlanLevelIDs(focus, scene)
	if err != nil {
		return growth.LevelIDs{}, err
	}
	return growth.LevelIDs{Single: single, Full: full}, nil
}
