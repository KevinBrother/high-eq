package training

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

func runnerError(e error) error {
	switch {
	case errors.Is(e, accounts.ErrAuth),
		errors.Is(e, accounts.ErrInvalid),
		errors.Is(e, privacy.ErrHidden),
		errors.Is(e, ErrConsent),
		errors.Is(e, membership.ErrForbidden),
		errors.Is(e, membership.ErrConflict):
		return e
	default:
		return ErrGeneration
	}
}

func rolePlayCall(j job, msgs []gateway.Message, emit func(context.Context, gateway.Event) error) gateway.Call {
	return gateway.Call{
		Scope: j.scope(), Task: gateway.RolePlay, Mode: gateway.Stream,
		Variables: map[string]string{"scene": rolePlayScene(j)}, Messages: msgs, Emit: emit,
	}
}

// A catalog level has a server-owned, frozen scene. A custom setup keeps its
// complete text in the first user JSON message; only the validated category may
// influence the system prompt.
func rolePlayScene(j job) string {
	if j.input.Level == nil && j.input.Scene != nil {
		return *j.input.Scene
	}
	return j.scene
}

func (s *Service) Send(parent context.Context, p accounts.Principal, id uuid.UUID, in app.SendMessageInput, emit Emit) error {
	j, replay, e := s.claim(parent, p, id, in.ClientMessageId, "message", in.Text)
	if e != nil {
		return e
	}
	if replay != nil {
		return emit(*replay)
	}
	// A broken mobile socket is not an exit. Keep the original bounded worker;
	// it can commit a retrievable result even when no one receives the receipt.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(parent), 80*time.Second)
	defer cancel()
	runner, e := s.runner(p, &j)
	if e != nil {
		return s.failed(ctx, j, ErrGeneration)
	}
	setting, _ := json.Marshal(map[string]string{"scenario": j.scene, "profile_summary": j.profile})
	msgs := []gateway.Message{{Role: "user", Content: string(setting)}}
	for _, m := range j.Messages {
		msgs = append(msgs, gateway.Message{Role: string(m.Role), Content: m.Text})
	}
	var text strings.Builder
	disconnected := false
	send := func(f Frame) {
		if !disconnected {
			disconnected = emit(f) != nil
		}
	}
	reply, e := runner.Run(ctx, rolePlayCall(j, msgs, func(c context.Context, v gateway.Event) error {
		if v.Name != "fragment" {
			return nil
		}
		if j.tokens+len(in.Text)+text.Len()+len(v.Text) > 30000 {
			return ErrCap
		}
		if e := s.Data.Access(c, j.user, func(tx pgx.Tx) error {
			if e := s.check(c, tx, j); e != nil {
				return e
			}
			return s.allowed(c, tx, j.user, j.input)
		}); e != nil {
			return e
		}
		text.WriteString(v.Text)
		send(Frame{"fragment", map[string]any{"client_message_id": j.key, "text": v.Text}})
		return nil
	}))
	if t := reply.Terminal; t != nil {
		settlementErr := s.settleTerminal(ctx, &j, *t)
		send(Frame{t.Name(), t})
		return settlementErr
	}
	if errors.Is(e, ErrCap) {
		return s.capped(ctx, &j)
	}
	if e != nil || reply.CallID == uuid.Nil || text.Len() == 0 {
		return s.failed(ctx, j, runnerError(e))
	}
	delta := len(in.Text) + text.Len()
	if reply.Result.UsageKnown {
		delta = max(delta, reply.Result.InputTokens+reply.Result.OutputTokens)
	}
	if delta > 30000-j.tokens {
		return s.capped(ctx, &j)
	}
	m := app.Message{Id: uuid.New(), ClientMessageId: j.key, Role: "assistant", Seq: len(j.Messages) + 1, Text: text.String()}
	var ledger Settlement
	e = s.Accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if e := s.check(ctx, tx, j); e != nil {
			return e
		}
		if e := s.allowed(ctx, tx, j.user, j.input); e != nil {
			return e
		}
		persist := func(t pgx.Tx) error { return s.add(ctx, t, j, m) }
		var e error
		if j.held {
			e = s.Rights.SaveApproved(ctx, tx, j.user, j.ID, j.token, persist)
		} else {
			e = persist(tx)
		}
		if e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, `update activities set state='active' where id=$1`, id); e != nil {
			return e
		}
		if _, e = tx.Exec(ctx, `update practice_work set worker=null,valid_until=null,used_tokens=used_tokens+$2 where activity_id=$1`, id, delta); e != nil {
			return e
		}
		r, e := s.load(ctx, tx, j.user, id)
		ledger = r.Settlement
		return e
	})
	if e != nil {
		return s.failed(ctx, j, e)
	}
	send(Frame{"reply_saved", saved{j.key, m.Id, ledger}})
	return nil
}
