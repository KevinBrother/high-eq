package growth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/assessment"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/membership"
)

var (
	ErrInvalid     = errors.New("invalid growth request")
	ErrNotFound    = errors.New("growth content not found")
	ErrUnavailable = errors.New("growth dependency unavailable")
)

// ResultReader reads the canonical, still-owned WLEIS result inside the T03
// event transaction. Implementations must never open their own transaction.
type ResultReader interface {
	ReadResult(context.Context, pgx.Tx, uuid.UUID, uuid.UUID) (assessment.Result, error)
}

// LevelResolver is the T19 boundary. Single is the weakest/target-item level;
// Full is the scene level. T26 does not carry fallback IDs for either.
type LevelResolver interface {
	PlanLevels(context.Context, pgx.Tx, uuid.UUID, string, string) (LevelIDs, error)
}

// ActivityLevelReader resolves the pinned catalog level of a completed source
// activity. The source owner decrypts its own setup envelope; T26 must not
// interpret T19 ciphertext directly.
type ActivityLevelReader interface {
	ActivityLevel(context.Context, pgx.Tx, uuid.UUID, uuid.UUID) (uuid.UUID, error)
}

// ProfileProvider is the T25 boundary. It may only read a scene after the
// caller has proved the personal-plan capability.
type ProfileProvider interface {
	AuthorizedScene(context.Context, pgx.Tx, uuid.UUID) (string, bool, error)
}

type MembershipGate interface {
	Require(context.Context, pgx.Tx, uuid.UUID, membership.Capability) error
}

type PlanDependencies struct {
	Fields     *fieldcrypt.Cipher
	Results    ResultReader
	Levels     LevelResolver
	Activities ActivityLevelReader
	Profiles   ProfileProvider
	Membership MembershipGate
}

type PlanService struct {
	Fields     *fieldcrypt.Cipher
	Results    ResultReader
	Levels     LevelResolver
	Activities ActivityLevelReader
	Profiles   ProfileProvider
	Membership MembershipGate
	Content    Content
}

func NewPlanService(d PlanDependencies) (*PlanService, error) {
	content, err := LoadContent()
	if err != nil {
		return nil, err
	}
	if d.Fields == nil || d.Results == nil {
		return nil, ErrUnavailable
	}
	return &PlanService{Fields: d.Fields, Results: d.Results, Levels: d.Levels, Activities: d.Activities, Profiles: d.Profiles, Membership: d.Membership, Content: content}, nil
}

type PlanProgress struct {
	Streak       int   `json:"streak"`
	Achievements []int `json:"achievements"`
}

type GrowthSummary struct {
	Reference
	Streak       int   `json:"streak"`
	Achievements []int `json:"achievements"`
}

type drillReview struct {
	ActivityID uuid.UUID
	LevelID    uuid.UUID
	Focus      string
}

func (s *PlanService) ConsumeAssessment(ctx context.Context, tx pgx.Tx, v events.Assessment) error {
	if s == nil || tx == nil || s.Fields == nil || s.Results == nil || v.UserID == uuid.Nil || v.AssessmentID == uuid.Nil {
		return ErrInvalid
	}
	// Repeat delivery short-circuits before profile/canonical reads; the
	// one-plan-per-day primary key is the durable concurrency backstop.
	exists, err := s.hasAssessmentPlan(ctx, tx, v.UserID, v.AssessmentID)
	if err != nil || exists {
		return err
	}
	result, err := s.Results.ReadResult(ctx, tx, v.UserID, v.AssessmentID)
	if err != nil {
		return err
	}
	_, err = s.generatePlan(ctx, tx, v.UserID, v.AssessmentID, result, result.CompletedAt, false)
	return err
}

