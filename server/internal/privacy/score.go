package privacy

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type ScoreKey struct {
	UserID     uuid.UUID `json:"user_id"`
	ActivityID uuid.UUID `json:"activity_id"`
	SourceID   uuid.UUID `json:"source_id"`
	Kind       string    `json:"kind"`
	OccurredAt time.Time `json:"occurred_at"`
}
type ScoreSource struct {
	ScoreKey
	Detail []byte
}
type ScoreHandler func(context.Context, pgx.Tx, ScoreSource) error

// Read canonical encrypted details, ownership, kind and time from the source;
// never project values supplied by a replay. All subscribers share this tx.
func (c *Coordinator) ConsumeScore(ctx context.Context, key ScoreKey, h ScoreHandler) error {
	return c.Access(ctx, key.UserID, func(tx pgx.Tx) error {
		src := ScoreSource{ScoreKey: key}
		e := tx.QueryRow(ctx, `select s.detail_enc from activities a join scores s on s.activity_id=a.id and s.id=a.source_id where a.user_id=$1 and a.id=$2 and s.id=$3 and a.kind=$4 and a.kind in ('practice','review') and a.state='complete' and s.occurred_at=$5 and s.occurred_at>clock_timestamp()-interval '720 hours' and s.occurred_at<=clock_timestamp() for update of a,s`, key.UserID, key.ActivityID, key.SourceID, key.Kind, key.OccurredAt).Scan(&src.Detail)
		if e != nil {
			return e
		}
		return h(ctx, tx, src)
	})
}
