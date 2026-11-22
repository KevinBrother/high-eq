package growth

import (
	"context"
	"encoding/json"
	"errors"
	"hash/fnv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/events"
)

type drillScheduleEnvelope struct {
	Score int    `json:"score"`
	Band  string `json:"band"`
}

func scheduleAAD(user, activityID uuid.UUID) []byte {
	return []byte("growth_drill_schedules.schedule_enc/" + user.String() + "/" + activityID.String())
}

func (s *PlanService) sealSchedule(user, activityID uuid.UUID, score int, band string) ([]byte, error) {
	plain, err := json.Marshal(drillScheduleEnvelope{Score: score, Band: band})
	if err != nil {
		return nil, err
	}
	return s.Fields.Seal(plain, scheduleAAD(user, activityID))
}

func (s *PlanService) openSchedule(sealed []byte, user, activityID uuid.UUID) (int, string, error) {
	plain, err := s.Fields.Open(sealed, scheduleAAD(user, activityID))
	if err != nil {
		return 0, "", err
	}
	var v drillScheduleEnvelope
	if err = json.Unmarshal(plain, &v); err != nil {
		return 0, "", err
	}
	if v.Score < 0 || v.Score > 25 || v.Band != Band(v.Score) {
		return 0, "", ErrInvalid
	}
	return v.Score, v.Band, nil
}

// ConsumeDrill records every real drill completion but keeps only the latest
// completion for a user/level/target as schedulable. Rows are never deleted:
// closed_at makes old replay harmless and survives process restarts.
func (s *PlanService) ConsumeDrill(ctx context.Context, tx pgx.Tx, v events.Drill) error {
	if s == nil || tx == nil || s.Fields == nil || v.UserID == uuid.Nil || v.ActivityID == uuid.Nil || v.LevelID == uuid.Nil || !validFocus(v.TargetItem) || v.Score < 0 || v.Score > 25 || v.OccurredAt.IsZero() {
		return ErrInvalid
	}
	occurredAt := v.OccurredAt.UTC()
	if occurredAt.Before(time.Now().UTC().Add(-behaviorWindow)) {
		return ErrInvalid
	}
	band := Band(v.Score)
	var retryAt *time.Time
	if band == ReviewThreeDays {
		// Scores below 10 are immediate coaching feedback, not a queued retry.
		// Only the 10..24 band owns a durable three-day due schedule.
		t := occurredAt.Add(72 * time.Hour)
		retryAt = &t
	}
	sealed, err := s.sealSchedule(v.UserID, v.ActivityID, v.Score, band)
	if err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `select pg_advisory_xact_lock($1)`, scheduleLockKey(v.UserID, v.LevelID, v.TargetItem)); err != nil {
		return err
	}

	// The source event can arrive after a newer completion. In that case the
	// row is still retained as history, but is born closed and can never become
	// an active due item. UUID ordering is only a deterministic tie-breaker for
	// two completions with the same source timestamp.
	var newerAt *time.Time
	err = tx.QueryRow(ctx, `select d.occurred_at
from growth_drill_schedules d
join activities a on a.id=d.activity_id
where a.user_id=$1 and d.level_id=$2 and d.target_item=$3
  and (d.occurred_at>$4 or (d.occurred_at=$4 and d.activity_id>$5))
order by d.occurred_at desc,d.activity_id desc
limit 1`, v.UserID, v.LevelID, v.TargetItem, occurredAt, v.ActivityID).Scan(&newerAt)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	var closedAt *time.Time
	if newerAt != nil {
		t := newerAt.UTC()
		closedAt = &t
	}

	_, err = tx.Exec(ctx, `insert into growth_drill_schedules(activity_id,target_item,level_id,schedule_enc,occurred_at,retry_at,closed_at)
values($1,$2,$3,$4,$5,$6,$7) on conflict(activity_id) do nothing`, v.ActivityID, v.TargetItem, v.LevelID, sealed, occurredAt, retryAt, closedAt)
	if err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `update growth_drill_schedules d
set closed_at=$4
from activities a
where a.id=d.activity_id
  and a.user_id=$1
  and d.level_id=$2
  and d.target_item=$3
  and d.closed_at is null
  and (d.occurred_at<$4 or (d.occurred_at=$4 and d.activity_id<$5))`, v.UserID, v.LevelID, v.TargetItem, occurredAt, v.ActivityID); err != nil {
		return err
	}
	// Closing an out-of-order schedule must not swallow the real completion.
	// Completion is keyed by the source occurrence day and is idempotent, so
	// both delayed first delivery and duplicate replay can safely reach it.
	return s.completeLevelForActivity(ctx, tx, v.UserID, occurredAt, v.LevelID)
}