func (s *PlanService) Today(ctx context.Context, tx pgx.Tx, user uuid.UUID) (Plan, error) {
	if s == nil || tx == nil || s.Fields == nil || user == uuid.Nil {
		return Plan{}, ErrInvalid
	}
	now, zone, err := s.current(ctx, tx, user)
	if err != nil {
		return Plan{}, err
	}
	day, err := localDay(now, zone)
	if err != nil {
		return Plan{}, err
	}
	if p, ok, err := s.readDayPlan(ctx, tx, user, day); err != nil || ok {
		return p, err
	}
	var assessmentID uuid.UUID
	err = tx.QueryRow(ctx, `select id from assessments where user_id=$1 order by completed_at desc,id desc limit 1`, user).Scan(&assessmentID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Plan{Day: day, Items: []PlanItem{}}, nil
	}
	if err != nil {
		return Plan{}, err
	}
	result, err := s.Results.ReadResult(ctx, tx, user, assessmentID)
	if err != nil {
		return Plan{}, err
	}
	return s.generatePlan(ctx, tx, user, assessmentID, result, now, true)
}

func (s *PlanService) CompleteItem(ctx context.Context, tx pgx.Tx, user, itemID uuid.UUID) (PlanProgress, error) {
	if s == nil || tx == nil || s.Fields == nil || user == uuid.Nil || itemID == uuid.Nil {
		return PlanProgress{}, ErrInvalid
	}
	now, zone, err := s.current(ctx, tx, user)
	if err != nil {
		return PlanProgress{}, err
	}
	day, err := localDay(now, zone)
	if err != nil {
		return PlanProgress{}, err
	}
	var (
		sealed      []byte
		completedAt *time.Time
	)
	err = tx.QueryRow(ctx, `select plan_enc,completed_at from daily_plans where user_id=$1 and plan_day=$2 for update`, user, day).Scan(&sealed, &completedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return PlanProgress{}, ErrNotFound
	}
	if err != nil {
		return PlanProgress{}, err
	}
	plan, err := s.openPlan(sealed, user, day)
	if err != nil {
		return PlanProgress{}, err
	}
	index := -1
	for i := range plan.Items {
		if plan.Items[i].ID == itemID {
			index = i
			break
		}
	}
	if index < 0 {
		return PlanProgress{}, ErrNotFound
	}
	item := &plan.Items[index]
	if item.Kind == KindLevel {
		// Level completion is owned by real drill/practice events. Once such a
		// source has completed this item, a client retry may read the same
		// progress, but an untouched level cannot be claimed manually.
		if !item.Completed {
			return PlanProgress{}, ErrInvalid
		}
		return s.progress(ctx, tx, user, day)
	}
	if !item.Completed {
		if err := s.attributePlan(ctx, tx, user, zone, &plan, completedAt); err != nil {
			return PlanProgress{}, err
		}
		item.Completed = true
		now = now.UTC()
		if plan.completion.ManualAt == nil {
			plan.completion.ManualAt = &now
		}
		if completedAt == nil {
			completedAt = &now
		}
		if err = s.savePlanCompletion(ctx, tx, user, plan, completedAt); err != nil {
			return PlanProgress{}, err
		}
	}
	return s.progress(ctx, tx, user, day)
}

func (s *PlanService) Growth(ctx context.Context, tx pgx.Tx, user uuid.UUID) (GrowthSummary, error) {
	if s == nil || tx == nil || s.Fields == nil || user == uuid.Nil {
		return GrowthSummary{}, ErrInvalid
	}
	now, zone, err := s.current(ctx, tx, user)
	if err != nil {
		return GrowthSummary{}, err
	}
	day, err := localDay(now, zone)
	if err != nil {
		return GrowthSummary{}, err
	}
	ref, err := (&Service{Fields: s.Fields}).Reference(ctx, tx, user, now)
	if err != nil {
		return GrowthSummary{}, err
	}
	streak, achievements, err := s.achievements(ctx, tx, user, day)
	if err != nil {
		return GrowthSummary{}, err
	}
	return GrowthSummary{Reference: ref, Streak: streak, Achievements: achievements}, nil
}

func (s *PlanService) GetExercise(id uuid.UUID) (Exercise, error) {
	if s == nil || id == uuid.Nil {
		return Exercise{}, ErrInvalid
	}
	for _, exercise := range s.Content.Exercises {
		if exercise.ID == id {
			return exercise, nil
		}
	}
	return Exercise{}, ErrNotFound
}

