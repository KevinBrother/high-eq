//go:build integration

package growth

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/assessment"
	"high-eq/server/internal/events"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

type planningFixture struct {
	*projectionFixture
	assessments *assessment.Service
	plans       *PlanService
	levels      *testLevels
	activities  *testActivityLevels
	profiles    *testProfiles
}

type testActivityLevels struct {
	levels map[uuid.UUID]uuid.UUID
}

func (a *testActivityLevels) ActivityLevel(_ context.Context, _ pgx.Tx, _ uuid.UUID, activityID uuid.UUID) (uuid.UUID, error) {
	return a.levels[activityID], nil
}

func setupPlanning(t *testing.T, membershipErr error) *planningFixture {
	t.Helper()
	base := setupProjection(t)
	bank, err := assessment.Load("")
	if err != nil {
		t.Fatal(err)
	}
	assessments := assessment.New(bank, nil, base.svc.Fields, base.bus, base.db)
	levels := &testLevels{levels: LevelIDs{Single: uuid.New(), Full: uuid.New()}}
	activities := &testActivityLevels{levels: map[uuid.UUID]uuid.UUID{}}
	profiles := &testProfiles{scene: "partner", ok: true}
	plans, err := NewPlanService(PlanDependencies{
		Fields:     base.svc.Fields,
		Results:    assessments,
		Levels:     levels,
		Activities: activities,
		Profiles:   profiles,
		Membership: testMembership{err: membershipErr},
	})
	if err != nil {
		t.Fatal(err)
	}
	base.bus.AssessmentCompleted.Subscribe(plans.ConsumeAssessment)
	base.bus.DrillProgressed.Subscribe(plans.ConsumeDrill)
	base.bus.ScoreCompleted.Subscribe(plans.ConsumeScore)
	return &planningFixture{
		projectionFixture: base,
		assessments:       assessments,
		plans:             plans,
		levels:            levels,
		activities:        activities,
		profiles:          profiles,
	}
}

func (f *planningFixture) publishAssessment(user, id uuid.UUID) error {
	f.t.Helper()
	return f.bus.PublishAssessment(f.ctx, events.Assessment{UserID: user, AssessmentID: id})
}

func (f *planningFixture) today(user uuid.UUID) Plan {
	f.t.Helper()
	var plan Plan
	if err := f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
		var err error
		plan, err = f.plans.Today(f.ctx, tx, user)
		return err
	}); err != nil {
		f.t.Fatal(err)
	}
	return plan
}

func (f *planningFixture) complete(user, item uuid.UUID) PlanProgress {
	f.t.Helper()
	var progress PlanProgress
	if err := f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
		var err error
		progress, err = f.plans.CompleteItem(f.ctx, tx, user, item)
		return err
	}); err != nil {
		f.t.Fatal(err)
	}
	return progress
}

func (f *planningFixture) completeErr(user, item uuid.UUID) error {
	f.t.Helper()
	return f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
		_, err := f.plans.CompleteItem(f.ctx, tx, user, item)
		return err
	})
}

func (f *planningFixture) generate(user, assessmentID uuid.UUID, at time.Time) Plan {
	f.t.Helper()
	result := assessment.Result{
		ID:          assessmentID,
		CompletedAt: at,
		Scores: assessment.Scores{
			Dimensions: map[string]assessment.Dimension{
				"SEA": {Percent: 20},
				"OEA": {Percent: 40},
				"UOE": {Percent: 60},
				"ROE": {Percent: 80},
			},
			Total: assessment.Dimension{Percent: 50},
		},
	}
	var plan Plan
	if err := f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
		var err error
		plan, err = f.plans.generatePlan(f.ctx, tx, user, assessmentID, result, at, true)
		return err
	}); err != nil {
		f.t.Fatal(err)
	}
	return plan
}

type plannedDrill struct {
	ID          uuid.UUID
	SourceID    uuid.UUID
	LevelID     uuid.UUID
	Score       int
	TargetItem  string
	CreatedAt   time.Time
	CompletedAt time.Time
}

