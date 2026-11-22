package growth

import (
	"context"
	"errors"

	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Hooks registers the growth projection partition. Source deletes cascade
// through scores and activities into the derived tables; the delete hook
// verifies those boundaries before the coordinated transaction commits.
func Hooks(fields *fieldcrypt.Cipher) privacy.Module {
	scores := Service{Fields: fields}
	plans := PlanService{Fields: fields}
	return privacy.Module{
		Name: "growth",
		Delete: func(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
			return verifyDeletion(ctx, tx, d)
		},
		Export: func(ctx context.Context, tx pgx.Tx, q privacy.ExportRequest, emit privacy.Emit) error {
			if err := scores.export(ctx, tx, q.UserID, emit); err != nil {
				return err
			}
			return plans.exportPlanData(ctx, tx, q.UserID, emit)
		},
	}
}

func verifyDeletion(ctx context.Context, tx pgx.Tx, d privacy.Deletion) error {
	if tx == nil || d.UserID == uuid.Nil {
		return errors.New("invalid growth deletion")
	}
	if d.Scope == "account" {
		if d.SourceID != uuid.Nil {
			return errors.New("invalid account growth deletion")
		}
		if err := requireAbsent(ctx, tx, `select exists(select 1 from daily_plans where user_id=$1)`, d.UserID); err != nil {
			return err
		}
		// Ownership is only reachable through the cascading source. After an
		// account delete, a surviving projection can therefore be detected as
		// an orphan without persisting a second copy of the account ID.
		if err := requireAbsent(ctx, tx, `select exists(
			select 1 from growth_scores g
			left join scores s on s.id=g.score_id and s.activity_kind=g.kind
			where s.id is null)`); err != nil {
			return err
		}
		return requireAbsent(ctx, tx, `select exists(
			select 1 from growth_drill_schedules d
			left join activities a on a.id=d.activity_id
			where a.id is null)`)
	}
	if d.SourceID == uuid.Nil {
		return errors.New("invalid growth deletion")
	}
	switch d.Scope {
	case "assessments":
		return requireAbsent(ctx, tx, `select exists(select 1 from daily_plans where user_id=$1 and assessment_id=$2)`, d.UserID, d.SourceID)
	case "sessions", "reviews":
		if err := requireAbsent(ctx, tx, `select exists(select 1 from growth_scores where score_id=$1)`, d.SourceID); err != nil {
			return err
		}
		if d.Scope == "sessions" {
			// growth_drill_schedules is keyed by activities.id, while the deletion root
			// supplies activities.source_id. The source row is already gone at
			// this point, so verify the FK result by rejecting orphaned drills.
			return requireAbsent(ctx, tx, `select exists(
				select 1 from growth_drill_schedules d
				left join activities a on a.id=d.activity_id
				where a.id is null)`)
		}
		return nil
	default:
		return nil
	}
}

func requireAbsent(ctx context.Context, tx pgx.Tx, query string, args ...any) error {
	var remains bool
	if err := tx.QueryRow(ctx, query, args...).Scan(&remains); err != nil {
		return err
	}
	if remains {
		return errors.New("growth projection remains after source deletion")
	}
	return nil
}