func (s *PlanService) AnswerExercise(id uuid.UUID, choice int) (bool, string, error) {
	exercise, err := s.GetExercise(id)
	if err != nil {
		return false, "", err
	}
	if choice < 0 || choice >= len(exercise.Choices) {
		return false, "", ErrInvalid
	}
	return choice == exercise.AnswerIndex, exercise.Explanation, nil
}

func (s *PlanService) GetCard(id uuid.UUID) (Card, error) {
	if s == nil || id == uuid.Nil {
		return Card{}, ErrInvalid
	}
	for _, card := range s.Content.Cards {
		if card.ID == id {
			return card, nil
		}
	}
	return Card{}, ErrNotFound
}

type CardPage struct {
	Items      []Card  `json:"items"`
	NextCursor *string `json:"next_cursor"`
}

func (s *PlanService) ListCards(scene, cursor string, limit int) (CardPage, error) {
	if s == nil || (scene != "" && !validScene(scene)) || limit < 1 || limit > 100 {
		return CardPage{}, ErrInvalid
	}
	var after uuid.UUID
	if cursor != "" {
		var err error
		if after, err = uuid.Parse(cursor); err != nil {
			return CardPage{}, ErrInvalid
		}
	}
	cards := make([]Card, 0, len(s.Content.Cards))
	for _, card := range s.Content.Cards {
		if (scene == "" || card.Scene == scene) && (after == uuid.Nil || card.ID.String() > after.String()) {
			cards = append(cards, card)
		}
	}
	sort.Slice(cards, func(i, j int) bool { return cards[i].ID.String() < cards[j].ID.String() })
	page := CardPage{Items: []Card{}}
	if len(cards) > limit {
		page.Items = append(page.Items, cards[:limit]...)
		next := cards[limit-1].ID.String()
		page.NextCursor = &next
	} else {
		page.Items = append(page.Items, cards...)
	}
	return page, nil
}

func (s *PlanService) generatePlan(ctx context.Context, tx pgx.Tx, user, assessmentID uuid.UUID, result assessment.Result, at time.Time, checkDay bool) (Plan, error) {
	if s.Levels == nil {
		return Plan{}, ErrUnavailable
	}
	zone, err := s.timezone(ctx, tx, user)
	if err != nil {
		return Plan{}, err
	}
	day, err := localDay(at, zone)
	if err != nil {
		return Plan{}, err
	}
	if checkDay {
		if p, ok, err := s.readDayPlan(ctx, tx, user, day); err != nil || ok {
			return p, err
		}
	}
	if result.ID != assessmentID || result.CompletedAt.IsZero() {
		return Plan{}, ErrInvalid
	}
	focus := Weakest(wleisFrom(result.Scores))
	review, err := s.dueReview(ctx, tx, user, at)
	if err != nil {
		return Plan{}, err
	}
	reviewTarget := ""
	var reviewLevel *uuid.UUID
	var reviewActivity *uuid.UUID
	if review != nil {
		focus, reviewTarget = review.Focus, review.Focus
		reviewLevel = &review.LevelID
		reviewActivity = &review.ActivityID
	}
	scene, personalized, err := s.planScene(ctx, tx, user, day, focus)
	if err != nil {
		return Plan{}, err
	}
	levels, err := s.Levels.PlanLevels(ctx, tx, user, focus, scene)
	if err != nil {
		return Plan{}, err
	}
	if review != nil {
		levels.Single = review.LevelID
		if levels.Single == uuid.Nil || levels.Full == uuid.Nil || levels.Single == levels.Full {
			return Plan{}, ErrInvalid
		}
	}
	usedExercises, usedCards, err := s.usedContent(ctx, tx, user, day)
	if err != nil {
		return Plan{}, err
	}
	plan, err := BuildPlan(s.Content, PlanInput{
		User:             user,
		Day:              mustDate(day),
		AssessmentID:     assessmentID,
		Scores:           wleisFrom(result.Scores),
		Personalized:     personalized,
		Scene:            scene,
		Levels:           levels,
		UsedExercises:    usedExercises,
		UsedCards:        usedCards,
		ReviewTarget:     reviewTarget,
		ReviewLevelID:    reviewLevel,
		ReviewActivityID: reviewActivity,
	})
	if err != nil {
		return Plan{}, fmt.Errorf("build growth plan: %w", err)
	}
	plan.completion = &planCompletion{}
	sealed, err := s.sealPlan(plan, user, day)
	if err != nil {
		return Plan{}, err
	}
	_, err = tx.Exec(ctx, `insert into daily_plans(user_id,plan_day,plan_enc,assessment_id)
values($1,$2,$3,$4) on conflict(user_id,plan_day) do nothing`, user, day, sealed, assessmentID)
	if err != nil {
		return Plan{}, err
	}
	// A concurrent assessment delivery or Today request may have won the
	// one-plan-per-day insert. Return the durable row rather than the version
	// this transaction attempted to insert.
	stored, ok, err := s.readDayPlan(ctx, tx, user, day)
	if err != nil {
		return Plan{}, err
	}
	if !ok {
		return Plan{}, ErrUnavailable
	}
	return stored, nil
}

