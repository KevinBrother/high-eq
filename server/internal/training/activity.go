package training

import (
	"context"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// ActivityLevel is the source-owner adapter used by consumers that need the
// catalog level pinned in a completed practice setup. It reads through the
// existing setup decryptor and never opens its own transaction.
func (s *Service) ActivityLevel(ctx context.Context, tx pgx.Tx, user, activityID uuid.UUID) (uuid.UUID, error) {
	if s == nil || tx == nil || user == uuid.Nil || activityID == uuid.Nil {
		return uuid.Nil, ErrMissing
	}
	r, err := s.load(ctx, tx, user, activityID)
	if err != nil {
		return uuid.Nil, err
	}
	if r.kind != "practice" {
		return uuid.Nil, ErrMissing
	}
	if r.Level == nil {
		return uuid.Nil, nil
	}
	return *r.Level, nil
}
