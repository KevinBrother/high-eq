// Package gateway is the private, task-facing boundary for provider calls.
package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/google/uuid"
)

var (
	ErrRequest      = errors.New("invalid chat request")
	ErrProvider     = errors.New("provider response unavailable or incomplete")
	ErrConfig       = errors.New("configuration not admitted or unavailable")
	ErrNotification = errors.New("configuration committed; notification failed")
)

type Mode string

const (
	Text       Mode = "text"
	Stream     Mode = "stream"
	JSONObject Mode = "json_object"
)

type Kind string

const (
	Model      Kind = "model"
	Moderation Kind = "moderation"
)

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}
type Request struct {
	Messages []Message
	Mode     Mode
	OnDelta  func(string) error
}
type Result struct {
	Text                      string
	Object                    json.RawMessage
	InputTokens, OutputTokens int
}

// Resolve is supplied by the routing layer. Business callers never pass a model ID.
type Resolve func(context.Context, string) (uuid.UUID, error)
type Chat struct {
	catalog *Catalog
	kind    Kind
	resolve Resolve
}

func (c *Catalog) ForTasks(kind Kind, resolve Resolve) *Chat { return &Chat{c, kind, resolve} }
func (c *Chat) Chat(ctx context.Context, task string, r Request) (Result, error) {
	if strings.TrimSpace(task) == "" || c.resolve == nil || !r.valid() {
		return Result{}, ErrRequest
	}
	id, err := c.resolve(ctx, task)
	if err != nil {
		return Result{}, err
	}
	a, t, err := c.catalog.lookup(ctx, id, c.kind)
	if err != nil {
		return Result{}, err
	}
	return a.chat(ctx, t, r)
}
func (r Request) valid() bool {
	if len(r.Messages) == 0 || (r.Mode != Text && r.Mode != Stream && r.Mode != JSONObject) || (r.OnDelta != nil) != (r.Mode == Stream) {
		return false
	}
	for _, m := range r.Messages {
		if (m.Role != "user" && m.Role != "system" && m.Role != "assistant") || m.Content == "" {
			return false
		}
	}
	return true
}

type target struct{ endpoint, model, key string }
type adapter interface {
	chat(context.Context, target, Request) (Result, error)
}
