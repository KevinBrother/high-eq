package growth

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// todayTx is a minimal pgx.Tx for the Today read/attach path. Unrelated
// methods panic through the nil embedded interface; every test here only needs
// the clock, the stored plan and the drill schedule lookup.
type todayTx struct {
	pgx.Tx
	now     time.Time
	zone    string
	planEnc []byte
	reviews []fakeDue
	updates int
}

type fakeDue struct {
	review  drillReview
	retryAt time.Time
}

type todayRows struct {
	pgx.Rows
	items []fakeDue
	i     int
}

func (r *todayRows) Next() bool {
	if r.i >= len(r.items) {
		return false
	}
	r.i++
	return true
}

func (r *todayRows) Scan(dest ...any) error {
	v := r.items[r.i-1].review
	*dest[0].(*uuid.UUID) = v.ActivityID
	*dest[1].(*uuid.UUID) = v.LevelID
	*dest[2].(*string) = v.Focus
	return nil
}

func (r *todayRows) Close() {}

func (r *todayRows) Err() error { return nil }

type rowFunc func(dest ...any) error

func (f rowFunc) Scan(dest ...any) error { return f(dest...) }

type errRow struct{ err error }

func (r errRow) Scan(...any) error { return r.err }

func (f *todayTx) QueryRow(_ context.Context, sql string, _ ...any) pgx.Row {
	switch {
	case strings.Contains(sql, "clock_timestamp()"):
		return rowFunc(func(dest ...any) error {
			*dest[0].(*time.Time) = f.now
			*dest[1].(*string) = f.zone
			return nil
		})
	case strings.Contains(sql, "for update"):
		if f.planEnc == nil {
			return errRow{pgx.ErrNoRows}
		}
		return rowFunc(func(dest ...any) error {
			*dest[0].(*[]byte) = f.planEnc
			return nil
		})
	case strings.Contains(sql, "from daily_plans where user_id=$1 and plan_day=$2"):
		if f.planEnc == nil {
			return errRow{pgx.ErrNoRows}
		}
		return rowFunc(func(dest ...any) error {
			*dest[0].(*[]byte) = f.planEnc
			return nil
		})
	}
	return errRow{fmt.Errorf("unexpected query: %s", sql)}
}

func (f *todayTx) Query(_ context.Context, sql string, _ ...any) (pgx.Rows, error) {
	if !strings.Contains(sql, "d.retry_at is not null") {
		return nil, fmt.Errorf("unexpected query: %s", sql)
	}
	var due []fakeDue
	for _, v := range f.reviews {
		if !v.retryAt.After(f.now) {
			due = append(due, v)
		}
	}
	sort.SliceStable(due, func(i, j int) bool {
		if due[i].retryAt.Equal(due[j].retryAt) {
			return due[i].review.ActivityID.String() < due[j].review.ActivityID.String()
		}
		return due[i].retryAt.Before(due[j].retryAt)
	})
	return &todayRows{items: due}, nil
}

func (f *todayTx) Exec(_ context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	if !strings.Contains(sql, "update daily_plans set plan_enc=$3") {
		return pgconn.CommandTag{}, fmt.Errorf("unexpected exec: %s", sql)
	}
	sealed, ok := args[2].([]byte)
	if !ok {
		return pgconn.CommandTag{}, errors.New("plan_enc is not bytes")
	}
	f.planEnc = append([]byte(nil), sealed...)
	f.updates++
	return pgconn.NewCommandTag("UPDATE 1"), nil
}

type todayFixture struct {
	svc  *PlanService
	tx   *todayTx
	user uuid.UUID
	day  string
	plan Plan
}

func setupToday(t *testing.T) *todayFixture {
	t.Helper()
	fields := testCipher(t)
	svc, err := NewPlanService(PlanDependencies{Fields: fields, Results: noResultReader{}})
	if err != nil {
		t.Fatal(err)
	}
	user := uuid.New()
	day := "2026-11-25"
	assessmentID := uuid.New()
	exercise, single, full, card := uuid.New(), uuid.New(), uuid.New(), uuid.New()
	plan := Plan{
		Day:          day,
		AssessmentID: &assessmentID,
		Items: []PlanItem{
			{ID: PlanItemID(user, day, KindExercise, exercise), Kind: KindExercise, Title: "读人练习", ContentID: exercise, Completed: true},
			{ID: PlanItemID(user, day, KindLevel, single), Kind: KindLevel, Title: "单项练习", ContentID: single},
			{ID: PlanItemID(user, day, KindLevel, full), Kind: KindLevel, Title: "完整对练", ContentID: full},
			{ID: PlanItemID(user, day, KindCard, card), Kind: KindCard, Title: "知识卡", ContentID: card},
		},
		completion: &planCompletion{},
	}
	sealed, err := svc.sealPlan(plan, user, day)
	if err != nil {
		t.Fatal(err)
	}
	return &todayFixture{
		svc: svc, user: user, day: day, plan: plan,
		tx: &todayTx{now: time.Date(2026, 11, 25, 8, 0, 0, 0, time.UTC), zone: "UTC", planEnc: sealed},
	}
}

