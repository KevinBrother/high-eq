package training

import (
	"context"
	"errors"

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
	var sealed []byte
	err := tx.QueryRow(ctx, `select a.content_enc
from activities a join practice_work w on w.activity_id=a.id
where a.user_id=$1 and a.id=$2 and a.kind='practice' and a.state='complete'`, user, activityID).Scan(&sealed)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, ErrMissing
	}
	if err != nil {
		return uuid.Nil, err
	}
	var setup setupSnapshot
	if err := s.open(user, activityID, "setup", sealed, &setup); err != nil {
		return uuid.Nil, err
	}
	if setup.Input.Level == nil {
		return uuid.Nil, nil
	}
	return *setup.Input.Level, nil
}
