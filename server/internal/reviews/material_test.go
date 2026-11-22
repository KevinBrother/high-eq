package reviews

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/scoring"
	"strings"
	"testing"
)

type runFunc func(context.Context, gateway.Call) (gateway.Reply, error)

func (f runFunc) Run(c context.Context, v gateway.Call) (gateway.Reply, error) { return f(c, v) }

func TestOnlyReportedActionIsScored(t *testing.T) {
	in := app.ReviewInput{RequestId: uuid.New(), Happened: "background", TheirPossibleFeeling: "guess", NextAction: "future", MyAction: "action", MyFeeling: "feeling"}
	var tasks []gateway.Task
	_, _, _, term, e := analyze(t.Context(), runFunc(func(_ context.Context, c gateway.Call) (gateway.Reply, error) {
		tasks = append(tasks, c.Task)
		if strings.Contains(c.Messages[0].Content, in.RequestId.String()) {
			t.Fatal("leaked request key")
		}
		if c.Task == gateway.ReviewAnalysis {
			return gateway.Reply{Result: gateway.Result{Object: []byte(`{"repair_phrase":"我刚才打断了你，你愿意继续说吗？"}`)}}, nil
		}
		var m struct{ Turns []scoring.Turn }
		if json.Unmarshal([]byte(c.Messages[0].Content), &m) != nil || len(m.Turns) != 1 || m.Turns[0] != (scoring.Turn{Role: "user", Text: "action"}) {
			t.Fatal("incorrect scoring target")
		}
		return gateway.Reply{Terminal: &gateway.Terminal{Safety: true}}, nil
	}), gateway.Scope{}, in, "", "", func(string) error { return nil }, analyzeHooks{})
	if len(tasks) != 2 || tasks[1] != gateway.Scoring || term == nil || !term.Safety || e != nil {
		t.Fatal(tasks, term, e)
	}
}
func TestRejectInvalidRepair(t *testing.T) {
	for _, s := range []string{`{}`, `{"repair_phrase":"都是你的错"}`, `{"repair_phrase":"谢谢","score":99}`, `{"repair_phrase":"  "}`, `{"repair_phrase":"可以吗？必须。"}`, `{"repair_phrase":"我刚才打断你. 我想先听你说。"}`, `{"repair_phrase":"."}`, `{"repair_phrase":"..."}`, `{"repair_phrase":"！"}`, `{"repair_phrase":"．"}`} {
		if _, e := repair([]byte(s)); e == nil {
			t.Fatalf("accepted %s", s)
		}
	}
	if got, e := repair([]byte(`{"repair_phrase":"我刚才打断你. 你愿意继续说吗？"}`)); e == nil {
		t.Fatalf("accepted two sentences: %q", got)
	}
	if got, e := repair([]byte(`{"repair_phrase":"我刚才打断你."}`)); e != nil || got != "我刚才打断你." {
		t.Fatalf("rejected one ASCII-terminated sentence: %q %v", got, e)
	}
	if got, e := repair([]byte(`{"repair_phrase":"我只等了3.5分钟，你愿意现在说吗？"}`)); e != nil || got != "我只等了3.5分钟，你愿意现在说吗？" {
		t.Fatalf("rejected decimal number: %q %v", got, e)
	}
}

func TestAnalyzeRechecksAccessBeforeScoring(t *testing.T) {
	in := app.ReviewInput{RequestId: uuid.New(), Happened: "background", TheirPossibleFeeling: "guess", NextAction: "future", MyAction: "action", MyFeeling: "feeling"}
	calls := 0
	_, _, _, term, e := analyze(t.Context(), runFunc(func(_ context.Context, c gateway.Call) (gateway.Reply, error) {
		calls++
		if c.Task != gateway.ReviewAnalysis {
			t.Fatalf("scored after access was revoked: %s", c.Task)
		}
		return gateway.Reply{Result: gateway.Result{Object: []byte(`{"repair_phrase":"我刚才打断了你，你愿意继续说吗？"}`)}}, nil
	}), gateway.Scope{}, in, "", "", func(string) error { return nil }, analyzeHooks{BeforeScore: func() error { return ErrConsent }})
	if !errors.Is(e, ErrConsent) || term != nil || calls != 1 {
		t.Fatalf("access recheck: calls=%d term=%v err=%v", calls, term, e)
	}
}
