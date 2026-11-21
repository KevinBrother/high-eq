package assessment

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/events"
)

// ReplayPending scans only delivery keys; PublishAssessment rechecks ownership,
// deletion and freeze under lock before it reads or delivers anything. Failed
// rows do not prevent other accounts' events from being delivered.
func (s *Service) ReplayPending(ctx context.Context) error {
	if !s.bus.AssessmentCompleted.HasSubscribers() {
		return nil
	}
	var after uuid.UUID
	var failed bool
	for {
		rows, e := s.db.Query(ctx, `select user_id,id from assessments where completion_pending and id>$1 order by id limit 100`, after)
		if e != nil {
			return e
		}
		batch, e := pgx.CollectRows(rows, func(row pgx.CollectableRow) (v events.Assessment, e error) {
			e = row.Scan(&v.UserID, &v.AssessmentID)
			return
		})
		if e != nil {
			return e
		}
		for _, v := range batch {
			if e = s.bus.PublishAssessment(ctx, v); e != nil {
				failed = true
			}
			after = v.AssessmentID
		}
		if len(batch) < 100 {
			break
		}
	}
	if failed {
		return errors.New("assessment delivery pending")
	}
	return nil
}
