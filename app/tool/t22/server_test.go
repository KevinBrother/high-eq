//go:build t22live

// Mounted into the T21 service test package only in an isolated Compose job.
package service

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"testing"

	"github.com/google/uuid"
	"high-eq/server/internal/events"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/replies"
)

type t22Upstream struct{ stop gateway.Stop }

func (u t22Upstream) Run(ctx context.Context, c gateway.Call) (gateway.Reply, error) {
	var in struct {
		Chat string `json:"chat_text"`
	}
	if c.Task != gateway.ReplySuggestion || c.Mode != gateway.JSONObject || len(c.Messages) != 1 || json.Unmarshal([]byte(c.Messages[0].Content), &in) != nil {
		return gateway.Reply{}, errors.New("unexpected test request")
	}
	switch in.Chat {
	case "T22-SYNTHETIC-NORMAL":
		return gateway.Reply{CallID: uuid.New(), Result: gateway.Result{Object: []byte(`{"possible_feeling":"可能有些着急","possible_need":"想确认时间","suggestions":[{"style":"直接","text":"我周三交初稿。","reason":"明确时间。"},{"style":"先确认","text":"你想先看提纲吗？","reason":"留出选择。"}]}`)}}, nil
	case "T22-SYNTHETIC-CRISIS", "T22-SYNTHETIC-OUTAGE":
		terminal := gateway.Terminal{Safety: in.Chat == "T22-SYNTHETIC-CRISIS"}
		return gateway.Reply{Terminal: &terminal}, u.stop(ctx, c.Scope, terminal)
	default:
		return gateway.Reply{}, errors.New("only fixed synthetic cases are allowed")
	}
}
func TestT22LiveServer(t *testing.T) {
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s, err := Start(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	s.Replies = replies.New(s.Accounts, s.Membership, s.Data, s.Fields, s.db, events.New(s.Data, nil), cfg.authMaster, func(stop gateway.Stop) (replies.Runner, error) { return t22Upstream{stop}, nil })
	// The harness only publishes this container port on 127.0.0.1.
	t.Fatal(http.ListenAndServe(":8080", s.Router()))
}