func (f *planningFixture) createDrill(user uuid.UUID, score int, createdAt, completedAt time.Time, levelID uuid.UUID) plannedDrill {
	f.t.Helper()
	d := plannedDrill{
		LevelID: levelID, Score: score, TargetItem: "observation",
		CreatedAt: createdAt.UTC().Truncate(time.Microsecond), CompletedAt: completedAt.UTC().Truncate(time.Microsecond),
	}
	if err := f.db.QueryRow(f.ctx, `insert into activities(user_id,kind,state,created_at) values($1,'drill','complete',$2) returning id,source_id`, user, d.CreatedAt).Scan(&d.ID, &d.SourceID); err != nil {
		f.t.Fatal(err)
	}
	if _, err := f.db.Exec(f.ctx, `insert into practice_work(activity_id,completed_at) values($1,$2)`, d.ID, d.CompletedAt); err != nil {
		f.t.Fatal(err)
	}
	return d
}

func (f *planningFixture) publishDrill(user uuid.UUID, d plannedDrill) error {
	f.t.Helper()
	return f.bus.PublishDrill(f.ctx, events.Drill{
		UserID: user, ActivityID: d.ID, LevelID: d.LevelID, TargetItem: d.TargetItem, Score: d.Score,
	})
}

func (f *planningFixture) publishPractice(user, levelID uuid.UUID, at time.Time) events.Score {
	f.t.Helper()
	v := f.score(user, "practice", "complete", at, fullScore(values()))
	f.activities.levels[v.ActivityID] = levelID
	if err := f.bus.PublishScore(f.ctx, v); err != nil {
		f.t.Fatal(err)
	}
	return v
}

func (f *planningFixture) drill(user uuid.UUID, score int) plannedDrill {
	f.t.Helper()
	completedAt := time.Now().UTC().Add(-time.Hour)
	d := f.createDrill(user, score, completedAt.Add(-25*time.Hour), completedAt, uuid.New())
	if err := f.publishDrill(user, d); err != nil {
		f.t.Fatal(err)
	}
	return d
}

func (f *planningFixture) dueDrill(user uuid.UUID, score int, levelID uuid.UUID) plannedDrill {
	f.t.Helper()
	completedAt := time.Now().UTC().Add(-73 * time.Hour)
	d := f.createDrill(user, score, completedAt.Add(-25*time.Hour), completedAt, levelID)
	if err := f.publishDrill(user, d); err != nil {
		f.t.Fatal(err)
	}
	return d
}

type scheduleRow struct {
	Score      int
	Band       string
	OccurredAt time.Time
	RetryAt    *time.Time
	ClosedAt   *time.Time
}

func (f *planningFixture) schedule(user, activityID uuid.UUID) scheduleRow {
	f.t.Helper()
	var row scheduleRow
	var sealed []byte
	if err := f.db.QueryRow(f.ctx, `select schedule_enc,occurred_at,retry_at,closed_at from growth_drill_schedules where activity_id=$1`, activityID).Scan(&sealed, &row.OccurredAt, &row.RetryAt, &row.ClosedAt); err != nil {
		f.t.Fatal(err)
	}
	var err error
	row.Score, row.Band, err = f.plans.openSchedule(sealed, user, activityID)
	if err != nil {
		f.t.Fatal(err)
	}
	return row
}

func (f *planningFixture) dueReview(user uuid.UUID, at time.Time) *drillReview {
	f.t.Helper()
	var review *drillReview
	if err := f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
		var err error
		review, err = f.plans.dueReview(f.ctx, tx, user, at)
		return err
	}); err != nil {
		f.t.Fatal(err)
	}
	return review
}

func (f *planningFixture) planCompletedAt(user uuid.UUID, day string) *time.Time {
	f.t.Helper()
	var completedAt *time.Time
	if err := f.db.QueryRow(f.ctx, `select completed_at from daily_plans where user_id=$1 and plan_day=$2`, user, day).Scan(&completedAt); err != nil {
		f.t.Fatal(err)
	}
	return completedAt
}

func levelItem(plan Plan, levelID uuid.UUID) PlanItem {
	for _, item := range plan.Items {
		if item.Kind == KindLevel && item.ContentID == levelID {
			return item
		}
	}
	return PlanItem{}
}

