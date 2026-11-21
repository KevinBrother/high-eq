package gateway

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
)

// An approved but malformed scoring object is eligible for schema repair, NOT
// fallback. A missing moderation verdict for that same output must win first.
func TestScoringFormatAfterReview(t *testing.T) {
	for _, verdict := range []string{"allow", "unknown", "crisis"} {
		t.Run(verdict, func(t *testing.T) {
			models, reviews, stops := 0, 0, 0
			p := plan{primary: endpoint{id: uuid.New()}, backup: endpoint{id: uuid.New()}, moderator: endpoint{id: uuid.New()}}
			r := Router{first: time.Second, total: time.Second, review: time.Second, load: func(context.Context, Call) (plan, error) { return p, nil }, resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
				return uuid.New(), "合成规则", nil
			}, stop: func(context.Context, Scope, Terminal) error { stops++; return nil }, record: func(_ context.Context, c Call, s attemptStat) error {
				if c.Messages != nil || c.Variables != nil || s.usage.Text != "" || s.usage.Object != nil {
					t.Fatal("telemetry retained content")
				}
				return nil
			}, dispatch: func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, r Request) (Result, error) {
				if k == Moderation {
					reviews++
					v := "allow"
					if reviews == 2 {
						v = verdict
					}
					return Result{Object: []byte(`{"verdict":"` + v + `"}`)}, nil
				}
				models++
				return Result{}, r.OnDelta(`[1]`)
			}}
			reply, err := r.Run(t.Context(), Call{Scope: Scope{User: uuid.New(), Operation: uuid.New()}, Task: Scoring, Mode: JSONObject})
			if models != 1 || reviews != 2 || reply.CallID != uuid.Nil || reply.Result.Object != nil {
				t.Fatal("invalid output leaked or triggered fallback")
			}
			if verdict == "allow" {
				if !errors.Is(err, ErrObjectFormat) || stops != 0 || reply.Terminal != nil {
					t.Fatal("lost schema error")
				}
			} else if err != nil || stops != 1 || reply.Terminal == nil || reply.Terminal.Safety != (verdict == "crisis") {
				t.Fatal("moderation did not win")
			}
		})
	}
}
