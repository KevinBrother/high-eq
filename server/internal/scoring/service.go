package scoring

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"high-eq/server/internal/gateway"
)

type Runner interface {
	Run(context.Context, gateway.Call) (gateway.Reply, error)
}

type Hooks struct {
	BeforeGenerate func(context.Context) error
	OnGenerated    func(context.Context, uuid.UUID, string) error
	Generated      *gateway.Generated
}

type Service struct {
	router Runner
	scope  gateway.Scope
	hooks  Hooks
}

const retryInstruction = "上一次输出格式无效。请按当前分支重新生成一个严格合规的 JSON 对象。"

// New binds the router to authenticated server state for ONE operation.
func New(r Runner, scope gateway.Scope, hooks ...Hooks) *Service {
	var h Hooks
	if len(hooks) != 0 {
		h = hooks[0]
	}
	return &Service{router: r, scope: scope, hooks: h}
}

type numbered struct {
	Turn
	UserTurn int `json:"user_turn,omitempty"`
}
type material struct {
	Scene   string     `json:"scene"`
	Context string     `json:"context,omitempty"`
	Profile string     `json:"profile,omitempty"`
	Turns   []numbered `json:"turns"`
}

func call(scene, background, profile, assessment, target string, turns []Turn) (gateway.Call, int, error) {
	m := material{Scene: scene, Context: background, Profile: profile}
	n := 0
	if strings.TrimSpace(scene) == "" || !utf8.ValidString(scene) || !utf8.ValidString(background) || !utf8.ValidString(profile) {
		return gateway.Call{}, 0, ErrInput
	}
	for _, t := range turns {
		if strings.TrimSpace(t.Text) == "" || !utf8.ValidString(t.Text) || (t.Role != "assistant" && t.Role != "user") {
			return gateway.Call{}, 0, ErrInput
		}
		v := numbered{Turn: t}
		if t.Role == "user" {
			n++
			v.UserTurn = n
		}
		m.Turns = append(m.Turns, v)
	}
	if n == 0 {
		return gateway.Call{}, 0, ErrInput
	}
	data, err := json.Marshal(m)
	if err != nil {
		return gateway.Call{}, 0, ErrInput
	}
	return gateway.Call{Task: gateway.Scoring, Mode: gateway.JSONObject, Variables: map[string]string{"assessment": assessment, "target_item": target, "retry": ""}, Messages: []gateway.Message{{Role: "user", Content: string(data)}}}, n, nil
}

// Score grades only the reviewer's own reported action. Background and profile
// are context, not additional utterances; a review has precisely one user turn.
func (s *Service) Score(ctx context.Context, scene, background, utterance, profile string) (Outcome[Full], error) {
	return s.full(ctx, scene, background, profile, "full_review", []Turn{{"user", utterance}})
}
func (s *Service) ScoreSession(ctx context.Context, scene string, turns []Turn, profile string) (Outcome[Full], error) {
	return s.full(ctx, scene, "", profile, "full_session", turns)
}
func (s *Service) full(ctx context.Context, scene, bg, profile, kind string, turns []Turn) (Outcome[Full], error) {
	c, n, err := call(scene, bg, profile, kind, "", turns)
	if err != nil {
		return Outcome[Full]{Status: Failed}, err
	}
	return run(ctx, s, c, func(raw []byte) (*Full, error) { return ParseFull(raw, n) })
}
func (s *Service) ScoreSkill(ctx context.Context, scene string, turns []Turn, profile, target string) (Outcome[Progress], error) {
	if !validTarget(target) {
		return Outcome[Progress]{Status: Failed}, ErrInput
	}
	c, _, err := call(scene, "", profile, "single_skill", target, turns)
	if err != nil {
		return Outcome[Progress]{Status: Failed}, err
	}
	return run(ctx, s, c, func(raw []byte) (*Progress, error) { return parseSkill(raw, target) })
}
func run[T any](parent context.Context, s *Service, c gateway.Call, parse func([]byte) (*T, error)) (Outcome[T], error) {
	ctx, cancel := context.WithTimeout(parent, 60*time.Second)
	defer cancel()
	c.Scope = s.scope
	c.BeforeGenerate = s.hooks.BeforeGenerate
	c.OnGenerated = s.hooks.OnGenerated
	c.Generated = s.hooks.Generated
	failed := Outcome[T]{Status: Failed}
	for attempt := 0; attempt < 2; attempt++ {
		if err := ctx.Err(); err != nil {
			return failed, err
		}
		reply, err := s.router.Run(ctx, c)
		if t := reply.Terminal; t != nil {
			switch {
			case t.Safety:
				return safety[T](), err
			case t.Code == "moderation_unavailable":
				return Outcome[T]{Status: ModerationUnavailable, Terminal: &gateway.Terminal{Code: t.Code, Message: gateway.UnavailableMessage, Retryable: true}}, err
			default:
				return failed, errors.Join(gateway.ErrProvider, err)
			}
		}
		if err != nil && !errors.Is(err, gateway.ErrObjectFormat) {
			return failed, err
		}
		if err == nil {
			if f, ok := object(reply.Result.Object, "safety_flag"); ok && string(f["safety_flag"]) == "true" {
				return safety[T](), nil
			}
			value, err := parse(reply.Result.Object)
			if err == nil {
				return Outcome[T]{Status: Success, Value: value, CallID: reply.CallID}, nil
			}
		}
		// Never echo rejected model text, or mutate the first attempt's variable map.
		c.Variables = map[string]string{"assessment": c.Variables["assessment"], "target_item": c.Variables["target_item"], "retry": retryInstruction}
	}
	return failed, ErrSchema
}
func safety[T any]() Outcome[T] {
	return Outcome[T]{Status: Safety, Terminal: &gateway.Terminal{Safety: true, Message: gateway.HelpMessage}}
}
