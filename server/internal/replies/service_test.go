package replies

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
)

type runnerFunc func(context.Context, gateway.Call) (gateway.Reply, error)

func (f runnerFunc) Run(c context.Context, v gateway.Call) (gateway.Reply, error) { return f(c, v) }

func TestTerminalSafetySurvivesAuditFailure(t *testing.T) {
	settled := 0
	s := &Service{newRunner: func(stop gateway.Stop) (Runner, error) {
		return runnerFunc(func(ctx context.Context, c gateway.Call) (gateway.Reply, error) {
			term := gateway.Terminal{Safety: true, Message: gateway.HelpMessage}
			if e := stop(ctx, c.Scope, term); e != nil {
				return gateway.Reply{}, e
			}
			return gateway.Reply{Terminal: &term}, errors.New("audit unavailable")
		}), nil
	}}
	v, e := s.generate(context.Background(), accounts.Principal{User: uuid.New()}, app.CreateReplyInput{RequestId: uuid.New(), ChatText: "synthetic"}, uuid.New(), uuid.New(), consentBinding{chat: uuid.New()}, func(context.Context, membership.Outcome) error {
		settled++
		return nil
	})
	if e != nil || v.Status != 200 || settled != 1 {
		t.Fatalf("settled safety was hidden by audit error: status=%d err=%v settled=%d", v.Status, e, settled)
	}
}

func TestTerminalModerationRetriesFailedSettlement(t *testing.T) {
	settlements := 0
	s := &Service{newRunner: func(stop gateway.Stop) (Runner, error) {
		return runnerFunc(func(ctx context.Context, c gateway.Call) (gateway.Reply, error) {
			term := gateway.Terminal{Code: "moderation_unavailable", Message: gateway.UnavailableMessage, Retryable: true}
			e := stop(ctx, c.Scope, term)
			return gateway.Reply{Terminal: &term}, e
		}), nil
	}}
	v, e := s.generate(context.Background(), accounts.Principal{User: uuid.New()}, app.CreateReplyInput{RequestId: uuid.New(), ChatText: "synthetic"}, uuid.New(), uuid.New(), consentBinding{chat: uuid.New()}, func(context.Context, membership.Outcome) error {
		settlements++
		if settlements == 1 {
			return errors.New("temporary settlement failure")
		}
		return nil
	})
	if !errors.Is(e, ErrModeration) || v.Status != 0 || settlements != 2 {
		t.Fatalf("moderation terminal was not durably settled: status=%d err=%v settlements=%d", v.Status, e, settlements)
	}
}
