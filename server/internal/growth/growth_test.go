package growth

import (
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestContentIsCompleteAndOriginal(t *testing.T) {
	c, err := LoadContent()
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Exercises) < 50 || len(c.Cards) < 20 {
		t.Fatalf("content below minimum: exercises=%d (want at least 50), cards=%d (want at least 20)", len(c.Exercises), len(c.Cards))
	}
	if c.SourceNote == "" || !contains(c.SourceNote, "原创虚构材料") {
		t.Fatal("missing original-material declaration")
	}
	if contains(c.SourceNote, "人工审核通过") || contains(c.SourceNote, "审核通过") {
		t.Fatal("must not claim external review")
	}
	exerciseIDs := map[uuid.UUID]bool{}
	cardIDs := map[uuid.UUID]bool{}
	for _, e := range c.Exercises {
		if e.ID == uuid.Nil || exerciseIDs[e.ID] || !validScene(e.Scene) || !validFocus(e.Focus) || e.Question == "" || len(e.Choices) < 2 || e.AnswerIndex < 0 || e.AnswerIndex >= len(e.Choices) || e.Explanation == "" {
			t.Fatalf("invalid exercise: %+v", e)
		}
		exerciseIDs[e.ID] = true
	}
	for _, v := range c.Cards {
		if v.ID == uuid.Nil || cardIDs[v.ID] || !validScene(v.Scene) || v.Title == "" || v.Body == "" {
			t.Fatalf("invalid card: %+v", v)
		}
		cardIDs[v.ID] = true
	}
}

func TestWeakestDimensionTieBreakAndLevelIDs(t *testing.T) {
	cases := []struct {
		name string
		in   WLEIS
		want string
	}{
		{"sea", WLEIS{SEA: 20, OEA: 50, UOE: 60, ROE: 70}, "observation"},
		{"oea", WLEIS{SEA: 50, OEA: 20, UOE: 60, ROE: 70}, "feeling"},
		{"uoe", WLEIS{SEA: 50, OEA: 60, UOE: 20, ROE: 70}, "need"},
		{"roe", WLEIS{SEA: 50, OEA: 60, UOE: 70, ROE: 20}, "request"},
		{"tie", WLEIS{SEA: 20, OEA: 20, UOE: 20, ROE: 20}, "observation"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := Weakest(tc.in); got != tc.want {
				t.Fatalf("got %s", got)
			}
		})
	}
}

func TestBandBoundaries(t *testing.T) {
	for score, want := range map[int]string{0: "retry_now", 5: "retry_now", 9: "retry_now", 10: "retry_in_three_days", 15: "retry_in_three_days", 24: "retry_in_three_days", 25: "pass"} {
		if got := Band(score); got != want {
			t.Errorf("%d: got %s want %s", score, got, want)
		}
	}
}

func TestBehaviorAndTrainingReference(t *testing.T) {
	if got := BehaviorScore(100, [3]int{3, 3, 3}); got != 85 {
		t.Fatalf("behavior=%v", got)
	}
	if got := BehaviorScore(60, [3]int{4, 5, 3}); got != 64.5 {
		t.Fatalf("behavior=%v", got)
	}
	half := 50.0
	if got := TrainingReference(&half, &half); got == nil || *got != 50 {
		t.Fatalf("reference=%v", got)
	}
	if got := TrainingReference(nil, &half); got != nil {
		t.Fatalf("reference without WLEIS=%v", got)
	}
	if got := TrainingReference(&half, nil); got != nil {
		t.Fatalf("reference without behavior=%v", got)
	}
}

func TestAchievementsAndCurrentStreak(t *testing.T) {
	days := []string{"2026-11-01", "2026-11-02", "2026-11-03", "2026-11-20", "2026-11-21", "2026-11-22"}
	streak, got := Achievements(days, "2026-11-22")
	if streak != 3 || !sameInts(got, []int{3}) {
		t.Fatalf("streak=%d achievements=%v", streak, got)
	}
	streak, got = Achievements(days[:3], "2026-11-22")
	if streak != 0 || !sameInts(got, []int{3}) {
		t.Fatalf("broken streak=%d achievements=%v", streak, got)
	}
	streak, got = Achievements([]string{"2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07"}, "2026-11-08")
	if streak != 7 || !sameInts(got, []int{3, 7}) {
		t.Fatalf("historical achievements=%d %v", streak, got)
	}
	days30 := make([]string, 30)
	for i := range days30 {
		days30[i] = time.Date(2026, 10, 1+i, 0, 0, 0, 0, time.UTC).Format(time.DateOnly)
	}
	streak, got = Achievements(days30, "2026-11-01")
	if streak != 0 || !sameInts(got, []int{3, 7, 30}) {
		t.Fatalf("30-day history streak=%d achievements=%v", streak, got)
	}
}

