package membership

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// RequireCollectionFrom checks the same verified continuous period as Require,
// so a new subscription cannot authorize backfill across a membership lapse.
func (s *Service) RequireCollectionFrom(ctx context.Context, tx pgx.Tx, user uuid.UUID, at time.Time) error {
	a, e := s.access(ctx, tx, user)
	if e != nil {
		return e
	}
	if !a.allows(Collection) || a.start == nil || at.Before(*a.start) {
		return ErrForbidden
	}
	return nil
}