func (f *todayFixture) today(t *testing.T) Plan {
	t.Helper()
	plan, err := f.svc.Today(context.Background(), f.tx, f.user)
	if err != nil {
		t.Fatal(err)
	}
	return plan
}

func (f *todayFixture) armReview(level uuid.UUID, retryAt time.Time) drillReview {
	r := drillReview{ActivityID: uuid.New(), LevelID: level, Focus: "observation"}
	f.tx.reviews = append(f.tx.reviews, fakeDue{review: r, retryAt: retryAt})
	return r
}

func reviewItem(plan Plan) (PlanItem, int) {
	count := 0
	var found PlanItem
	for _, item := range plan.Items {
		if item.Review {
			count++
			found = item
		}
	}
	return found, count
}

func TestTodayDoesNotAttachReviewBeforeDeadline(t *testing.T) {
	f := setupToday(t)
	f.armReview(uuid.New(), f.tx.now.Add(time.Microsecond))

	plan := f.today(t)
	if _, count := reviewItem(plan); count != 0 {
		t.Fatalf("review attached before deadline: %+v", plan)
	}
	if f.tx.updates != 0 {
		t.Fatalf("plan rewritten before deadline: %d", f.tx.updates)
	}
	for i := range plan.Items {
		if plan.Items[i].ID != f.plan.Items[i].ID || plan.Items[i].ContentID != f.plan.Items[i].ContentID {
			t.Fatalf("ordinary plan changed: got=%+v want=%+v", plan.Items, f.plan.Items)
		}
	}
}

func TestTodayAttachesReviewAtDeadlineAndStaysIdempotent(t *testing.T) {
	f := setupToday(t)
	// Earlier in the same local day the user already opened the normal plan.
	first := f.today(t)
	if _, count := reviewItem(first); count != 0 {
		t.Fatalf("review attached before deadline: %+v", first)
	}
	originalAt := *first.AssessmentID

	level := uuid.New()
	due := f.armReview(level, f.tx.now) // exactly due: retry_at == now

	second := f.today(t)
	review, count := reviewItem(second)
	if count != 1 {
		t.Fatalf("review count=%d plan=%+v", count, second)
	}
	if review.Kind != KindLevel || review.ContentID != level || review.ReviewActivityID == nil || *review.ReviewActivityID != due.ActivityID {
		t.Fatalf("review item=%+v", review)
	}
	if review.ID != PlanItemID(f.user, f.day, KindLevel, level) {
		t.Fatalf("review item id=%s", review.ID)
	}
	if second.Day != f.day || second.AssessmentID == nil || *second.AssessmentID != originalAt || len(second.Items) != 5 {
		t.Fatalf("plan identity changed: %+v", second)
	}
	if !second.Items[0].Completed {
		t.Fatalf("completed item lost: %+v", second.Items[0])
	}
	for i := range first.Items {
		if first.Items[i] != second.Items[i] {
			t.Fatalf("ordinary item %d changed: got=%+v want=%+v", i, second.Items[i], first.Items[i])
		}
	}
	if f.tx.updates != 1 {
		t.Fatalf("first attach updates=%d", f.tx.updates)
	}

	third := f.today(t)
	if f.tx.updates != 1 {
		t.Fatalf("repeated GET rewrote plan: updates=%d", f.tx.updates)
	}
	again, count := reviewItem(third)
	if count != 1 || again.ID != review.ID || *again.ReviewActivityID != *review.ReviewActivityID || len(third.Items) != 5 {
		t.Fatalf("repeated GET changed review: %+v", third)
	}
}

func TestTodayAppendsReviewWhenOrdinaryLevelAlreadyCompleted(t *testing.T) {
	f := setupToday(t)
	f.plan.Items[1].Completed = true
	sealed, err := f.svc.sealPlan(f.plan, f.user, f.day)
	if err != nil {
		t.Fatal(err)
	}
	f.tx.planEnc = sealed
	dueLevel := uuid.New()
	f.armReview(dueLevel, f.tx.now.Add(-time.Hour))

	plan := f.today(t)
	review, count := reviewItem(plan)
	if count != 1 || review.ContentID != dueLevel || len(plan.Items) != 5 {
		t.Fatalf("due review not appended: %+v", plan)
	}
	if !plan.Items[1].Completed || plan.Items[1].ContentID != f.plan.Items[1].ContentID {
		t.Fatalf("completed ordinary item lost: %+v", plan.Items[1])
	}
}