// ConsumeScore only advances plans for a genuinely completed full practice
// session. Reviews and drill scores are deliberately ignored here.
func (s *PlanService) ConsumeScore(ctx context.Context, tx pgx.Tx, v events.Score) error {
	if v.Kind != "practice" {
		return nil
	}
	if s == nil || tx == nil || s.Fields == nil || s.Activities == nil || v.UserID == uuid.Nil || v.ActivityID == uuid.Nil || v.OccurredAt.IsZero() {
		return ErrInvalid
	}
	occurredAt := v.OccurredAt.UTC()
	if occurredAt.Before(time.Now().UTC().Add(-behaviorWindow)) {
		return ErrInvalid
	}
	levelID, err := s.Activities.ActivityLevel(ctx, tx, v.UserID, v.ActivityID)
	if err != nil {
		return err
	}
	if levelID == uuid.Nil {
		// A custom-scene practice has no catalog level and therefore no plan item.
		return nil
	}
	return s.completeLevelForActivity(ctx, tx, v.UserID, occurredAt, levelID)
}

func scheduleLockKey(user, level uuid.UUID, target string) int64 {
	h := fnv.New64a()
	_, _ = h.Write(user[:])
	_, _ = h.Write([]byte{0})
	_, _ = h.Write(level[:])
	_, _ = h.Write([]byte{0})
	_, _ = h.Write([]byte(target))
	return int64(h.Sum64())
}

func (s *PlanService) completeLevelForActivity(ctx context.Context, tx pgx.Tx, user uuid.UUID, at time.Time, levelID uuid.UUID) error {
	zone, err := s.timezone(ctx, tx, user)
	if err != nil {
		return err
	}
	day, err := localDay(at, zone)
	if err != nil {
		return err
	}
	return s.completeLevelItem(ctx, tx, user, day, levelID, at)
}

func (s *PlanService) completeLevelItem(ctx context.Context, tx pgx.Tx, user uuid.UUID, day string, levelID uuid.UUID, at time.Time) error {
	var (
		sealed      []byte
		completedAt *time.Time
	)
	err := tx.QueryRow(ctx, `select plan_enc,completed_at from daily_plans where user_id=$1 and plan_day=$2 for update`, user, day).Scan(&sealed, &completedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	plan, err := s.openPlan(sealed, user, day)
	if err != nil {
		return err
	}
	found, changed := false, false
	for i := range plan.Items {
		item := &plan.Items[i]
		if item.Kind != KindLevel || item.ContentID != levelID {
			continue
		}
		found = true
		if !item.Completed {
			item.Completed = true
			changed = true
		}
		break
	}
	if !found || !changed && completedAt != nil {
		return nil
	}
	sealed, err = s.sealPlan(plan, user, day)
	if err != nil {
		return err
	}
	if completedAt == nil {
		t := at.UTC()
		completedAt = &t
	}
	_, err = tx.Exec(ctx, `update daily_plans set plan_enc=$3,completed_at=$4 where user_id=$1 and plan_day=$2`, user, day, sealed, completedAt)
	return err
}