func (s *PlanService) planScene(ctx context.Context, tx pgx.Tx, user uuid.UUID, day, focus string) (string, bool, error) {
	scene := sceneFor(user, day, focus)
	if s.Membership == nil {
		return scene, false, nil
	}
	err := s.Membership.Require(ctx, tx, user, membership.PersonalPlan)
	if errors.Is(err, membership.ErrForbidden) {
		return scene, false, nil
	}
	if err != nil {
		return "", false, err
	}
	if s.Profiles == nil {
		return scene, false, nil
	}
	authorized, ok, err := s.Profiles.AuthorizedScene(ctx, tx, user)
	if err != nil || !ok || !validScene(authorized) {
		return scene, false, nil
	}
	return authorized, true, nil
}

func (s *PlanService) dueReview(ctx context.Context, tx pgx.Tx, user uuid.UUID, at time.Time) (*drillReview, error) {
	var out drillReview
	err := tx.QueryRow(ctx, `select d.activity_id,d.level_id,d.target_item
from growth_drill_schedules d join activities a on a.id=d.activity_id and a.kind='drill'
where a.user_id=$1 and a.state='complete' and d.retry_at is not null and d.retry_at<=$2
  and d.closed_at is null
order by d.retry_at,d.activity_id limit 1`, user, at).Scan(&out.ActivityID, &out.LevelID, &out.Focus)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if out.ActivityID == uuid.Nil || out.LevelID == uuid.Nil || !validFocus(out.Focus) {
		return nil, ErrInvalid
	}
	return &out, nil
}

func (s *PlanService) usedContent(ctx context.Context, tx pgx.Tx, user uuid.UUID, day string) (map[uuid.UUID]bool, map[uuid.UUID]bool, error) {
	exercises, cards := map[uuid.UUID]bool{}, map[uuid.UUID]bool{}
	current, err := time.Parse(time.DateOnly, day)
	if err != nil {
		return nil, nil, ErrInvalid
	}
	start := current.AddDate(0, 0, -6).Format(time.DateOnly)
	rows, err := tx.Query(ctx, `select plan_day::text,plan_enc from daily_plans where user_id=$1 and plan_day>=$2 and plan_day<$3 order by plan_day`, user, start, day)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var rawDay string
		var sealed []byte
		if err := rows.Scan(&rawDay, &sealed); err != nil {
			return nil, nil, err
		}
		plan, err := s.openPlan(sealed, user, rawDay)
		if err != nil {
			return nil, nil, err
		}
		for _, item := range plan.Items {
			switch item.Kind {
			case KindExercise:
				exercises[item.ContentID] = true
			case KindCard:
				cards[item.ContentID] = true
			}
		}
	}
	return exercises, cards, rows.Err()
}

func (s *PlanService) hasAssessmentPlan(ctx context.Context, tx pgx.Tx, user, assessmentID uuid.UUID) (bool, error) {
	var exists bool
	err := tx.QueryRow(ctx, `select exists(select 1 from daily_plans where user_id=$1 and assessment_id=$2)`, user, assessmentID).Scan(&exists)
	return exists, err
}

