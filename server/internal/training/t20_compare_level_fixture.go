//go:build integration && t20compare

package training

import (
	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

// T20CompareObservationLevel is a test-only second single-skill level with the
// same target as level 1. The T20 comparison check appends it to the catalog so
// a different-level control can keep the same mode and target. It exists only
// in binaries built with the t20compare tag and never changes the product
// catalog used by ordinary builds.
const T20CompareObservationLevel = "19000000-0000-4000-8000-000000000099"

func AddT20CompareObservationLevel() uuid.UUID {
	id := uuid.MustParse(T20CompareObservationLevel)
	for _, existing := range catalog {
		if existing.Id == id {
			return id
		}
	}
	target := "observation"
	catalog = append(catalog, lesson{
		Level: app.Level{
			Id:         id,
			Title:      "对照关卡（仅 T20 测试）",
			Scene:      app.LevelScene("work"),
			Difficulty: 1,
			Mode:       "single_skill",
			TargetItem: &target,
		},
		scenario: "合成观察对照：同一目标，不同关卡。",
	})
	return id
}