func TestAssessmentEventBuildsFreePlanWithoutProfile(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	assessmentID := f.assessment(user, time.Now().UTC(), 80)

	if err := f.publishAssessment(user, assessmentID); err != nil {
		t.Fatal(err)
	}
	if f.profiles.calls != 0 {
		t.Fatalf("free plan read profile %d times", f.profiles.calls)
	}
	plan := f.today(user)
	if plan.Personalized || plan.AssessmentID == nil || *plan.AssessmentID != assessmentID {
		t.Fatalf("free plan=%+v", plan)
	}
	if len(plan.Items) != 4 || f.levels.calls != 1 {
		t.Fatalf("items=%d level calls=%d", len(plan.Items), f.levels.calls)
	}
	if f.levels.scene != sceneFor(user, plan.Day, "observation") {
		t.Fatalf("free plan level scene=%q", f.levels.scene)
	}

	if err := f.publishAssessment(user, assessmentID); err != nil {
		t.Fatal(err)
	}
	if f.profiles.calls != 0 || f.levels.calls != 1 {
		t.Fatalf("replay profile calls=%d level calls=%d", f.profiles.calls, f.levels.calls)
	}
	if n := f.planCount(user); n != 1 {
		t.Fatalf("plans after replay=%d", n)
	}
}

func TestAssessmentEventBuildsPersonalizedMemberPlan(t *testing.T) {
	f := setupPlanning(t, nil)
	user := f.user()
	assessmentID := f.assessment(user, time.Now().UTC(), 80)

	if err := f.publishAssessment(user, assessmentID); err != nil {
		t.Fatal(err)
	}
	plan := f.today(user)
	if !plan.Personalized || f.profiles.calls != 1 || f.levels.scene != "partner" {
		t.Fatalf("plan=%+v profile calls=%d level scene=%q", plan, f.profiles.calls, f.levels.scene)
	}
}

func TestPlansDoNotRepeatContentWithinSevenDays(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	base := time.Date(2026, 11, 16, 4, 0, 0, 0, time.UTC)
	assessmentID := f.assessment(user, base, 80)
	exercises, cards := map[uuid.UUID]bool{}, map[uuid.UUID]bool{}

	for offset := 0; offset < 7; offset++ {
		plan := f.generate(user, assessmentID, base.AddDate(0, 0, offset))
		for _, item := range plan.Items {
			if item.Kind == KindExercise {
				if exercises[item.ContentID] {
					t.Fatalf("exercise %s repeated within seven days", item.ContentID)
				}
				exercises[item.ContentID] = true
			}
			if item.Kind == KindCard {
				if cards[item.ContentID] {
					t.Fatalf("card %s repeated within seven days", item.ContentID)
				}
				cards[item.ContentID] = true
			}
		}
	}
	if len(exercises) != 7 || len(cards) != 7 {
		t.Fatalf("exercises=%d cards=%d", len(exercises), len(cards))
	}
}

