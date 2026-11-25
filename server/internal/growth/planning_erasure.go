package growth

import (
	"context"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/privacy"
)

// Only the encrypted plan carries this attribution. The public plan and ZIP
// use explicit field lists and never emit completion source IDs.
type planCompletion struct {
	Practices     []practiceCompletion `json:"practices,omitempty"`
	ManualAt      *time.Time           `json:"manual_at,omitempty"`
	ManualUnknown bool                 `json:"manual_unknown,omitempty"`
}

type practiceCompletion struct {
	ActivityID uuid.UUID `json:"activity_id"`
	ItemID     uuid.UUID `json:"item_id"`
	At         time.Time `json:"at"`
}

func (c *planCompletion) addPractice(v practiceCompletion) bool {
	for _, existing := range c.Practices {
		if existing.ActivityID == v.ActivityID {
			return false
		}
	}
	c.Practices = append(c.Practices, v)
	return true
}

func (s *PlanService) savePlanCompletion(ctx context.Context, tx pgx.Tx, user uuid.UUID, plan Plan, at *time.Time) error {
	sealed, err := s.sealPlan(plan, user, plan.Day)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `update daily_plans set plan_enc=$3,completed_at=$4,completed_without_timestamp=$5
where user_id=$1 and plan_day=$2`, user, plan.Day, sealed, at, at == nil && plan.completion.ManualUnknown)
	return err
}

type practiceSource struct {
	ID    uuid.UUID
	Level *uuid.UUID
	At    time.Time
}

func (s *PlanService) erasePracticeContributions(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
	if d.Scope != "sessions" && d.Scope != "contacts" {
		return nil
	}
	rows, err := tx.Query(ctx, `select a.id from activities a join practice_work w on w.activity_id=a.id
where a.user_id=$1 and a.state='complete' and a.kind in ('practice','drill')
and (($2='sessions' and a.source_id=$3) or ($2='contacts' and a.contact_id=$3))`, d.UserID, d.Scope, d.SourceID)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil || len(ids) == 0 {
		return err
	}
	deleted := make(map[uuid.UUID]bool, len(ids))
	for _, id := range ids {
		deleted[id] = true
	}
	zone, err := s.timezone(ctx, tx, d.UserID)
	if err != nil {
		return err
	}
	return s.retractPracticeContributions(ctx, tx, d.UserID, zone, deleted)
}

func (s *PlanService) retractPracticeContributions(ctx context.Context, tx pgx.Tx, user uuid.UUID, zone string, deleted map[uuid.UUID]bool) error {
	type stored struct {
		day    string
		sealed []byte
		at     *time.Time
	}
	var after *string
	for {
		rows, err := tx.Query(ctx, `select plan_day::text,plan_enc,completed_at from daily_plans
where user_id=$1 and ($2::date is null or plan_day>$2) order by plan_day limit 50 for update`, user, after)
		if err != nil {
			return err
		}
		batch, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (v stored, err error) {
			err = row.Scan(&v.day, &v.sealed, &v.at)
			return
		})
		if err != nil {
			return err
		}
		for _, v := range batch {
			plan, err := s.openPlan(v.sealed, user, v.day)
			if err != nil {
				return err
			}
			if err := s.attributePlan(ctx, tx, user, zone, &plan, v.at); err != nil {
				return err
			}
			at, changed := plan.retractPractices(deleted, v.at)
			if changed {
				if err := s.savePlanCompletion(ctx, tx, user, plan, at); err != nil {
					return err
				}
			}
			after = &v.day
		}
		if len(batch) < 50 {
			return nil
		}
	}
}

