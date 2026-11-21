package gateway

import (
	"context"

	"github.com/google/uuid"
	"high-eq/server/internal/prompts"
)

type promptResolver func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error)

func databasePrompts(db prompts.Reader) promptResolver {
	return func(ctx context.Context, task string, model, user uuid.UUID, vars map[string]string) (uuid.UUID, string, error) {
		return prompts.Resolve(ctx, db, task, model, user, vars)
	}
}

// Construct a fresh attempt rather than mutating the conversation: no primary template
// can carry over into a fallback, and neither telemetry nor Stop needs variable values.
func (r *Router) prepare(ctx context.Context, c Call, model endpoint) (Call, error) {
	if r.resolvePrompt == nil {
		return Call{}, ErrConfig
	}
	id, text, err := r.resolvePrompt(ctx, string(c.Task), model.id, c.User, c.Variables)
	if err != nil {
		return Call{}, err
	}
	if id == uuid.Nil || text == "" {
		return Call{}, ErrConfig
	}
	c.PromptVersion = id
	c.Variables = nil
	c.Messages = append([]Message{{Role: "system", Content: text}}, c.Messages...)
	return c, nil
}