func (s *PlanService) readDayPlan(ctx context.Context, tx pgx.Tx, user uuid.UUID, day string) (Plan, bool, error) {
	var sealed []byte
	err := tx.QueryRow(ctx, `select plan_enc from daily_plans where user_id=$1 and plan_day=$2`, user, day).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return Plan{}, false, nil
	}
	if err != nil {
		return Plan{}, false, err
	}
	plan, err := s.openPlan(sealed, user, day)
	return plan, true, err
}

func (s *PlanService) progress(ctx context.Context, tx pgx.Tx, user uuid.UUID, day string) (PlanProgress, error) {
	streak, achievements, err := s.achievements(ctx, tx, user, day)
	return PlanProgress{Streak: streak, Achievements: achievements}, err
}

func (s *PlanService) achievements(ctx context.Context, tx pgx.Tx, user uuid.UUID, day string) (int, []int, error) {
	rows, err := tx.Query(ctx, `select plan_day::text from daily_plans where user_id=$1
and (completed_at is not null or completed_without_timestamp) order by plan_day`, user)
	if err != nil {
		return 0, nil, err
	}
	defer rows.Close()
	days := []string{}
	for rows.Next() {
		var used string
		if err := rows.Scan(&used); err != nil {
			return 0, nil, err
		}
		days = append(days, used)
	}
	if err := rows.Err(); err != nil {
		return 0, nil, err
	}
	streak, achievements := Achievements(days, day)
	return streak, achievements, nil
}

func (s *PlanService) current(ctx context.Context, tx pgx.Tx, user uuid.UUID) (time.Time, string, error) {
	var now time.Time
	var zone string
	err := tx.QueryRow(ctx, `select clock_timestamp(),timezone from users where id=$1`, user).Scan(&now, &zone)
	return now, zone, err
}

func (s *PlanService) timezone(ctx context.Context, tx pgx.Tx, user uuid.UUID) (string, error) {
	var zone string
	err := tx.QueryRow(ctx, `select timezone from users where id=$1`, user).Scan(&zone)
	return zone, err
}

func localDay(at time.Time, zone string) (string, error) {
	loc, err := time.LoadLocation(zone)
	if err != nil {
		return "", ErrInvalid
	}
	return at.In(loc).Format(time.DateOnly), nil
}

func mustDate(day string) time.Time {
	t, _ := time.Parse(time.DateOnly, day)
	return t
}

func wleisFrom(scores assessment.Scores) WLEIS {
	return WLEIS{
		SEA: scores.Dimensions["SEA"].Percent,
		OEA: scores.Dimensions["OEA"].Percent,
		UOE: scores.Dimensions["UOE"].Percent,
		ROE: scores.Dimensions["ROE"].Percent,
	}
}

func planAAD(user uuid.UUID, day string) []byte {
	return []byte("daily_plans:plan_enc:" + user.String() + ":" + day)
}

type storedPlan struct {
	Plan
	Completion *planCompletion `json:"completion,omitempty"`
}

func (s *PlanService) sealPlan(plan Plan, user uuid.UUID, day string) ([]byte, error) {
	plain, err := json.Marshal(storedPlan{Plan: plan, Completion: plan.completion})
	if err != nil {
		return nil, err
	}
	return s.Fields.Seal(plain, planAAD(user, day))
}

func (s *PlanService) openPlan(sealed []byte, user uuid.UUID, day string) (Plan, error) {
	plain, err := s.Fields.Open(sealed, planAAD(user, day))
	if err != nil {
		return Plan{}, err
	}
	var stored storedPlan
	if err := json.Unmarshal(plain, &stored); err != nil {
		return Plan{}, err
	}
	plan := stored.Plan
	plan.completion = stored.Completion
	if plan.Day != day || len(plan.Items) == 0 {
		return Plan{}, ErrInvalid
	}
	for _, item := range plan.Items {
		if item.ID == uuid.Nil || item.ContentID == uuid.Nil || (item.Kind != KindExercise && item.Kind != KindLevel && item.Kind != KindCard) {
			return Plan{}, ErrInvalid
		}
		if item.Review {
			if item.Kind != KindLevel || item.ReviewActivityID == nil || *item.ReviewActivityID == uuid.Nil {
				return Plan{}, ErrInvalid
			}
		} else if item.ReviewActivityID != nil {
			return Plan{}, ErrInvalid
		}
	}
	return plan, nil
}