func TestPlanDeterministicAndSevenDayNoRepeat(t *testing.T) {
	c, err := LoadContent()
	if err != nil {
		t.Fatal(err)
	}
	user := uuid.MustParse("11111111-1111-4111-8111-111111111111")
	usedE, usedC := map[uuid.UUID]bool{}, map[uuid.UUID]bool{}
	var first Plan
	for i := 0; i < 7; i++ {
		day := time.Date(2026, 11, 16+i, 0, 0, 0, 0, time.UTC)
		p, err := BuildPlan(c, testPlanInput(user, day, WLEIS{SEA: 20, OEA: 30, UOE: 40, ROE: 50}, usedE, usedC))
		if err != nil {
			t.Fatal(err)
		}
		if i == 0 {
			first = p
			in := testPlanInput(user, day, WLEIS{SEA: 20, OEA: 30, UOE: 40, ROE: 50}, map[uuid.UUID]bool{}, map[uuid.UUID]bool{})
			in.AssessmentID = *first.AssessmentID
			p2, err := BuildPlan(c, in)
			if err != nil {
				t.Fatal(err)
			}
			if p2.Items[0].ID != p.Items[0].ID || p2.Items[0].ContentID != p.Items[0].ContentID {
				t.Fatal("plan is not deterministic")
			}
		}
		for _, item := range p.Items {
			if item.Kind == "exercise" {
				if usedE[item.ContentID] {
					t.Fatal("exercise repeated")
				}
				usedE[item.ContentID] = true
			}
			if item.Kind == "card" {
				if usedC[item.ContentID] {
					t.Fatal("card repeated")
				}
				usedC[item.ContentID] = true
			}
		}
	}
}

func TestDueLevelReviewDoesNotResetExerciseDedup(t *testing.T) {
	c := dueLevelReviewContent()
	user := uuid.MustParse("00000000-0000-0000-0000-000000000006")
	scores := WLEIS{SEA: 20, OEA: 40, UOE: 60, ROE: 80}
	firstDay := time.Date(2026, 11, 19, 0, 0, 0, 0, time.UTC)
	first := testPlanInput(user, firstDay, scores, nil, nil)
	first.Scene = "friends"
	firstPlan, err := BuildPlan(c, first)
	if err != nil {
		t.Fatal(err)
	}
	firstExercise := firstPlan.Items[0].ContentID
	if !fixtureContainsExercise(c, firstExercise) {
		t.Fatalf("fixture selected unexpected exercise %s", firstExercise)
	}

	reviewDay := time.Date(2026, 11, 22, 0, 0, 0, 0, time.UTC)
	review := testPlanInput(user, reviewDay, scores, map[uuid.UUID]bool{firstExercise: true}, nil)
	review.Scene = "friends"
	review.ReviewTarget = "observation"
	review.ReviewLevelID = &review.Levels.Single
	reviewActivityID := uuid.New()
	review.ReviewActivityID = &reviewActivityID
	reviewPlan, err := BuildPlan(c, review)
	if err != nil {
		t.Fatal(err)
	}
	if reviewPlan.Items[0].ContentID == firstExercise {
		t.Fatalf("due level review reused ordinary exercise %s", firstExercise)
	}
	if !fixtureContainsExercise(c, reviewPlan.Items[0].ContentID) {
		t.Fatalf("fixture selected unexpected replacement exercise %s", reviewPlan.Items[0].ContentID)
	}
	if item := reviewPlan.Items[1]; !item.Review || item.ReviewActivityID == nil || *item.ReviewActivityID != reviewActivityID {
		t.Fatalf("review link not attached to level: %+v", item)
	}

	// The same due-level input with an empty history must select the original
	// exercise again. This keeps the counterexample precise: only the used set
	// prevents the repeat, not the level review path itself.
	control := testPlanInput(user, reviewDay, scores, nil, nil)
	control.Scene = "friends"
	control.ReviewTarget = "observation"
	control.ReviewLevelID = &control.Levels.Single
	control.ReviewActivityID = &reviewActivityID
	controlPlan, err := BuildPlan(c, control)
	if err != nil {
		t.Fatal(err)
	}
	if controlPlan.Items[0].ContentID != firstExercise {
		t.Fatalf("fixture no longer reproduces the seven-day repeat: got %s want %s", controlPlan.Items[0].ContentID, firstExercise)
	}

	explicit := testPlanInput(user, reviewDay.AddDate(0, 0, 1), scores, map[uuid.UUID]bool{firstExercise: true}, nil)
	explicit.Scene = "friends"
	explicit.ReviewExerciseID = &firstExercise
	explicit.ReviewTarget = "observation"
	explicit.ReviewLevelID = &explicit.Levels.Single
	explicit.ReviewActivityID = &reviewActivityID
	explicitPlan, err := BuildPlan(c, explicit)
	if err != nil {
		t.Fatal(err)
	}
	if explicitPlan.Items[0].ContentID != firstExercise || explicitPlan.Items[0].Review {
		t.Fatalf("explicit review exception not preserved: %+v", explicitPlan.Items[0])
	}
}

