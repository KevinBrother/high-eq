package growth

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestRetractRemovesAppendedReviewKeepsOrdinaryItems(t *testing.T) {
	exercise, single, full, card, dueLevel := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	deleted, retained := uuid.New(), uuid.New()
	first := time.Date(2026, 11, 25, 9, 0, 0, 0, time.UTC)
	reviewID := uuid.New()
	plan := Plan{
		Day: "2026-11-25",
		Items: []PlanItem{
			{ID: exercise, Kind: KindExercise, ContentID: exercise, Completed: true},
			{ID: single, Kind: KindLevel, ContentID: single, Completed: true},
			{ID: full, Kind: KindLevel, ContentID: full},
			{ID: card, Kind: KindCard, ContentID: card},
			{ID: reviewID, Kind: KindLevel, ContentID: dueLevel, Review: true, ReviewActivityID: &deleted},
		},
		completion: &planCompletion{Practices: []practiceCompletion{
			{ActivityID: deleted, ItemID: reviewID, At: first},
			{ActivityID: retained, ItemID: single, At: first.Add(time.Hour)},
		}},
	}

	at, changed := plan.retractPractices(map[uuid.UUID]bool{deleted: true}, &first)
	if !changed || len(plan.Items) != 4 {
		t.Fatalf("appended review not removed: changed=%v items=%+v", changed, plan.Items)
	}
	for _, item := range plan.Items {
		if item.Review || item.ReviewActivityID != nil || item.ID == reviewID {
			t.Fatalf("review residue: %+v", item)
		}
	}
	if plan.Items[0].ID != exercise || !plan.Items[0].Completed || plan.Items[1].ID != single || !plan.Items[1].Completed || plan.Items[2].ID != full || plan.Items[3].ID != card {
		t.Fatalf("ordinary items changed: %+v", plan.Items)
	}
	want := first.Add(time.Hour)
	if at == nil || !at.Equal(want) {
		t.Fatalf("check-in=%v want=%v", at, want)
	}
	if _, changed := plan.retractPractices(map[uuid.UUID]bool{deleted: true}, at); changed {
		t.Fatal("retraction applied a second time")
	}
}

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