func TestDueReviewIsReusedAndCompletionClearsRetry(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	f.assessment(user, time.Now().UTC().Add(-2*time.Hour), 80)
	source := f.dueDrill(user, 10, uuid.New())

	// Seed T19's canonical progress with its own AAD. T26 may schedule against
	// this source but must never rewrite or reinterpret the encrypted history.
	progress := scoring.Progress{
		TargetItem: source.TargetItem,
		Item:       scoring.Item{Score: 10, Reason: "源评分"},
		NextAction: ReviewThreeDays,
	}
	plain, err := json.Marshal(progress)
	if err != nil {
		t.Fatal(err)
	}
	progressAAD := []byte("practice/progress/" + user.String() + "/" + source.ID.String())
	sealedProgress, err := f.svc.Fields.Seal(plain, progressAAD)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.db.Exec(f.ctx, `insert into drill_progress(activity_id,target_item,progress_enc,retry_at) values($1,$2,$3,$4)`, source.ID, source.TargetItem, sealedProgress, source.CompletedAt.Add(72*time.Hour)); err != nil {
		t.Fatal(err)
	}

	plan := f.today(user)
	var review PlanItem
	var exercise PlanItem
	for _, item := range plan.Items {
		if item.Review {
			review = item
		}
		if item.Kind == KindExercise {
			exercise = item
		}
	}
	if review.Kind != KindLevel || !review.Review || review.ContentID != source.LevelID || review.ReviewActivityID == nil || *review.ReviewActivityID != source.ID {
		t.Fatalf("review plan=%+v", plan)
	}
	if exercise.ID == uuid.Nil {
		t.Fatalf("plan has no exercise: %+v", plan)
	}

	f.complete(user, exercise.ID)
	completedAt := f.planCompletedAt(user, plan.Day)
	if completedAt == nil {
		t.Fatal("exercise check-in did not set plan completion time")
	}
	if row := f.schedule(user, source.ID); row.ClosedAt != nil || row.RetryAt == nil {
		t.Fatalf("ordinary exercise check-in cleared source schedule: %+v", row)
	}

	if err := f.completeErr(user, review.ID); !errors.Is(err, ErrInvalid) {
		t.Fatalf("manual level completion err=%v, want ErrInvalid", err)
	}
	if row := f.schedule(user, source.ID); row.ClosedAt != nil {
		t.Fatalf("manual level completion closed schedule: %+v", row)
	}

	newer := f.createDrill(user, 25, time.Now().UTC().Add(-2*time.Hour), time.Now().UTC().Add(-time.Hour), source.LevelID)
	if err := f.publishDrill(user, newer); err != nil {
		t.Fatal(err)
	}
	if row := f.schedule(user, source.ID); row.ClosedAt == nil || !row.ClosedAt.Equal(newer.CompletedAt) {
		t.Fatalf("new same-level completion did not close source: %+v newer=%s", row, newer.CompletedAt)
	}
	plan = f.today(user)
	if item := levelItem(plan, source.LevelID); !item.Completed {
		t.Fatalf("real level completion did not advance plan: %+v", plan)
	}
	if got := f.planCompletedAt(user, plan.Day); got == nil || !got.Equal(*completedAt) {
		t.Fatalf("real level completion changed first plan completion: got=%v want=%v", got, completedAt)
	}
	if err := f.publishDrill(user, source); err != nil { // duplicate old completion replay
		t.Fatal(err)
	}
	if row := f.schedule(user, source.ID); row.ClosedAt == nil {
		t.Fatalf("old replay reopened source schedule: %+v", row)
	}
	if review := f.dueReview(user, time.Now().UTC()); review != nil {
		t.Fatalf("old replay resurrected due review: %+v", review)
	}

	var gotProgress []byte
	var retryAt *time.Time
	if err := f.db.QueryRow(f.ctx, `select progress_enc,retry_at from drill_progress where activity_id=$1`, source.ID).Scan(&gotProgress, &retryAt); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotProgress, sealedProgress) || retryAt == nil || !retryAt.Equal(source.CompletedAt.Add(72*time.Hour)) {
		t.Fatal("T26 rewrote T19 canonical drill progress")
	}
	opened, err := f.svc.Fields.Open(gotProgress, progressAAD)
	if err != nil {
		t.Fatal(err)
	}
	var got scoring.Progress
	if err := json.Unmarshal(opened, &got); err != nil || got.Score != progress.Score || got.NextAction != progress.NextAction {
		t.Fatalf("T19 progress no longer decodes: %+v err=%v", got, err)
	}
}

