package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

func testAttemptRouter(dispatch func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error)) *Router {
	primary, backup, moderator := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	return &Router{
		resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "synthetic prompt", nil
		},
		load: func(context.Context, Call) (plan, error) {
			return plan{primary: primary, backup: backup, moderator: moderator}, nil
		},
		dispatch: dispatch,
		record:   func(context.Context, Call, attemptStat) error { return nil },
		stop:     func(context.Context, Scope, Terminal) error { return nil },
		first:    time.Second,
		total:    time.Second,
		review:   time.Second,
	}
}

func TestAttemptGuardRunsBeforeEveryDispatch(t *testing.T) {
	ctx := context.Background()
	var guards, dispatches int
	r := testAttemptRouter(func(_ context.Context, _ uuid.UUID, _ endpoint, kind Kind, req Request) (Result, error) {
		dispatches++
		if kind == Moderation {
			return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
		}
		if err := req.OnDelta(`{"ok":true}`); err != nil {
			return Result{}, err
		}
		return Result{Object: json.RawMessage(`{"ok":true}`)}, nil
	})
	call := Call{
		Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
		Task:     Classification,
		Mode:     JSONObject,
		Messages: []Message{{Role: "user", Content: "synthetic material"}},
		BeforeAttempt: func(context.Context) error {
			guards++
			return nil
		},
	}
	if _, err := r.Run(ctx, call); err != nil {
		t.Fatal(err)
	}
	if guards != 3 || dispatches != 3 {
		t.Fatalf("guard/dispatch count: guards=%d dispatches=%d", guards, dispatches)
	}
}

func TestAttemptGuardStopsBeforeFallbackDispatch(t *testing.T) {
	ctx := context.Background()
	rejected := errors.New("synthetic authorization rejected")
	var guards, dispatches int
	r := testAttemptRouter(func(_ context.Context, _ uuid.UUID, _ endpoint, kind Kind, req Request) (Result, error) {
		dispatches++
		if kind == Moderation {
			return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
		}
		// The primary model attempt fails before emitting content, which makes
		// the router eligible to try the backup. The guard must run again before
		// that backup model is dispatched.
		if dispatches == 2 {
			return Result{}, ErrProvider
		}
		if err := req.OnDelta(`{"ok":true}`); err != nil {
			return Result{}, err
		}
		return Result{Object: json.RawMessage(`{"ok":true}`)}, nil
	})
	call := Call{
		Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
		Task:     Classification,
		Mode:     JSONObject,
		Messages: []Message{{Role: "user", Content: "synthetic material"}},
		BeforeAttempt: func(context.Context) error {
			guards++
			if guards == 4 {
				return rejected
			}
			return nil
		},
	}
	if _, err := r.Run(ctx, call); !errors.Is(err, rejected) {
		t.Fatalf("got %v, want authorization rejection", err)
	}
	if guards != 4 || dispatches != 3 {
		t.Fatalf("fallback dispatched without guard: guards=%d dispatches=%d", guards, dispatches)
	}
}

func TestAttemptGuardRejectsBeforeInputModerationDispatch(t *testing.T) {
	ctx := context.Background()
	rejected := errors.New("synthetic authorization rejected")
	var dispatches int
	r := testAttemptRouter(func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error) {
		dispatches++
		return Result{}, nil
	})
	call := Call{
		Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
		Task:     Classification,
		Mode:     JSONObject,
		Messages: []Message{{Role: "user", Content: "synthetic material"}},
		BeforeAttempt: func(context.Context) error {
			return rejected
		},
	}
	if _, err := r.Run(ctx, call); !errors.Is(err, rejected) {
		t.Fatalf("got %v, want authorization rejection", err)
	}
	if dispatches != 0 {
		t.Fatalf("dispatches=%d, want zero", dispatches)
	}
}

func TestAttemptGuardRejectsBeforeOutputModerationDispatch(t *testing.T) {
	ctx := context.Background()
	rejected := errors.New("synthetic authorization rejected")
	var guards, dispatches int
	r := testAttemptRouter(func(_ context.Context, _ uuid.UUID, _ endpoint, kind Kind, req Request) (Result, error) {
		dispatches++
		if kind == Moderation {
			return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
		}
		if err := req.OnDelta(`{"ok":true}`); err != nil {
			return Result{}, err
		}
		return Result{Object: json.RawMessage(`{"ok":true}`)}, nil
	})
	call := Call{
		Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
		Task:     Classification,
		Mode:     JSONObject,
		Messages: []Message{{Role: "user", Content: "synthetic material"}},
		BeforeAttempt: func(context.Context) error {
			guards++
			if guards == 3 {
				return rejected
			}
			return nil
		},
	}
	if _, err := r.Run(ctx, call); !errors.Is(err, rejected) {
		t.Fatalf("got %v, want authorization rejection", err)
	}
	if guards != 3 || dispatches != 2 {
		t.Fatalf("output review dispatched without guard: guards=%d dispatches=%d", guards, dispatches)
	}
}
