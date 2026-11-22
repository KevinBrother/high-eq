package events

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/privacy"
)

// Claim belongs to the source module. Acknowledgement rolls back with any
// subscriber failure; replay and delete/recreate cannot consume a stale key.
func (b *Bus) DeliverPracticeScore(ctx context.Context, key privacy.ScoreKey, claim func(pgx.Tx) (bool, error)) error {
	if b.decode == nil || key.Kind != "practice" {
		return errors.New("practice score decoder unavailable")
	}
	return b.guard.ConsumeScore(ctx, key, func(ctx context.Context, tx pgx.Tx, src privacy.ScoreSource) error {
		ok, e := claim(tx)
		if e != nil || !ok {
			return e
		}
		v, e := b.decode(src)
		if e != nil {
			return e
		}
		return b.ScoreCompleted.dispatch(ctx, tx, Score{src.ScoreKey, v})
	})
}
func (b *Bus) DeliverPracticeDrill(ctx context.Context, v Drill, claim func(pgx.Tx) (bool, error)) error {
	return b.guard.Access(ctx, v.UserID, func(tx pgx.Tx) error {
		ok, e := claim(tx)
		if e != nil || !ok {
			return e
		}
		return b.DrillProgressed.dispatch(ctx, tx, v)
	})
}