func (p *Plan) retractPractices(deleted map[uuid.UUID]bool, at *time.Time) (*time.Time, bool) {
	changed, removedCheckIn := false, false
	affectedItems := make(map[uuid.UUID]bool)
	p.completion.Practices = slices.DeleteFunc(p.completion.Practices, func(v practiceCompletion) bool {
		if !deleted[v.ActivityID] {
			return false
		}
		affectedItems[v.ItemID] = true
		removedCheckIn = removedCheckIn || at != nil && at.Equal(v.At)
		return true
	})
	// A review that replaced the plan's single-practice slot keeps the item and
	// merely loses its link. An appended review was never an ordinary item, so
	// deleting its source must remove it rather than leave a fake normal item.
	firstLevel := -1
	for i := range p.Items {
		if p.Items[i].Kind == KindLevel {
			firstLevel = i
			break
		}
	}
	kept := p.Items[:0]
	for i := range p.Items {
		item := p.Items[i]
		if item.ReviewActivityID != nil && deleted[*item.ReviewActivityID] {
			changed = true
			if i == firstLevel {
				item.Review, item.ReviewActivityID = false, nil
			} else {
				continue
			}
		}
		if affectedItems[item.ID] {
			item.Completed = slices.ContainsFunc(p.completion.Practices, func(v practiceCompletion) bool {
				return v.ItemID == item.ID
			})
			changed = true
		}
		kept = append(kept, item)
	}
	p.Items = kept
	if len(affectedItems) != 0 && (at == nil || removedCheckIn || !p.hasCompletedItem()) {
		at = p.completion.earliest()
	}
	return at, changed
}

func (p Plan) hasCompletedItem() bool {
	return slices.ContainsFunc(p.Items, func(item PlanItem) bool { return item.Completed })
}

func (c planCompletion) earliest() *time.Time {
	first := c.ManualAt
	for _, v := range c.Practices {
		if first == nil || v.At.Before(*first) {
			at := v.At
			first = &at
		}
	}
	return first
}

// Older encrypted plans have flags and the first check-in only. Reconstruct
// their level attribution from the delivered canonical sources. A manual flag
// still proves a check-in day even when its precise timestamp cannot be known.
func (s *PlanService) attributePlan(ctx context.Context, tx pgx.Tx, user uuid.UUID, zone string, plan *Plan, at *time.Time) error {
	if plan.completion != nil {
		return nil
	}
	completion := &planCompletion{}
	levels := make(map[uuid.UUID]uuid.UUID)
	for _, item := range plan.Items {
		if !item.Completed {
			continue
		}
		if item.Kind == KindLevel {
			levels[item.ContentID] = item.ID
		} else {
			completion.ManualUnknown = true
		}
	}
	if len(levels) != 0 {
		sources, err := s.deliveredPractices(ctx, tx, user, plan.Day, zone, at)
		if err != nil {
			return err
		}
		for _, source := range sources {
			if source.Level != nil && levels[*source.Level] != uuid.Nil {
				completion.addPractice(practiceCompletion{ActivityID: source.ID, ItemID: levels[*source.Level], At: source.At})
			}
		}
	}
	if completion.ManualUnknown && at != nil && !slices.ContainsFunc(completion.Practices, func(v practiceCompletion) bool {
		return at.Equal(v.At)
	}) {
		completion.ManualAt, completion.ManualUnknown = at, false
	}
	plan.completion = completion
	return nil
}

func (s *PlanService) deliveredPractices(ctx context.Context, tx pgx.Tx, user uuid.UUID, day, zone string, first *time.Time) ([]practiceSource, error) {
	loc, err := time.LoadLocation(zone)
	if err != nil {
		return nil, err
	}
	start, err := time.ParseInLocation(time.DateOnly, day, loc)
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, `select a.id,coalesce(d.occurred_at,sc.occurred_at),d.level_id
from activities a join practice_work w on w.activity_id=a.id
left join growth_drill_schedules d on d.activity_id=a.id
left join (scores sc join growth_scores g on g.score_id=sc.id) on sc.activity_id=a.id
where a.user_id=$1 and a.state='complete' and a.kind in ('practice','drill')
and (coalesce(d.occurred_at,sc.occurred_at)>=$2 and coalesce(d.occurred_at,sc.occurred_at)<$3
     or coalesce(d.occurred_at,sc.occurred_at)=$4)`, user, start, start.AddDate(0, 0, 1), first)
	if err != nil {
		return nil, err
	}
	sources, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (v practiceSource, err error) {
		err = row.Scan(&v.ID, &v.At, &v.Level)
		return
	})
	if err != nil {
		return nil, err
	}
	for i := range sources {
		v := &sources[i]
		if v.Level == nil {
			if s.Activities == nil {
				return nil, ErrUnavailable
			}
			level, err := s.Activities.ActivityLevel(ctx, tx, user, v.ID)
			if err != nil {
				return nil, err
			}
			v.Level = &level
		}
	}
	return sources, nil
}