func TestOutOfOrderDrillCompletesOriginalDayWithoutReopeningSchedule(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	if _, err := f.db.Exec(f.ctx, `update users set timezone='Asia/Shanghai' where id=$1`, user); err != nil {
		t.Fatal(err)
	}
	zone, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	secondAt := time.Now().In(zone).Truncate(time.Second)
	firstAt := secondAt.AddDate(0, 0, -1)
	assessmentID := f.assessment(user, firstAt, 80)
	firstPlan := f.generate(user, assessmentID, firstAt)
	secondPlan := f.generate(user, assessmentID, secondAt)
	if firstPlan.Day != firstAt.Format(time.DateOnly) || secondPlan.Day != secondAt.Format(time.DateOnly) || firstPlan.Day == secondPlan.Day {
		t.Fatalf("plan days first=%s second=%s", firstPlan.Day, secondPlan.Day)
	}

	singleLevel := f.levels.levels.Single
	firstLevel := levelItem(firstPlan, singleLevel)
	secondLevel := levelItem(secondPlan, singleLevel)
	fullLevel := levelItem(secondPlan, f.levels.levels.Full)
	if firstLevel.ID == uuid.Nil || secondLevel.ID == uuid.Nil || fullLevel.ID == uuid.Nil {
		t.Fatalf("missing level items: first=%+v second=%+v full=%+v", firstPlan, secondPlan, fullLevel)
	}
	firstDrill := f.createDrill(user, 10, firstAt.Add(-time.Hour), firstAt, singleLevel)
	secondDrill := f.createDrill(user, 10, secondAt.Add(-time.Hour), secondAt, singleLevel)

	// The newer completion is delivered first. The delayed older completion must
	// stay closed for scheduling, but still complete the day on which it occurred.
	if err := f.publishDrill(user, secondDrill); err != nil {
		t.Fatal(err)
	}
	if got := f.planCompletedAt(user, secondPlan.Day); got == nil || !got.Equal(secondDrill.CompletedAt) {
		t.Fatalf("second-day completion=%v want=%v", got, secondDrill.CompletedAt)
	}
	if err := f.publishDrill(user, firstDrill); err != nil {
		t.Fatal(err)
	}
	firstCompletedAt := f.planCompletedAt(user, firstPlan.Day)
	if firstCompletedAt == nil || !firstCompletedAt.Equal(firstDrill.CompletedAt) {
		t.Fatalf("first-day completion=%v want original occurrence=%v", firstCompletedAt, firstDrill.CompletedAt)
	}
	var stored Plan
	var found bool
	if err := f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
		var readErr error
		stored, found, readErr = f.plans.readDayPlan(f.ctx, tx, user, firstPlan.Day)
		return readErr
	}); err != nil {
		t.Fatal(err)
	}
	if !found || !levelItem(stored, singleLevel).Completed {
		t.Fatalf("first-day level not completed: found=%v plan=%+v", found, stored)
	}
	if row := f.schedule(user, firstDrill.ID); row.ClosedAt == nil || !row.ClosedAt.Equal(secondDrill.CompletedAt) || row.RetryAt == nil {
		t.Fatalf("delayed schedule was reopened: %+v", row)
	}
	if review := f.dueReview(user, secondAt.Add(73*time.Hour)); review == nil || review.ActivityID != secondDrill.ID {
		t.Fatalf("due review=%+v want newer activity=%s", review, secondDrill.ID)
	}

	if err := f.publishDrill(user, firstDrill); err != nil { // duplicate delayed delivery
		t.Fatal(err)
	}
	if got := f.planCompletedAt(user, firstPlan.Day); got == nil || !got.Equal(*firstCompletedAt) {
		t.Fatalf("duplicate changed first-day completion: got=%v want=%v", got, firstCompletedAt)
	}
	if row := f.schedule(user, firstDrill.ID); row.ClosedAt == nil {
		t.Fatalf("duplicate reopened delayed schedule: %+v", row)
	}

	// A level item already completed by its real source event is safe to retry
	// through the manual completion endpoint, while an untouched level is not.
	firstProgress := f.complete(user, secondLevel.ID)
	secondProgress := f.complete(user, secondLevel.ID)
	if firstProgress.Streak != secondProgress.Streak || !sameInts(firstProgress.Achievements, secondProgress.Achievements) {
		t.Fatalf("manual replay progress changed: first=%+v second=%+v", firstProgress, secondProgress)
	}
	if err := f.completeErr(user, fullLevel.ID); !errors.Is(err, ErrInvalid) {
		t.Fatalf("uncompleted level completion err=%v want ErrInvalid", err)
	}
	other := f.user()
	if err := f.completeErr(other, secondLevel.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-account completion err=%v want ErrNotFound", err)
	}
}

