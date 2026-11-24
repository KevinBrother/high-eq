package scoring

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/prompts"
	"high-eq/server/internal/promptvars"
)

type step struct {
	raw  string
	term *gateway.Terminal
	err  error
}
type spy struct {
	steps []step
	calls []gateway.Call
}

func (s *spy) Run(_ context.Context, c gateway.Call) (gateway.Reply, error) {
	s.calls = append(s.calls, c)
	x := s.steps[len(s.calls)-1]
	return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(x.raw)}, Terminal: x.term, CallID: uuid.New()}, x.err
}

var turns = []Turn{{"assistant", "想谈什么？"}, {"user", "昨天两份报表都是我做的。"}, {"assistant", "哪里需要调整？"}, {"user", "你就是个废物！"}}
var scope = gateway.Scope{User: uuid.New(), Operation: uuid.New()}

func TestScoringPromptVariablesFitPublishedBounds(t *testing.T) {
	for _, assessment := range []string{"full_session", "single_skill", "full_review"} {
		if len(assessment) > promptvars.ScoringAssessmentMaxBytes {
			t.Fatalf("assessment %q exceeds prompt contract", assessment)
		}
	}
	for _, target := range []string{"observation", "feeling", "need", "request"} {
		if len(target) > promptvars.ScoringTargetItemMaxBytes {
			t.Fatalf("target %q exceeds prompt contract", target)
		}
	}
	if len(retryInstruction) != promptvars.ScoringRetryMaxBytes {
		t.Fatalf("retry=%d bytes, prompt contract=%d", len(retryInstruction), promptvars.ScoringRetryMaxBytes)
	}
}

const good = `{"safety_flag":false,"mode":"express","nvc":{"observation":{"score":15,"reason":"事实加一处评判"},"feeling":{"score":0,"reason":"无情绪"},"need":{"score":0,"reason":"指责"},"request":{"score":0,"reason":"无请求"},"total":99},"emotion":{"read_others":{"level":1,"reason":"未回应"},"self_management":{"level":1,"reason":"攻击"},"relationship":{"level":1,"reason":"辱骂"}},"target_turn":2,"better_version":"一起理一下分工好吗？","why_better":"具体请求"}`

func TestSessionRetry(t *testing.T) {
	f := &spy{steps: []step{{err: gateway.ErrObjectFormat}, {raw: good}}}
	r, err := New(f, scope).ScoreSession(t.Context(), "职场", turns, "")
	if err != nil || r.Status != Success || r.Value.NVC.Total != 15 || r.CallID == uuid.Nil || *r.Value.TargetTurn != 2 {
		t.Fatal("missing normalized score", err)
	}
	for _, c := range f.calls {
		if c.Task != gateway.Scoring || c.Mode != gateway.JSONObject || c.Scope != scope || len(c.Messages) != 1 || c.Messages[0].Role != "user" {
			t.Fatal("invalid routing")
		}
		var data struct {
			Turns []struct {
				Role, Text string
				N          int `json:"user_turn"`
			}
		}
		if json.Unmarshal([]byte(c.Messages[0].Content), &data) != nil || len(data.Turns) != 4 {
			t.Fatal("transcript")
		}
		for i, v := range data.Turns {
			if v.N != []int{0, 1, 0, 2}[i] || v.Text != turns[i].Text || v.Role != turns[i].Role {
				t.Fatal(i)
			}
		}
	}
	if f.calls[1].Variables["retry"] == f.calls[0].Variables["retry"] {
		t.Fatal("no repair instruction")
	}
}

