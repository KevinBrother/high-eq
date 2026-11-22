package service

import (
	"context"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/marks"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/payments"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/profile"
	"high-eq/server/internal/replies"
	"high-eq/server/internal/reviews"
	"high-eq/server/internal/scoring"
	"high-eq/server/internal/training"
	"high-eq/server/migrations"
)

// Runtime is the composition root. Business cards add module inventory and both hooks here.
type Runtime struct {
	Payments             *payments.Service
	Marks                *marks.Service
	Practice             *training.Service
	Profiles             *profile.Service
	Reviews              *reviews.Service
	Emotion              *emotion.Service
	Replies              *replies.Service
	Assessments          *assessment.Service
	catalog              *gateway.Catalog
	db                   *pgxpool.Pool
	cache, registryRedis *redis.Client
	ledger               *privacy.Ledger
	Membership           *membership.Service
	Accounts             *accounts.Service
	Data                 *privacy.Coordinator
	Bus                  *events.Bus
	Fields               *fieldcrypt.Cipher
}

func Start(ctx context.Context, c Config) (*Runtime, error) {
	if c.DatabasePoolMaxConns < 1 || c.DatabasePoolMaxConns > 256 {
		return nil, errors.New("invalid DATABASE_POOL_MAX_CONNS")
	}
	poolConfig, e := pgxpool.ParseConfig(c.DatabaseURL)
	if e != nil {
		return nil, e
	}
	poolConfig.MaxConns = c.DatabasePoolMaxConns
	if e = migrations.Up(ctx, c.DatabaseURL); e != nil {
		return nil, e
	}
	db, e := pgxpool.NewWithConfig(ctx, poolConfig)
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
	sms, exchange, e := accounts.DevelopmentProviders(c.Environment, s.cache)
	if e != nil {
		return nil, e
	}
	s.Membership, e = membership.New(s.cache)
	if e != nil {
		return nil, e
	}
	bank, e := assessment.Load(c.InstrumentPath)
	if e != nil {
		return nil, e
	}
	s.Profiles = &profile.Service{Fields: c.Fields, Rights: s.Membership}
	hooks, e := privacy.NewRegistry(
		[]string{"training", "profiles", "assessments", "payments", "membership", "accounts", "replies", "ai_calls", "emotion", "manual_marks", "reviews"},
		payments.Hooks(), s.Membership.Hooks(), assessment.Hooks(c.Fields), accounts.Hooks(c.Fields),
		training.Hooks(c.Fields), s.Profiles.Hooks(), replies.Hooks(c.Fields), gateway.Hooks(), emotion.Hooks(c.Fields), marks.Hooks(c.Fields), reviews.Hooks(c.Fields),
	)
	if e != nil {
		return nil, e
	}
	s.Data = privacy.NewCoordinator(db, s.ledger, hooks)
	s.Payments, e = payments.New(db, s.Data, c.authMaster, c.PaymentChannels)
	if e != nil {
		return nil, e
	}
	s.Accounts, e = accounts.New(db, s.Data, c.Fields, c.authMaster, sms, exchange)
	if e != nil {
		return nil, e
	}
	if e = s.Data.Resume(ctx); e != nil {
		return nil, e
	}
	if e = s.Accounts.PurgeDue(ctx); e != nil {
		return nil, e
	}
	s.catalog, e = s.StartGateway(ctx)
	if e != nil {
		return nil, e
	}
	s.Profiles.Data = s.Data
	// Profile inference has no quota ledger or score settlement.
	s.Profiles.AI, e = s.catalog.NewRouter(s.Data, func(context.Context, gateway.Scope, gateway.Terminal) error { return nil })
	if e != nil {
		return nil, e
	}
	s.Bus = events.New(s.Data, training.Decoder(c.Fields, reviews.Decoder(c.Fields)))
	s.Bus.ProfileFeedback.Subscribe(s.Profiles.Consume)
	s.Replies = replies.New(s.Accounts, s.Membership, s.Data, c.Fields, s.db, s.Bus, c.authMaster, func(stop gateway.Stop) (replies.Runner, error) { return s.catalog.NewRouter(s.Data, stop) })
	s.Replies.AttachFeedback(s.Profiles)
	s.Replies.AttachProfiles(s.Profiles)
	s.Bus.ReplyOutcome.Subscribe(func(ctx context.Context, tx pgx.Tx, v events.ReplyOutcome) error {
		return s.Profiles.ConsumeReplyOutcome(ctx, tx, v, s.Replies)
	})
	s.initPractice()
	s.Marks = &marks.Service{Fields: c.Fields, DB: s.db, Data: s.Data}
	s.Reviews = &reviews.Service{Accounts: s.Accounts, Rights: s.Membership, Data: s.Data, Fields: c.Fields, DB: s.db, Bus: s.Bus, Key: c.authMaster, Router: func(stop gateway.Stop) (scoring.Runner, error) { return s.catalog.NewRouter(s.Data, stop) }}
	s.Reviews.Profile = s.Profiles
	s.Emotion = &emotion.Service{DB: s.db, Data: s.Data, Fields: c.Fields, Bus: s.Bus}
	s.Assessments = assessment.New(bank, s.Accounts, c.Fields, s.Bus, s.db)
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
func (s *Runtime) Close() {
	if s.catalog != nil {
		s.catalog.Close()
	}
	s.db.Close()
	s.cache.Close()
	s.registryRedis.Close()
}