func TestTodayAttachesReviewAfterPlanOpenedBeforeDeadline(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	assessmentID := f.assessment(user, time.Now().UTC().Add(-2*time.Hour), 80)

	// The user opens today's ordinary plan before the retry is due.
	first := f.today(user)
	if first.AssessmentID == nil || *first.AssessmentID != assessmentID {
		t.Fatalf("first plan=%+v", first)
	}
	if _, count := reviewItem(first); count != 0 {
		t.Fatalf("first plan already has a review: %+v", first)
	}
	exercise := first.Items[0]
	f.complete(user, exercise.ID)
	checkin := f.planCompletedAt(user, first.Day)
	if checkin == nil {
		t.Fatal("exercise check-in did not complete the day")
	}

	level := uuid.New()
	completedAt := time.Now().UTC().Add(-71 * time.Hour) // retry still ~1h away
	source := f.createDrill(user, 10, completedAt.Add(-time.Hour), completedAt, level)
	if err := f.publishDrill(user, source); err != nil {
		t.Fatal(err)
	}
	if plan := f.today(user); len(plan.Items) != 4 {
		t.Fatalf("plan changed before deadline: %+v", plan)
	} else if _, count := reviewItem(plan); count != 0 {
		t.Fatalf("review attached before deadline: %+v", plan)
	}

	// Same local day, exactly at the persisted deadline.
	if _, err := f.db.Exec(f.ctx, `update growth_drill_schedules set retry_at=clock_timestamp() where activity_id=$1`, source.ID); err != nil {
		t.Fatal(err)
	}
	due := f.today(user)
	review, count := reviewItem(due)
	if count != 1 || review.Kind != KindLevel || review.ContentID != level || review.ReviewActivityID == nil || *review.ReviewActivityID != source.ID {
		t.Fatalf("due plan review=%+v plan=%+v", review, due)
	}
	if due.Day != first.Day || due.AssessmentID == nil || *due.AssessmentID != assessmentID || len(due.Items) != 5 {
		t.Fatalf("due plan lost identity: first=%+v due=%+v", first, due)
	}
	// The read exercise was completed after the first snapshot, so identity,
	// content and review fields must match while its Completed flag is now true.
	for i := range first.Items {
		g, w := due.Items[i], first.Items[i]
		if g.ID != w.ID || g.Kind != w.Kind || g.Title != w.Title || g.ContentID != w.ContentID || g.Review != w.Review || (g.ReviewActivityID == nil) != (w.ReviewActivityID == nil) {
			t.Fatalf("ordinary item %d replaced: got=%+v want=%+v", i, g, w)
		}
		if i == 0 && !g.Completed {
			t.Fatalf("completed exercise flag lost: %+v", g)
		}
		if i != 0 && g.Completed != w.Completed {
			t.Fatalf("ordinary item %d completion changed: got=%+v want=%+v", i, g, w)
		}
	}
	if got := f.planCompletedAt(user, due.Day); got == nil || !got.Equal(*checkin) {
		t.Fatalf("check-in changed: got=%v want=%v", got, checkin)
	}

	// Repeated GET stays idempotent.
	again := f.today(user)
	againReview, againCount := reviewItem(again)
	if againCount != 1 || againReview.ID != review.ID || *againReview.ReviewActivityID != *review.ReviewActivityID || len(again.Items) != 5 {
		t.Fatalf("repeated GET changed review: %+v", again)
	}
	for i := range first.Items {
		g, w := again.Items[i], due.Items[i]
		if g.ID != w.ID || g.ContentID != w.ContentID || g.Review != w.Review || g.Completed != w.Completed {
			t.Fatalf("repeated GET changed ordinary item %d: got=%+v want=%+v", i, g, w)
		}
	}
	if got := f.planCompletedAt(user, again.Day); got == nil || !got.Equal(*checkin) {
		t.Fatalf("repeated GET changed check-in: %v", got)
	}

	// A second distinct source whose deadline lands later the same local day
	// must become visible on its own GET without hiding the first review.
	laterLevel := uuid.New()
	laterAt := time.Now().UTC().Add(-71 * time.Hour)
	laterSource := f.createDrill(user, 10, laterAt.Add(-time.Hour), laterAt, laterLevel)
	if err := f.publishDrill(user, laterSource); err != nil {
		t.Fatal(err)
	}
	if plan := f.today(user); len(plan.Items) != 5 || len(reviewsOf(plan)) != 1 {
		t.Fatalf("second source arrived early: %+v", plan)
	}
	if _, err := f.db.Exec(f.ctx, `update growth_drill_schedules set retry_at=clock_timestamp() where activity_id=$1`, laterSource.ID); err != nil {
		t.Fatal(err)
	}
	both := f.today(user)
	bothReviews := reviewsOf(both)
	if len(both.Items) != 6 || len(bothReviews) != 2 {
		t.Fatalf("second due source blocked: %+v", both)
	}
	if *bothReviews[0].ReviewActivityID != source.ID || *bothReviews[1].ReviewActivityID != laterSource.ID {
		t.Fatalf("wrong due sources: %+v", bothReviews)
	}
	for i := range first.Items {
		g, w := both.Items[i], due.Items[i]
		if g.ID != w.ID || g.ContentID != w.ContentID || g.Review != w.Review || g.Completed != w.Completed {
			t.Fatalf("later attachment changed ordinary item %d: got=%+v want=%+v", i, g, w)
		}
	}

	// A real completion of the original level fulfills the review and keeps the
	// source identity; later GETs do not resurrect or reset it.
	newer := f.createDrill(user, 25, time.Now().UTC().Add(-2*time.Hour), time.Now().UTC().Add(-time.Hour), level)
	newer.TargetItem = source.TargetItem
	if err := f.publishDrill(user, newer); err != nil {
		t.Fatal(err)
	}
	completed := f.today(user)
	done, found := reviewFor(completed, source.ID)
	if !found || done.ID != review.ID || !done.Completed {
		t.Fatalf("review completion not reflected: %+v", completed)
	}
	otherReview, ok := reviewFor(completed, laterSource.ID)
	if !ok || otherReview.Completed || len(reviewsOf(completed)) != 2 {
		t.Fatalf("later review disturbed: %+v", completed)
	}
	if got := f.planCompletedAt(user, completed.Day); got == nil || !got.Equal(*checkin) {
		t.Fatalf("review completion changed first check-in: %v", got)
	}
	for i := range first.Items {
		g, w := completed.Items[i], due.Items[i]
		if g.ID != w.ID || g.ContentID != w.ContentID || g.Review != w.Review || g.Completed != w.Completed {
			t.Fatalf("review completion changed ordinary item %d: got=%+v want=%+v", i, g, w)
		}
	}

	other := f.user()
	if n := f.planCount(other); n != 0 {
		t.Fatalf("cross-account plan leaked: %d", n)
	}
}

