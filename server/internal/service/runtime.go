package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/privacy"
	"high-eq/server/migrations"
)

// Runtime is the composition root. Business cards add module inventory and both hooks here.
type Runtime struct {
	db                   *pgxpool.Pool
	cache, registryRedis *redis.Client
	ledger               *privacy.Ledger
	Data                 *privacy.Coordinator
	Bus                  *events.Bus
	Fields               *fieldcrypt.Cipher
}

func Start(ctx context.Context, c Config) (*Runtime, error) {
	if e := migrations.Up(ctx, c.DatabaseURL); e != nil {
		return nil, e
	}
	db, e := pgxpool.New(ctx, c.DatabaseURL)
	if e != nil {
		return nil, e
	}
	s := &Runtime{db: db, cache: redis.NewClient(c.Cache), registryRedis: redis.NewClient(c.Ledger), Fields: c.Fields}
	ok := false
	defer func() {
		if !ok {
			s.Close()
		}
	}()
	a, e := instance(ctx, s.cache)
	if e != nil {
		return nil, e
	}
	b, e := instance(ctx, s.registryRedis)
	if e != nil {
		return nil, e
	}
	if a == b {
		return nil, errors.New("deletion ledger must be an independent instance")
	}
	s.ledger, e = privacy.BindLedger(ctx, db, s.registryRedis, c.BackupDays)
	if e != nil {
		return nil, e
	}
	hooks, e := privacy.NewRegistry(nil)
	if e != nil {
		return nil, e
	}
	s.Data = privacy.NewCoordinator(db, s.ledger, hooks)
	if e = s.Data.Resume(ctx); e != nil {
		return nil, e
	}
	s.Bus = events.New(s.Data, nil)
	ok = true
	return s, nil
}
func instance(ctx context.Context, r *redis.Client) (string, error) {
	info, e := r.Info(ctx, "server").Result()
	if e != nil {
		return "", e
	}
	for line := range strings.SplitSeq(info, "\r\n") {
		if id, ok := strings.CutPrefix(line, "run_id:"); ok && id != "" {
			return id, nil
		}
	}
	return "", errors.New("unknown redis instance")
}
func (s *Runtime) Health(ctx context.Context) error {
	if e := s.db.Ping(ctx); e != nil {
		return e
	}
	if e := s.cache.Ping(ctx).Err(); e != nil {
		return e
	}
	return s.ledger.Check(ctx)
}
func (s *Runtime) Close() { s.db.Close(); s.cache.Close(); s.registryRedis.Close() }
