package gateway

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestStickyCohorts(t *testing.T) {
	for _, percent := range []int{0, 1, 17, 50, 99, 100} {
		n := 0
		for i := 0; i < 100000; i++ {
			var id uuid.UUID
			binary.BigEndian.PutUint64(id[8:], uint64(i))
			in := inCanary(id, percent)
			if in != inCanary(id, percent) {
				t.Fatal("unstable")
			}
			if in {
				n++
			}
		}
		t.Logf("target=%d%%: %d/100000", percent, n)
		if n < percent*1000-1000 || n > percent*1000+1000 || percent == 0 && n != 0 || percent == 100 && n != 100000 {
			t.Fatalf("%d%%: %d", percent, n)
		}
	}
}

// Every upstream is synthetic. The balance starts charged to exercise a refund,
// not merely the absence of a new debit.
func TestModeratedAttempts(t *testing.T) {
	for _, tc := range []struct {
		name     string
		mode     Mode
		fault    string
		want     []string
		tries    int
		terminal string
	}{
		{"pre-fragment provider failure", Stream, "pre", []string{"fragment:甲乙。", "fragment:丙"}, 2, ""},
		{"first token timeout", Stream, "first", []string{"fragment:甲乙。", "fragment:丙"}, 2, ""},
		{"total deadline", Stream, "total", nil, 1, ""},
		{"no splice", Stream, "post", []string{"fragment:甲乙。"}, 1, ""},
		{"input crisis", Stream, "input", []string{"safety:" + HelpMessage}, 0, "safety"},
		{"first sentence crisis", Stream, "crisis", []string{"safety:" + HelpMessage}, 1, "safety"},
		{"review timeout before output", Stream, "timeout", []string{"moderation_unavailable:" + UnavailableMessage}, 1, "moderation_unavailable"},
		{"review down after output", Stream, "down", []string{"fragment:甲乙。", "moderation_unavailable:" + UnavailableMessage}, 1, "moderation_unavailable"},
		{"whole reply crisis after fragments", Stream, "full", []string{"fragment:甲乙。", "fragment:丙", "safety:" + HelpMessage}, 1, "safety"},
		{"inconclusive", Text, "unknown", nil, 1, "moderation_unavailable"},
		{"nonstream crisis", JSONObject, "flag", nil, 1, "safety"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx := context.Background()
			p, b, m := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
			var got []string
			tries, refunds := 0, 0
			// Simulate both an uncharged operation and an already charged session.
			balances := [2]int{0, 1}
			scope := Scope{User: uuid.New(), Operation: uuid.New(), Activity: uuid.New()}
			var stats []attemptStat
			r := Router{first: time.Second, total: 2 * time.Second, review: time.Second, load: func(context.Context, Call) (plan, error) { return plan{primary: p, backup: b, moderator: m}, nil }, record: func(_ context.Context, _ Call, s attemptStat) error { stats = append(stats, s); return nil }, stop: func(_ context.Context, got Scope, _ Terminal) error {
				if got != scope {
					t.Fatal("wrong settlement key")
				}
				for i, n := range balances {
					if n == 1 {
						balances[i]--
						refunds++
					}
				}
				return nil
			}}
			if tc.fault == "first" {
				r.first = 10 * time.Millisecond
			}
			if tc.fault == "total" {
				r.total = 15 * time.Millisecond
			}
			if tc.fault == "timeout" {
				r.review = 10 * time.Millisecond
			}
			r.dispatch = func(ctx context.Context, _ uuid.UUID, e endpoint, k Kind, req Request) (Result, error) {
				if k == Moderation {
					payload := req.Messages[len(req.Messages)-1].Content
					switch {
					case tc.fault == "full" && payload == "甲乙。丙" || tc.fault == "input" || tc.fault == "crisis" && payload == "甲乙。":
						return Result{Object: []byte(`{"verdict":"crisis"}`)}, nil
					case tc.fault == "timeout" && payload == "甲乙。":
						<-ctx.Done()
						return Result{}, ctx.Err()
					case tc.fault == "down" && payload == "丙":
						return Result{}, ErrProvider
					case tc.fault == "unknown" && tries > 0:
						return Result{Object: []byte(`{}`)}, nil
					}
					return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
				}
				tries++
				if e.id == p.id {
					switch tc.fault {
					case "first", "total":
						<-ctx.Done()
						return Result{}, ctx.Err()
					case "pre":
						_ = req.OnDelta("丢弃")
						return Result{}, ErrProvider
					}
				}
				chunks := []string{"甲", "乙。", "丙"}
				if tc.fault == "flag" {
					chunks = []string{`{"safety_flag":true}`}
				}
				for i, v := range chunks {
					if err := req.OnDelta(v); err != nil {
						return Result{}, err
					}
					if tc.fault == "post" && i == 1 {
						return Result{}, ErrProvider
					}
				}
				return Result{InputTokens: 4, OutputTokens: 2, UsageKnown: true}, nil
			}
			c := Call{Task: Scoring, Scope: scope, Mode: tc.mode, Messages: []Message{{"user", "合成输入"}}}
			if c.Mode == Stream {
				c.Emit = func(_ context.Context, e Event) error { got = append(got, e.Name+":"+e.Text); return nil }
			}
			out, err := r.Run(ctx, c)
			if tc.fault == "post" || tc.fault == "total" {
				if err == nil {
					t.Fatal("incomplete accepted")
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if tries != tc.tries || !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("tries=%d events=%v", tries, got)
			}
			if tc.terminal != "" {
				if out.Terminal == nil || out.Terminal.Name() != tc.terminal || balances != [2]int{} || refunds != 1 || out.CallID != uuid.Nil || out.Result.Text != "" || len(out.Result.Object) != 0 {
					t.Fatal("unsafe terminal result")
				}
			}
			var outcomes []string
			for _, s := range stats {
				if s.model.id != m.id {
					outcomes = append(outcomes, s.outcome)
				}
			}
			if len(outcomes) != tries {
				t.Fatal("missing attempt")
			}
			if tc.fault == "first" && outcomes[0] != "timeout" {
				t.Fatal(outcomes)
			}
		})
	}
}

func TestDispatchTerms(t *testing.T) {
	a := approved{endpoint: endpoint{id: uuid.New()}, purpose: "合成用途", deletion: "合同删除", fields: []string{"a", "b"}, retention: 2}
	candidate := a
	candidate.id = uuid.New()
	candidate.fields = []string{"b"}
	candidate.retention = 0
	if !a.covers(candidate) {
		t.Fatal("stricter backup refused")
	}
	for _, change := range []func(*approved){func(b *approved) { b.id = uuid.Nil }, func(b *approved) { b.purpose = "other" }, func(b *approved) { b.deletion = "unknown" }, func(b *approved) { b.retention = 3 }, func(b *approved) { b.fields = []string{"extra"} }} {
		b := candidate
		change(&b)
		if a.covers(b) {
			t.Fatal("weaker backup eligible")
		}
	}
}

func TestTerminalContracts(t *testing.T) {
	for _, tc := range []struct {
		t    Terminal
		want string
	}{{crisis, `{"safety":true,"message":"听起来你现在可能正经历很难受的事。这里不适合继续练习，建议你马上联系专业的人：全国心理援助热线 12356；如果有人身危险，请立即拨打 110 或 120。"}`}, {unavailable, `{"code":"moderation_unavailable","message":"服务暂不可用，可重试","retryable":true}`}} {
		got, _ := json.Marshal(tc.t)
		if string(got) != tc.want {
			t.Fatal("terminal contract mismatch")
		}
	}
}