func TestCompletePlanItemIsIdempotentAndConcurrent(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	assessmentID := f.assessment(user, time.Now().UTC(), 80)
	if err := f.publishAssessment(user, assessmentID); err != nil {
		t.Fatal(err)
	}
	plan := f.today(user)
	item := plan.Items[0].ID
	f.complete(user, item)

	fixed := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
		_, err := tx.Exec(f.ctx, `update daily_plans set completed_at=$3 where user_id=$1 and plan_day=$2`, user, plan.Day, fixed)
		return err
	}); err != nil {
		t.Fatal(err)
	}

	errs := make(chan error, 2)
	var wg sync.WaitGroup
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- f.coord.Access(f.ctx, user, func(tx pgx.Tx) error {
				_, err := f.plans.CompleteItem(f.ctx, tx, user, item)
				return err
			})
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	var completedAt time.Time
	if err := f.db.QueryRow(f.ctx, `select completed_at from daily_plans where user_id=$1 and plan_day=$2`, user, plan.Day).Scan(&completedAt); err != nil {
		t.Fatal(err)
	}
	if !completedAt.Equal(fixed) {
		t.Fatalf("completed_at changed: got %s want %s", completedAt, fixed)
	}
}

func TestDrillScoreBandsAndRetryDeadline(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	var plaintextColumns int
	if err := f.db.QueryRow(f.ctx, `select count(*) from information_schema.columns where table_schema=current_schema() and table_name='growth_drill_schedules' and column_name in ('score','band')`).Scan(&plaintextColumns); err != nil {
		t.Fatal(err)
	}
	if plaintextColumns != 0 {
		t.Fatalf("growth_drill_schedules still has plaintext score/band columns")
	}
	for _, score := range []int{0, 5, 9, 10, 15, 24, 25} {
		drill := f.drill(user, score)
		row := f.schedule(user, drill.ID)
		if row.Score != score || row.Band != Band(score) || !row.OccurredAt.Equal(drill.CompletedAt) {
			t.Fatalf("score %d schedule score=%d band=%s occurred=%s want=%s", score, row.Score, row.Band, row.OccurredAt, drill.CompletedAt)
		}
		if score >= 10 && score < 25 {
			want := drill.CompletedAt.Add(72 * time.Hour)
			if row.RetryAt == nil || !row.RetryAt.Equal(want) {
				t.Fatalf("score %d retry=%v want completion-based %v", score, row.RetryAt, want)
			}
			if row.RetryAt.Equal(drill.CreatedAt.Add(72 * time.Hour)) {
				t.Fatalf("score %d retry used activity creation time", score)
			}
		} else if row.RetryAt != nil {
			t.Fatalf("score %d unexpected retry=%v", score, row.RetryAt)
		}
	}
}

