package gateway

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"high-eq/server/internal/prompts"
)

func TestPromptErrorBeforeAnyProvider(t *testing.T) {
	model := uuid.New()
	c := Call{Scope: Scope{User: uuid.New(), Operation: uuid.New()}, Task: Scoring, Mode: Text}
	loaded := false
	r := Router{total: time.Second, load: func(context.Context, Call) (plan, error) {
		loaded = true
		return plan{primary: endpoint{id: model}}, nil
	}, resolvePrompt: func(_ context.Context, _ string, m, u uuid.UUID, vars map[string]string) (uuid.UUID, string, error) {
		if !loaded || m != model || u != c.User {
			t.Fatal("resolved before routing")
		}
		s, e := prompts.Render("{{required}}", vars)
		return uuid.New(), s, e
	}, dispatch: func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error) {
		t.Fatal("called provider")
		return Result{}, nil
	}}
	if _, e := r.Run(context.Background(), c); !errors.Is(e, prompts.ErrVariable) {
		t.Fatal(e)
	}
	c.PromptVersion = uuid.New()
	if _, e := r.Run(context.Background(), c); !errors.Is(e, ErrRequest) {
		t.Fatal("accepted caller version")
	}
}

func TestInvalidPromptCallDoesNotSelectRoute(t *testing.T) {
	r := Router{total: time.Second, load: func(context.Context, Call) (plan, error) { t.Fatal("routed invalid call"); return plan{}, nil }}
	for _, mode := range []Mode{"", Stream} {
		c := Call{Scope: Scope{User: uuid.New(), Operation: uuid.New()}, Task: Scoring, Mode: mode}
		if _, e := r.Run(context.Background(), c); !errors.Is(e, ErrRequest) {
			t.Fatal(e)
		}
	}
}
