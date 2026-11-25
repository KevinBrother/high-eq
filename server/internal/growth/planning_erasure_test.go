package growth

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestRetractPracticeCompletionKeepsSurvivingContributions(t *testing.T) {
	level, other, exercise := uuid.New(), uuid.New(), uuid.New()
	deleted, repeat, otherSource := uuid.New(), uuid.New(), uuid.New()
	first := time.Date(2026, 11, 24, 8, 0, 0, 0, time.UTC)
	later := first.Add(time.Minute)
	last := later.Add(time.Minute)
	deletions := map[uuid.UUID]bool{deleted: true}
	for _, tc := range []struct {
		name          string
		retained      []practiceCompletion
		manual        *time.Time
		checkIn       *time.Time
		wantCheckIn   *time.Time
		wantSameItem  bool
		wantOtherItem bool
	}{
		{name: "only source", checkIn: &first},
		{
			name: "same item has another source", checkIn: &first,
			retained: []practiceCompletion{{ActivityID: repeat, ItemID: level, At: later}}, wantCheckIn: &later, wantSameItem: true,
		},
		{
			name: "another item owns the original check-in", checkIn: &later,
			retained: []practiceCompletion{{ActivityID: otherSource, ItemID: other, At: later}}, wantCheckIn: &later, wantOtherItem: true,
		},
		{name: "manual check-in survives", checkIn: &first, manual: &last, wantCheckIn: &last},
	} {
		t.Run(tc.name, func(t *testing.T) {
			plan := Plan{
				Items: []PlanItem{
					{ID: level, Kind: KindLevel, Completed: true, Review: true, ReviewActivityID: &deleted},
					{ID: other, Kind: KindLevel, Completed: tc.wantOtherItem},
					{ID: exercise, Kind: KindExercise, Completed: tc.manual != nil},
				},
				completion: &planCompletion{
					Practices: append([]practiceCompletion{{ActivityID: deleted, ItemID: level, At: first}}, tc.retained...),
					ManualAt:  tc.manual,
				},
			}
			at, changed := plan.retractPractices(deletions, tc.checkIn)
			if !changed || plan.Items[0].Completed != tc.wantSameItem || plan.Items[0].Review || plan.Items[0].ReviewActivityID != nil ||
				plan.Items[1].Completed != tc.wantOtherItem || plan.Items[2].Completed != (tc.manual != nil) {
				t.Fatalf("unexpected plan after retraction: %+v", plan.Items)
			}
			if (at == nil) != (tc.wantCheckIn == nil) || (at != nil && !at.Equal(*tc.wantCheckIn)) {
				t.Fatalf("check-in = %v, want %v", at, tc.wantCheckIn)
			}
			if len(plan.completion.Practices) != len(tc.retained) {
				t.Fatalf("unexpected completion attribution: %+v", plan.completion.Practices)
			}
			if _, changed := plan.retractPractices(deletions, at); changed {
				t.Fatal("retraction applied a second time")
			}
		})
	}
}