func TestGrowthExportIncludesPlansAndDrillsWithoutInternalLink(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	f.assessment(user, time.Now().UTC().Add(-time.Hour), 80)
	f.dueDrill(user, 10, uuid.New())
	plan := f.today(user)
	var reviewID uuid.UUID
	for _, item := range plan.Items {
		if item.ReviewActivityID != nil {
			reviewID = *item.ReviewActivityID
		}
	}
	if reviewID == uuid.Nil {
		t.Fatal("test setup did not create review plan")
	}
	raw := f.export(user)
	if bytes.Contains(raw, []byte("review_activity_id")) || bytes.Contains(raw, []byte(reviewID.String())) {
		t.Fatalf("export leaked internal review link: %s", raw)
	}
	var records []map[string]any
	if err := json.Unmarshal(raw, &records); err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, record := range records {
		if kind, ok := record["record_type"].(string); ok {
			seen[kind] = true
		}
	}
	if !seen["plan"] || !seen["drill"] {
		t.Fatalf("export missing derived records: %s", raw)
	}
}

func TestDeletedAssessmentCannotRebuildPlanOnReplay(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	assessmentID := f.assessment(user, time.Now().UTC(), 80)
	if err := f.publishAssessment(user, assessmentID); err != nil {
		t.Fatal(err)
	}
	if n := f.planCount(user); n != 1 {
		t.Fatalf("plans=%d", n)
	}
	if err := f.coord.Delete(f.ctx, privacy.Deletion{OperationID: uuid.New(), UserID: user, Scope: "assessments", SourceID: assessmentID}); err != nil {
		t.Fatal(err)
	}
	if n := f.planCount(user); n != 0 {
		t.Fatalf("plans after assessment delete=%d", n)
	}
	if err := f.publishAssessment(user, assessmentID); err == nil {
		t.Fatal("replayed deleted assessment")
	}
	if n := f.planCount(user); n != 0 {
		t.Fatalf("plans after replay=%d", n)
	}
}

func TestDeletedDrillCannotRebuildScheduleOnReplay(t *testing.T) {
	f := setupPlanning(t, membership.ErrForbidden)
	user := f.user()
	drill := f.drill(user, 10)
	if n := f.scheduleCount(drill.ID); n != 1 {
		t.Fatalf("schedule before delete=%d", n)
	}
	if err := f.coord.Delete(f.ctx, privacy.Deletion{OperationID: uuid.New(), UserID: user, Scope: "sessions", SourceID: drill.SourceID}); err != nil {
		t.Fatal(err)
	}
	if n := f.scheduleCount(drill.ID); n != 0 {
		t.Fatalf("schedule after delete=%d", n)
	}
	if err := f.publishDrill(user, drill); err == nil {
		t.Fatal("replayed deleted drill")
	}
	if n := f.scheduleCount(drill.ID); n != 0 {
		t.Fatalf("schedule after replay=%d", n)
	}
}

func (f *planningFixture) planCount(user uuid.UUID) int {
	f.t.Helper()
	var n int
	if err := f.db.QueryRow(f.ctx, `select count(*) from daily_plans where user_id=$1`, user).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	return n
}

func (f *planningFixture) scheduleCount(activityID uuid.UUID) int {
	f.t.Helper()
	var n int
	if err := f.db.QueryRow(f.ctx, `select count(*) from growth_drill_schedules where activity_id=$1`, activityID).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	return n
}