func TestHooksReachGatewayCall(t *testing.T) {
	f := &spy{steps: []step{{raw: strings.Replace(good, `"target_turn":2`, `"target_turn":1`, 1)}}}
	before, generated := 0, 0
	hooks := Hooks{
		BeforeGenerate: func(context.Context) error { before++; return nil },
		OnGenerated:    func(context.Context, uuid.UUID, string) error { generated++; return nil },
	}
	r, err := New(f, scope, hooks).Score(t.Context(), "家庭", "情境", "我的做法", "")
	if err != nil || r.Status != Success || len(f.calls) != 1 {
		t.Fatal(err)
	}
	c := f.calls[0]
	if c.BeforeGenerate == nil || c.OnGenerated == nil || c.Generated != nil {
		t.Fatal("review hooks were not forwarded")
	}
	if err = c.BeforeGenerate(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err = c.OnGenerated(t.Context(), uuid.New(), good); err != nil {
		t.Fatal(err)
	}
	if before != 1 || generated != 1 {
		t.Fatalf("hooks before=%d generated=%d", before, generated)
	}
}
func TestSchemaBoundaries(t *testing.T) {
	for _, pair := range [][2]string{{`"total":99`, `"total":null`}, {`"total":99`, `"TOTAL":15`}, {`"score":15`, `"score":15,"score":15`}, {`"score":15`, `"score":20`}, {`"score":15,`, ``}, {`"level":1`, `"level":0`}, {`"level":1`, `"level":6`}, {`"level":1`, `"extra":0,"level":1`}, {`"target_turn":2`, `"target_turn":0`}, {`"target_turn":2`, `"target_turn":3`}, {`"target_turn":2`, `"target_turn":null`}, {`"express"`, `"other"`}, {`"具体请求"`, `" "`}, {`"一起理一下分工好吗？"`, `"` + strings.Repeat("界", 81) + `"`}, {`false`, `"false"`}} {
		if _, err := ParseFull([]byte(strings.Replace(good, pair[0], pair[1], 1)), 2); err == nil {
			t.Errorf("accepted %s", pair[1])
		}
	}
	for _, v := range []string{good + `{}`, `[]`, `null`, `{`} {
		if _, err := ParseFull([]byte(v), 2); err == nil {
			t.Error("accepted malformed object")
		}
	}
	if _, err := ParseFull([]byte(strings.Replace(good, "一起理一下分工好吗？", strings.Repeat("界", 80), 1)), 2); err != nil {
		t.Error("80 characters rejected")
	}
}
func TestStopPrecedence(t *testing.T) {
	for _, x := range []struct {
		steps   []step
		status  Status
		wantErr bool
	}{{[]step{{raw: good, term: &gateway.Terminal{Safety: true}, err: errors.New("settlement")}}, Safety, true}, {[]step{{term: &gateway.Terminal{Code: "moderation_unavailable"}}}, ModerationUnavailable, false}, {[]step{{raw: `{"safety_flag":true}`}}, Safety, false}, {[]step{{err: gateway.ErrProvider}}, Failed, true}, {[]step{{raw: `{}`}, {raw: `{}`}}, Failed, true}} {
		f := &spy{steps: x.steps}
		r, e := New(f, scope).Score(t.Context(), "家庭", "情境", "我的做法", "")
		if len(f.calls) != len(x.steps) || r.Status != x.status || r.Value != nil || r.CallID != uuid.Nil || (e != nil) != x.wantErr {
			t.Fatal(x.status, e)
		}
		if x.status == Safety && (r.Terminal == nil || r.Terminal.Message != gateway.HelpMessage) {
			t.Fatal("crisis message")
		}
		if x.status == ModerationUnavailable && (r.Terminal == nil || r.Terminal.Safety || !r.Terminal.Retryable || r.Terminal.Message != gateway.UnavailableMessage) {
			t.Fatal("moderation message")
		}
	}
}
func TestSingle(t *testing.T) {
	for _, x := range []struct{ score, action string }{{"25", "pass"}, {"15", "retry_in_three_days"}, {"5", "retry_now"}} {
		f := &spy{steps: []step{{raw: good}, {raw: `{"target_item":"observation","score":` + x.score + `,"reason":"具体反馈"}`}}}
		r, e := New(f, scope).ScoreSkill(t.Context(), "职场", turns, "", "observation")
		if e != nil || r.Value.NextAction != x.action || f.calls[0].Variables["target_item"] != "observation" {
			t.Fatal(x, e)
		}
	}
	for _, raw := range []string{`{"target_item":"request","score":25,"reason":"反馈"}`, `{"target_item":"need","score":25,"reason":"反馈","total":25}`, `{"target_item":"need","score":15,"reason":"反馈"}`} {
		f := &spy{steps: []step{{raw: raw}, {raw: raw}}}
		r, _ := New(f, scope).ScoreSkill(t.Context(), "职场", turns, "", "need")
		if r.Status != Failed || r.Value != nil {
			t.Fatal(raw)
		}
	}
	f := &spy{}
	s := New(f, scope)
	if _, e := s.ScoreSkill(t.Context(), "职场", turns, "", "total"); e == nil {
		t.Fatal("invalid target")
	}
	if _, e := s.ScoreSession(t.Context(), "职场", turns[:1], ""); e == nil {
		t.Fatal("no user turns")
	}
}
func TestSeed(t *testing.T) {
	src, err := os.ReadFile("seed.txt")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = prompts.Render(string(src), map[string]string{"assessment": "single_skill", "target_item": "request", "retry": ""}); err != nil {
		t.Fatal(err)
	}
}

func TestReviewBoundary(t *testing.T) {
	f := &spy{steps: []step{{raw: strings.Replace(good, `"target_turn":2`, `"target_turn":1`, 1)}}}
	r, e := New(f, scope).Score(t.Context(), "朋友", "对方的处境", "我当时怎么做", "虚构摘要")
	if e != nil || r.Status != Success {
		t.Fatal(e)
	}
	c := f.calls[0]
	var m material
	if json.Unmarshal([]byte(c.Messages[0].Content), &m) != nil || c.Variables["assessment"] != "full_review" || m.Context != "对方的处境" || m.Profile != "虚构摘要" || len(m.Turns) != 1 || m.Turns[0].UserTurn != 1 || m.Turns[0].Text != "我当时怎么做" {
		t.Fatal("review scored background as speech")
	}
}
func TestSkillSafetyAfterInvalid(t *testing.T) {
	for _, x := range []struct {
		term   *gateway.Terminal
		status Status
	}{{&gateway.Terminal{Safety: true}, Safety}, {&gateway.Terminal{Code: "moderation_unavailable"}, ModerationUnavailable}} {
		f := &spy{steps: []step{{raw: `null`}, {term: x.term}}}
		r, err := New(f, scope).ScoreSkill(t.Context(), "朋友", turns, "", "request")
		if err != nil || r.Status != x.status || r.Value != nil || r.CallID != uuid.Nil || len(f.calls) != 2 {
			t.Fatal("unsafe drill termination")
		}
	}
}

func TestNumericProjection(t *testing.T) {
	v, e := ParseFull([]byte(good), 2)
	if e != nil {
		t.Fatal(e)
	}
	raw, e := json.Marshal(v.Values())
	if e != nil || string(raw) != `{"nvc":{"observation":15,"feeling":0,"need":0,"request":0,"total":15},"emotion":{"read_others":1,"self_management":1,"relationship":1}}` {
		t.Fatal("projection must contain only canonical integers")
	}
}