func TestBuildPlanPersonalizationAndReview(t *testing.T) {
	c, err := LoadContent()
	if err != nil {
		t.Fatal(err)
	}
	user := uuid.New()
	day := time.Date(2026, 11, 22, 0, 0, 0, 0, time.UTC)
	in := testPlanInput(user, day, WLEIS{SEA: 20, OEA: 30, UOE: 40, ROE: 50}, nil, nil)
	in.Scene = "work"
	free, err := BuildPlan(c, in)
	if err != nil || free.Personalized {
		t.Fatalf("free plan: %+v %v", free, err)
	}
	in = testPlanInput(user, day, WLEIS{SEA: 20, OEA: 30, UOE: 40, ROE: 50}, nil, nil)
	in.Scene = "partner"
	in.Personalized = true
	member, err := BuildPlan(c, in)
	if err != nil || !member.Personalized || len(member.Items) != 4 {
		t.Fatalf("member plan: %+v %v", member, err)
	}
	exercise := member.Items[0]
	in = testPlanInput(user, day.AddDate(0, 0, 1), WLEIS{SEA: 20, OEA: 30, UOE: 40, ROE: 50}, map[uuid.UUID]bool{exercise.ContentID: true}, nil)
	in.ReviewExerciseID = &exercise.ContentID
	in.ReviewTarget = "observation"
	in.ReviewLevelID = &in.Levels.Single
	reviewActivityID := uuid.New()
	in.ReviewActivityID = &reviewActivityID
	review, err := BuildPlan(c, in)
	if err != nil || review.Items[0].ContentID != exercise.ContentID || review.Items[0].Review {
		t.Fatalf("review plan: %+v %v", review, err)
	}
	if review.Items[0].ReviewActivityID != nil {
		t.Fatalf("review link attached to exercise: %+v", review.Items[0])
	}
	if review.Items[1].Kind != KindLevel || !review.Items[1].Review || review.Items[1].ContentID != in.Levels.Single || review.Items[1].ReviewActivityID == nil || *review.Items[1].ReviewActivityID != reviewActivityID {
		t.Fatalf("review level: %+v", review.Items[1])
	}
	for _, item := range review.Items[2:] {
		if item.Review || item.ReviewActivityID != nil {
			t.Fatalf("review link attached to non-single item: %+v", item)
		}
	}

	in = testPlanInput(user, day.AddDate(0, 0, 2), WLEIS{SEA: 20, OEA: 30, UOE: 40, ROE: 50}, nil, nil)
	in.ReviewTarget = "observation"
	in.ReviewLevelID = &in.Levels.Single
	if _, err := BuildPlan(c, in); err == nil {
		t.Fatal("review plan without source activity accepted")
	}
}

func TestBuildPlanRequiresDistinctResolvedLevels(t *testing.T) {
	c, err := LoadContent()
	if err != nil {
		t.Fatal(err)
	}
	day := time.Date(2026, 11, 22, 0, 0, 0, 0, time.UTC)
	for name, levels := range map[string]LevelIDs{
		"missing single": {Full: uuid.New()},
		"missing full":   {Single: uuid.New()},
		"same":           {Single: uuid.MustParse("11111111-1111-4111-8111-111111111111"), Full: uuid.MustParse("11111111-1111-4111-8111-111111111111")},
	} {
		t.Run(name, func(t *testing.T) {
			in := testPlanInput(uuid.New(), day, WLEIS{SEA: 20}, nil, nil)
			in.Levels = levels
			if _, err := BuildPlan(c, in); err == nil {
				t.Fatal("accepted unresolved level IDs")
			}
		})
	}
}

func testPlanInput(user uuid.UUID, day time.Time, scores WLEIS, exercises, cards map[uuid.UUID]bool) PlanInput {
	return PlanInput{
		User: user, Day: day, AssessmentID: uuid.New(), Scores: scores,
		Scene: "work", Levels: LevelIDs{Single: uuid.New(), Full: uuid.New()},
		UsedExercises: exercises, UsedCards: cards,
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func sameInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
