package training

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

func Decoder(f *fieldcrypt.Cipher, next func(privacy.ScoreSource) (events.ScoreValues, error)) func(privacy.ScoreSource) (events.ScoreValues, error) {
	return func(src privacy.ScoreSource) (events.ScoreValues, error) {
		var v scoring.Full
		if src.Kind != "practice" {
			if next != nil {
				return next(src)
			}
			return events.ScoreValues{}, errors.New("unsupported score source")
		}
		e := (&Service{Fields: f}).open(src.UserID, src.SourceID, "score", src.Detail, &v)
		return v.Values(), e
	}
}
func (s *Service) deliver(ctx context.Context, u, id uuid.UUID) error {
	var key privacy.ScoreKey
	var drill events.Drill
	var pending bool
	e := s.Data.Access(ctx, u, func(tx pgx.Tx) error {
		var at time.Time
		e := tx.QueryRow(ctx, `select w.delivery_pending, a.kind,a.source_id,w.completed_at from practice_work w join activities a on a.id=w.activity_id where a.id=$1 and user_id=$2 and w.completed_at>now()-interval '720 hours' and a.state='complete'`, id, u).Scan(&pending, &key.Kind, &key.SourceID, &at)
		if e != nil || !pending {
			return e
		}
		key.UserID, key.ActivityID, key.OccurredAt = u, id, at
		if key.Kind == "drill" {
			if !s.Bus.DrillProgressed.HasSubscribers() {
				return nil
			}
			r, e := s.load(ctx, tx, u, id)
			if e != nil {
				return e
			}
			drill = events.Drill{UserID: u, ActivityID: id, LevelID: *r.Level, OccurredAt: at, TargetItem: *r.Target, Score: r.Result.Progress.Score}
		}
		return nil
	})
	if e != nil || !pending {
		return e
	}
	claim := func(tx pgx.Tx) (bool, error) {
		tag, e := tx.Exec(ctx, `update practice_work set delivery_pending=false where delivery_pending and completed_at=$4 and completed_at>clock_timestamp()-interval '720 hours' and activity_id in (select id from activities where id=$1 and user_id=$2 and source_id=$3 and state='complete')`, id, u, key.SourceID, key.OccurredAt)
		return tag.RowsAffected() == 1, e
	}
	if key.Kind == "drill" {
		if !s.Bus.DrillProgressed.HasSubscribers() {
			return nil
		}
		return s.Bus.DeliverPracticeDrill(ctx, drill, claim)
	}
	if !s.Bus.ScoreCompleted.HasSubscribers() {
		return nil
	}
	return s.Bus.DeliverPracticeScore(ctx, key, claim)
}

// At-least-once delivery; consumers deduplicate by immutable source key. Scan keys only.
func (s *Service) ReplayPending(ctx context.Context) error {
	var after uuid.UUID
	var failed bool
	type candidate struct {
		user, id uuid.UUID
		worker   *uuid.UUID
	}
	for {
		rows, e := s.DB.Query(ctx, `select a.user_id,a.id,w.worker from practice_work w join activities a on a.id=w.activity_id
            where (w.settlement_pending or (w.worker is not null and a.state in ('safety','moderation_unavailable','failed')))
            and a.id>$1 order by a.id limit 64`, after)
		if e != nil {
			return e
		}
		batch, e := pgx.CollectRows(rows, func(r pgx.CollectableRow) (v candidate, e error) {
			e = r.Scan(&v.user, &v.id, &v.worker)
			return
		})
		if e != nil {
			return e
		}
		for _, pair := range batch {
			after = pair.id
			if pair.worker == nil {
				failed = true
				continue
			}
			if e := s.settlePending(ctx, pair.user, pair.id, uuid.Nil, *pair.worker); e != nil {
				failed = true
			}
		}
		if len(batch) < 64 {
			break
		}
	}
	if !s.Bus.ScoreCompleted.HasSubscribers() && !s.Bus.DrillProgressed.HasSubscribers() {
		if failed {
			return errors.New("practice settlement pending")
		}
		return nil
	}
	after = uuid.Nil
	for {
		rows, e := s.DB.Query(ctx, `select user_id,id from practice_work join activities on id=activity_id where delivery_pending and completed_at>now()-interval '720 hours' and id>$1 order by id limit 64`, after)
		if e != nil {
			return e
		}
		batch, e := pgx.CollectRows(rows, func(r pgx.CollectableRow) (v [2]uuid.UUID, e error) { e = r.Scan(&v[0], &v[1]); return })
		if e != nil {
			return e
		}
		for _, pair := range batch {
			after = pair[1]
			if e := s.deliver(ctx, pair[0], pair[1]); e != nil {
				failed = true
			}
		}
		if len(batch) < 64 {
			break
		}
	}
	if failed {
		return errors.New("practice settlement or delivery pending")
	}
	return nil
}
