package reviews

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

func Decoder(f *fieldcrypt.Cipher) func(privacy.ScoreSource) (events.ScoreValues, error) {
	return func(src privacy.ScoreSource) (events.ScoreValues, error) {
		if src.Kind != "review" {
			return events.ScoreValues{}, errors.New("unsupported score source")
		}
		b, e := f.Open(src.Detail, aad(src.UserID, src.SourceID, "score"))
		if e != nil {
			return events.ScoreValues{}, e
		}
		var full scoring.Full
		if e = json.Unmarshal(b, &full); e != nil {
			return events.ScoreValues{}, e
		}
		return full.Values(), nil
	}
}
func (s *Service) deliver(ctx context.Context, k privacy.ScoreKey) error {
	return s.Bus.PublishPendingScore(ctx, k, func(tx pgx.Tx) (bool, error) {
		tag, e := tx.Exec(ctx, `update review_requests set score_pending=false where activity_id=$1 and score_pending`, k.ActivityID)
		return tag.RowsAffected() == 1, e
	})
}
func (s *Service) ReplayPending(ctx context.Context) error {
	if e := s.purgeExpiredGenerated(ctx); e != nil {
		return e
	}
	if !s.Bus.ScoreCompleted.HasSubscribers() {
		return nil
	}
	var after uuid.UUID
	var first error
	for {
		rows, e := s.DB.Query(ctx, `select r.user_id,r.activity_id,s.id,s.occurred_at from review_requests r join scores s on s.activity_id=r.activity_id where r.score_pending and r.activity_id>$1 and s.occurred_at>now()-interval '720 hours' order by r.activity_id limit 64`, after)
		if e != nil {
			return e
		}
		keys, e := pgx.CollectRows(rows, func(row pgx.CollectableRow) (privacy.ScoreKey, error) {
			v := privacy.ScoreKey{Kind: "review"}
			e := row.Scan(&v.UserID, &v.ActivityID, &v.SourceID, &v.OccurredAt)
			return v, e
		})
		if e != nil {
			return e
		}
		for _, k := range keys {
			after = k.ActivityID
			if e = s.deliver(ctx, k); e != nil && first == nil {
				first = e
			}
		}
		if len(keys) < 64 {
			return first
		}
	}
}
