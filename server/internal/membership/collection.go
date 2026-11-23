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
	start, e := s.CollectionStart(ctx, tx, user, s.now())
	if e != nil {
		return e
	}
	if at.Before(start) {
		return ErrForbidden
	}
	return nil
}

// CollectionStart requires current collection rights and returns the start of
// the verified continuous period at now.
func (s *Service) CollectionStart(ctx context.Context, tx pgx.Tx, user uuid.UUID, now time.Time) (time.Time, error) {
	a, e := s.accessAt(ctx, tx, user, now)
	if e != nil {
		return time.Time{}, e
	}
	if !a.allows(Collection) || a.start == nil {
		return time.Time{}, ErrForbidden
	}
	return *a.start, nil
}