// exportPlanData emits the derived plan and drill records separately from the
// source score projection. Every output struct is explicit so false and zero
// values remain visible, while internal activity and plan links never leave
// storage.
func (s *PlanService) exportPlanData(ctx context.Context, tx pgx.Tx, user uuid.UUID, emit func(any) error) error {
	if s == nil || s.Fields == nil || tx == nil || user == uuid.Nil || emit == nil {
		return ErrInvalid
	}
	if err := s.exportPlans(ctx, tx, user, emit); err != nil {
		return err
	}
	return s.exportDrills(ctx, tx, user, emit)
}

func (s *PlanService) exportPlans(ctx context.Context, tx pgx.Tx, user uuid.UUID, emit func(any) error) error {
	rows, err := tx.Query(ctx, `select plan_day::text,plan_enc,assessment_id,completed_at
from daily_plans where user_id=$1 order by plan_day`, user)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			day          string
			sealed       []byte
			assessmentID *uuid.UUID
			completedAt  *time.Time
		)
		if err = rows.Scan(&day, &sealed, &assessmentID, &completedAt); err != nil {
			return err
		}
		plan, err := s.openPlan(sealed, user, day)
		if err != nil {
			return err
		}
		if (plan.AssessmentID == nil) != (assessmentID == nil) || (assessmentID != nil && *plan.AssessmentID != *assessmentID) {
			return errors.New("growth plan assessment mismatch")
		}
		record := PlanExportRecord{
			RecordType:   "plan",
			AssessmentID: assessmentID,
			Day:          day,
			Personalized: plan.Personalized,
			Items:        make([]PlanItemExportRecord, 0, len(plan.Items)),
			CompletedAt:  utcTimePointer(completedAt),
		}
		for _, item := range plan.Items {
			record.Items = append(record.Items, PlanItemExportRecord{
				ID: item.ID, Kind: item.Kind, Title: item.Title, ContentID: item.ContentID, Completed: item.Completed,
			})
		}
		if err = emit(record); err != nil {
			return err
		}
	}
	return rows.Err()
}

func (s *PlanService) exportDrills(ctx context.Context, tx pgx.Tx, user uuid.UUID, emit func(any) error) error {
	rows, err := tx.Query(ctx, `select d.activity_id,d.level_id,d.target_item,d.schedule_enc,d.occurred_at,d.retry_at,d.closed_at
from growth_drill_schedules d
join activities a on a.id=d.activity_id and a.kind='drill'
where a.user_id=$1 and a.state='complete'
order by d.occurred_at,d.activity_id`, user)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var (
			activityID uuid.UUID
			levelID    uuid.UUID
			target     string
			sealed     []byte
			occurredAt time.Time
			retryAt    *time.Time
			closedAt   *time.Time
		)
		if err = rows.Scan(&activityID, &levelID, &target, &sealed, &occurredAt, &retryAt, &closedAt); err != nil {
			return err
		}
		score, band, err := s.openSchedule(sealed, user, activityID)
		if err != nil {
			return err
		}
		if levelID == uuid.Nil || !validFocus(target) || score < 0 || score > 25 || band != Band(score) || occurredAt.IsZero() {
			return errors.New("invalid drill projection")
		}
		if closedAt != nil {
			retryAt = nil
		}
		record := DrillExportRecord{
			RecordType: "drill",
			LevelID:    levelID,
			TargetItem: target,
			Score:      score,
			Band:       band,
			OccurredAt: occurredAt.UTC(),
			RetryAt:    utcTimePointer(retryAt),
		}
		if err = emit(record); err != nil {
			return err
		}
	}
	return rows.Err()
}

func utcTimePointer(v *time.Time) *time.Time {
	if v == nil {
		return nil
	}
	utc := v.UTC()
	return &utc
}