func TestTodayReusesSameLevelItemInsteadOfDuplicating(t *testing.T) {
	f := setupToday(t)
	f.armReview(f.plan.Items[1].ContentID, f.tx.now.Add(-time.Hour))

	plan := f.today(t)
	if _, count := reviewItem(plan); count != 0 || len(plan.Items) != 4 {
		t.Fatalf("same level duplicated: %+v", plan)
	}
	if plan.Items[1] != f.plan.Items[1] {
		t.Fatalf("ordinary level item changed: %+v", plan.Items[1])
	}
	if f.tx.updates != 0 {
		t.Fatalf("plan rewritten: %d", f.tx.updates)
	}
}

func reviewFor(plan Plan, activity uuid.UUID) (PlanItem, bool) {
	for _, item := range plan.Items {
		if item.Review && item.ReviewActivityID != nil && *item.ReviewActivityID == activity {
			return item, true
		}
	}
	return PlanItem{}, false
}

func reviewsOf(plan Plan) []PlanItem {
	var out []PlanItem
	for _, item := range plan.Items {
		if item.Review {
			out = append(out, item)
		}
	}
	return out
}

func TestTodayAppendsEveryDistinctDueReviewAcrossDeadlines(t *testing.T) {
	f := setupToday(t)
	first := f.armReview(uuid.New(), f.tx.now.Add(-2*time.Hour))
	later := f.armReview(uuid.New(), f.tx.now.Add(time.Minute))

	plan := f.today(t)
	if got := reviewsOf(plan); len(got) != 1 || *got[0].ReviewActivityID != first.ActivityID || len(plan.Items) != 5 {
		t.Fatalf("first due review=%+v plan=%+v", got, plan)
	}
	if prior := reviewsOf(f.today(t)); len(prior) != 1 || *prior[0].ReviewActivityID != first.ActivityID || f.tx.updates != 1 {
		t.Fatalf("repeated GET before second deadline changed plan: updates=%d", f.tx.updates)
	}

	f.tx.now = f.tx.now.Add(time.Minute) // second source reaches its own deadline
	both := f.today(t)
	got := reviewsOf(both)
	if len(got) != 2 || len(both.Items) != 6 || f.tx.updates != 2 {
		t.Fatalf("later due review blocked: reviews=%+v updates=%d", got, f.tx.updates)
	}
	if *got[0].ReviewActivityID != first.ActivityID || *got[1].ReviewActivityID != later.ActivityID {
		t.Fatalf("wrong due sources: %+v", got)
	}
	if got[0].ContentID == got[1].ContentID {
		t.Fatalf("distinct levels collapsed: %+v", got)
	}
	again := f.today(t)
	if len(reviewsOf(again)) != 2 || f.tx.updates != 2 || len(again.Items) != 6 {
		t.Fatalf("repeated GET duplicated or rewrote: %+v updates=%d", again, f.tx.updates)
	}
}

func TestTodayDeduplicatesTwoDueSourcesOnSameLevel(t *testing.T) {
	f := setupToday(t)
	level := uuid.New()
	first := f.armReview(level, f.tx.now.Add(-time.Hour))
	second := f.armReview(level, f.tx.now)

	plan := f.today(t)
	got := reviewsOf(plan)
	if len(got) != 1 || len(plan.Items) != 5 || *got[0].ReviewActivityID != first.ActivityID {
		t.Fatalf("same level duplicated: %+v", got)
	}
	if second.ActivityID == first.ActivityID {
		t.Fatal("fixture reused the source id")
	}
	if again := f.today(t); len(reviewsOf(again)) != 1 || f.tx.updates != 1 {
		t.Fatalf("repeated GET duplicated same-level review: updates=%d", f.tx.updates)
	}
}

func TestTodayLeavesOrdinaryPlanAndRepeatedGetUnchanged(t *testing.T) {
	f := setupToday(t)
	first := f.today(t)
	second := f.today(t)
	if f.tx.updates != 0 {
		t.Fatalf("ordinary plan rewritten: %d", f.tx.updates)
	}
	for i := range first.Items {
		if first.Items[i] != second.Items[i] {
			t.Fatalf("repeated GET changed item %d: %+v != %+v", i, first.Items[i], second.Items[i])
		}
	}
}
