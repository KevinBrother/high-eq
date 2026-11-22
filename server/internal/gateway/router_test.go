package gateway

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestCallGuardFencesDispatchAndFragments(t *testing.T) {
	p, m := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	scope := Scope{User: uuid.New(), Operation: uuid.New(), Activity: uuid.New()}
	newRouter := func() *Router {
		r := &Router{resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "fixture", nil
		}, first: time.Second, total: 2 * time.Second, review: time.Second, load: func(context.Context, Call) (plan, error) {
			return plan{primary: p, moderator: m}, nil
		}, record: func(context.Context, Call, attemptStat) error { return nil }, stop: func(context.Context, Scope, Terminal) error { return nil }}
		return r
	}

	t.Run("after input review", func(t *testing.T) {
		r := newRouter()
		guardCalls, modelCalls, reviewCalls := 0, 0, 0
		r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, _ Request) (Result, error) {
			if k == Moderation {
				reviewCalls++
				return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
			}
			modelCalls++
			return Result{}, errors.New("model must not run")
		}
		revoked := errors.New("authorization revoked")
		c := Call{Task: RolePlay, Scope: scope, Mode: Text, Messages: []Message{{"user", "合成输入"}}, Guard: func(context.Context) error {
			guardCalls++
			if guardCalls > 1 {
				return revoked
			}
			return nil
		}}
		if _, err := r.Run(context.Background(), c); !errors.Is(err, revoked) {
			t.Fatalf("got %v want guard error", err)
		}
		if guardCalls != 2 || reviewCalls != 1 || modelCalls != 0 {
			t.Fatalf("guard=%d reviews=%d model=%d", guardCalls, reviewCalls, modelCalls)
		}
	})

	t.Run("before every fragment", func(t *testing.T) {
		r := newRouter()
		var events []string
		guardCalls := 0
		var denied bool
		revoked := errors.New("session ended")
		r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, req Request) (Result, error) {
			if k == Moderation {
				return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
			}
			if err := req.OnDelta("甲。"); err != nil {
				return Result{}, err
			}
			denied = true
			return Result{}, req.OnDelta("乙。")
		}
		c := Call{Task: RolePlay, Scope: scope, Mode: Stream, Messages: []Message{{"user", "合成输入"}}, Emit: func(_ context.Context, e Event) error {
			events = append(events, e.Name+":"+e.Text)
			return nil
		}, Guard: func(context.Context) error {
			guardCalls++
			if denied {
				return revoked
			}
			return nil
		}}
		if _, err := r.Run(context.Background(), c); !errors.Is(err, revoked) {
			t.Fatalf("got %v want guard error", err)
		}
		if guardCalls < 4 || !reflect.DeepEqual(events, []string{"fragment:甲。"}) {
			t.Fatalf("guard=%d events=%v", guardCalls, events)
		}
	})

	t.Run("before output review after revocation", func(t *testing.T) {
		r := newRouter()
		revoked := errors.New("authorization revoked")
		var denied bool
		var events []string
		reviewCalls := 0
		r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, req Request) (Result, error) {
			if k == Moderation {
				reviewCalls++
				return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
			}
			if err := req.OnDelta("甲。"); err != nil {
				return Result{}, err
			}
			denied = true
			return Result{}, req.OnDelta("乙。")
		}
		c := Call{Task: RolePlay, Scope: scope, Mode: Stream, Messages: []Message{{"user", "合成输入"}}, Emit: func(_ context.Context, e Event) error {
			events = append(events, e.Name+":"+e.Text)
			return nil
		}, Guard: func(context.Context) error {
			if denied {
				return revoked
			}
			return nil
		}}
		if _, err := r.Run(context.Background(), c); !errors.Is(err, revoked) {
			t.Fatalf("got %v want guard error", err)
		}
		if reviewCalls != 2 || !reflect.DeepEqual(events, []string{"fragment:甲。"}) {
			t.Fatalf("reviews=%d events=%v", reviewCalls, events)
		}
	})

	t.Run("before full output review after revocation", func(t *testing.T) {
		r := newRouter()
		revoked := errors.New("authorization revoked")
		var denied bool
		reviewCalls := 0
		r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, req Request) (Result, error) {
			if k == Moderation {
				reviewCalls++
				return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
			}
			if err := req.OnDelta("完整回复"); err != nil {
				return Result{}, err
			}
			denied = true
			return Result{}, nil
		}
		c := Call{Task: RolePlay, Scope: scope, Mode: Text, Messages: []Message{{"user", "合成输入"}}, Guard: func(context.Context) error {
			if denied {
				return revoked
			}
			return nil
		}}
		if _, err := r.Run(context.Background(), c); !errors.Is(err, revoked) {
			t.Fatalf("got %v want guard error", err)
		}
		if reviewCalls != 1 {
			t.Fatalf("reviews=%d", reviewCalls)
		}
	})

	t.Run("before backup review after revocation", func(t *testing.T) {
		primary, backup, moderator := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
		revoked := errors.New("authorization revoked")
		var denied bool
		reviewCalls, backupCalls := 0, 0
		r := &Router{resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "fixture", nil
		}, first: time.Second, total: 2 * time.Second, review: time.Second, load: func(context.Context, Call) (plan, error) {
			return plan{primary: primary, backup: backup, moderator: moderator}, nil
		}, record: func(context.Context, Call, attemptStat) error { return nil }, stop: func(context.Context, Scope, Terminal) error { return nil }}
		r.dispatch = func(_ context.Context, _ uuid.UUID, e endpoint, k Kind, _ Request) (Result, error) {
			if k == Moderation {
				reviewCalls++
				return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
			}
			if e.id == primary.id {
				denied = true
				return Result{}, ErrProvider
			}
			backupCalls++
			return Result{}, nil
		}
		c := Call{Task: RolePlay, Scope: scope, Mode: Text, Messages: []Message{{"user", "合成输入"}}, Guard: func(context.Context) error {
			if denied {
				return revoked
			}
			return nil
		}}
		if _, err := r.Run(context.Background(), c); !errors.Is(err, revoked) {
			t.Fatalf("got %v want revocation", err)
		}
		if reviewCalls != 1 || backupCalls != 0 {
			t.Fatalf("reviews=%d backup calls=%d", reviewCalls, backupCalls)
		}
	})
}

func TestCallPreservesFragmentEmitError(t *testing.T) {
	primary, moderator := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	want := errors.New("business callback rejected fragment")
	r := &Router{resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
		return uuid.New(), "fixture", nil
	}, first: time.Second, total: 2 * time.Second, review: time.Second, load: func(context.Context, Call) (plan, error) {
		return plan{primary: primary, moderator: moderator}, nil
	}, record: func(context.Context, Call, attemptStat) error { return nil }, stop: func(context.Context, Scope, Terminal) error { return nil }}
	r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, req Request) (Result, error) {
		if k == Moderation {
			return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
		}
		return Result{}, req.OnDelta("甲。")
	}
	c := Call{Task: RolePlay, Scope: Scope{User: uuid.New(), Operation: uuid.New(), Activity: uuid.New()}, Mode: Stream, Messages: []Message{{"user", "合成输入"}}, Emit: func(context.Context, Event) error {
		return want
	}}
	if _, err := r.Run(context.Background(), c); !errors.Is(err, want) {
		t.Fatalf("got %v want callback error", err)
	}
}

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

func TestGenerationHooksAndReplay(t *testing.T) {
	raw := `{"safety_flag":false,"value":"synthetic"}`
	newRouter := func(modelCalls, moderationCalls *int, order *[]string) *Router {
		model, moderator := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
		return &Router{
			first: time.Second, total: 2 * time.Second, review: time.Second,
			resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
				return uuid.New(), "synthetic rules", nil
			},
			load: func(context.Context, Call) (plan, error) {
				return plan{primary: model, moderator: moderator}, nil
			},
			record: func(context.Context, Call, attemptStat) error { return nil },
			stop:   func(context.Context, Scope, Terminal) error { return nil },
			dispatch: func(_ context.Context, _ uuid.UUID, _ endpoint, kind Kind, req Request) (Result, error) {
				if kind == Moderation {
					*moderationCalls++
					*order = append(*order, "moderate")
					return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
				}
				*modelCalls++
				*order = append(*order, "model")
				if err := req.OnDelta(raw); err != nil {
					return Result{}, err
				}
				return Result{}, nil
			},
		}
	}
	scope := Scope{User: uuid.New(), Operation: uuid.New(), Activity: uuid.New()}

	t.Run("object fallback respects checkpoint boundary", func(t *testing.T) {
		for _, checkpoint := range []bool{false, true} {
			modelCalls, checks, saved := 0, 0, 0
			var order []string
			r := newRouter(&modelCalls, &checks, &order)
			backup := endpoint{id: uuid.New()}
			load := r.load
			r.load = func(ctx context.Context, call Call) (plan, error) {
				p, err := load(ctx, call)
				p.backup = backup
				return p, err
			}
			r.dispatch = func(_ context.Context, _ uuid.UUID, target endpoint, kind Kind, req Request) (Result, error) {
				if kind == Moderation {
					checks++
					return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
				}
				modelCalls++
				if target.id == backup.id {
					return Result{}, req.OnDelta(raw)
				}
				return Result{}, req.OnDelta("not an object")
			}
			call := Call{Scope: scope, Task: ProfileInference, Mode: JSONObject, BeforeAttempt: func(context.Context) error { return nil }}
			if checkpoint {
				call.OnGenerated = func(context.Context, uuid.UUID, string) error { saved++; return nil }
			}
			reply, err := r.Run(t.Context(), call)
			if checkpoint {
				if !errors.Is(err, ErrProvider) || modelCalls != 1 || checks != 2 || saved != 1 {
					t.Fatalf("checkpointed retry: calls=%d reviews=%d saved=%d err=%v", modelCalls, checks, saved, err)
				}
			} else if err != nil || modelCalls != 2 || checks != 4 || string(reply.Result.Object) != raw {
				t.Fatalf("uncheckpointed fallback: calls=%d reviews=%d err=%v", modelCalls, checks, err)
			}
		}
	})

	t.Run("before dispatch then checkpoint before output review", func(t *testing.T) {
		modelCalls, moderationCalls := 0, 0
		var order []string
		var gotID uuid.UUID
		var gotRaw string
		r := newRouter(&modelCalls, &moderationCalls, &order)
		c := Call{Scope: scope, Task: Scoring, Mode: JSONObject, BeforeGenerate: func(context.Context) error {
			order = append(order, "before")
			return nil
		}, OnGenerated: func(_ context.Context, id uuid.UUID, value string) error {
			order = append(order, "generated")
			gotID, gotRaw = id, value
			return nil
		}}
		reply, err := r.Run(t.Context(), c)
		if err != nil || string(reply.Result.Object) != raw || reply.CallID == uuid.Nil {
			t.Fatalf("normal generation: reply=%+v err=%v", reply, err)
		}
		if !reflect.DeepEqual(order, []string{"moderate", "before", "model", "generated", "moderate"}) || modelCalls != 1 || moderationCalls != 2 {
			t.Fatalf("hook order=%v model=%d moderation=%d", order, modelCalls, moderationCalls)
		}
		if gotID != reply.CallID || gotRaw != raw {
			t.Fatalf("checkpoint hook got id=%s raw=%q", gotID, gotRaw)
		}
	})

	t.Run("before hook failure prevents dispatch", func(t *testing.T) {
		modelCalls, moderationCalls := 0, 0
		var order []string
		withdrawn := errors.New("synthetic withdrawal")
		r := newRouter(&modelCalls, &moderationCalls, &order)
		c := Call{Scope: scope, Task: Scoring, Mode: JSONObject, BeforeGenerate: func(context.Context) error { return withdrawn }, OnGenerated: func(context.Context, uuid.UUID, string) error {
			t.Fatal("checkpointed a withheld model call")
			return nil
		}}
		_, err := r.Run(t.Context(), c)
		if !errors.Is(err, withdrawn) || modelCalls != 0 || moderationCalls != 1 || !reflect.DeepEqual(order, []string{"moderate"}) {
			t.Fatalf("withdrawal: err=%v model=%d moderation=%d order=%v", err, modelCalls, moderationCalls, order)
		}
	})

	t.Run("fallback reauthorizes before input review", func(t *testing.T) {
		modelCalls, moderationCalls := 0, 0
		var order []string
		withdrawn := errors.New("synthetic fallback withdrawal")
		r := newRouter(&modelCalls, &moderationCalls, &order)
		primary := r.load
		r.load = func(ctx context.Context, c Call) (plan, error) {
			p, err := primary(ctx, c)
			p.backup = p.primary
			p.backup.id = uuid.New()
			return p, err
		}
		r.dispatch = func(_ context.Context, _ uuid.UUID, e endpoint, kind Kind, _ Request) (Result, error) {
			if kind == Moderation {
				moderationCalls++
				order = append(order, "moderate")
				return Result{Object: []byte(`{"verdict":"allow"}`)}, nil
			}
			modelCalls++
			order = append(order, "model")
			if modelCalls != 1 {
				t.Fatal("fallback model dispatched after withdrawal")
			}
			return Result{}, ErrProvider
		}
		beforeCalls := 0
		_, err := r.Run(t.Context(), Call{Scope: scope, Task: Scoring, Mode: JSONObject, Messages: []Message{{"user", "合成输入"}}, BeforeGenerate: func(context.Context) error {
			beforeCalls++
			order = append(order, "before")
			if beforeCalls == 1 {
				return nil
			}
			return withdrawn
		}})
		if !errors.Is(err, withdrawn) || modelCalls != 1 || moderationCalls != 1 || beforeCalls != 2 || !reflect.DeepEqual(order, []string{"moderate", "before", "model", "before"}) {
			t.Fatalf("fallback withdrawal: err=%v model=%d moderation=%d before=%d order=%v", err, modelCalls, moderationCalls, beforeCalls, order)
		}
	})

	t.Run("checkpoint failure stops output review and fallback", func(t *testing.T) {
		modelCalls, moderationCalls := 0, 0
		var order []string
		checkpointErr := errors.New("synthetic checkpoint failure")
		r := newRouter(&modelCalls, &moderationCalls, &order)
		// Give the router a fallback so a checkpoint failure cannot silently move
		// the same complete output to another model.
		primary := r.load
		r.load = func(ctx context.Context, c Call) (plan, error) {
			p, err := primary(ctx, c)
			p.backup = p.primary
			p.backup.id = uuid.New()
			return p, err
		}
		c := Call{Scope: scope, Task: Scoring, Mode: JSONObject, OnGenerated: func(context.Context, uuid.UUID, string) error {
			order = append(order, "generated")
			return checkpointErr
		}}
		reply, err := r.Run(t.Context(), c)
		if !errors.Is(err, checkpointErr) || reply.Terminal != nil || modelCalls != 1 || moderationCalls != 1 || !reflect.DeepEqual(order, []string{"moderate", "model", "generated"}) {
			t.Fatalf("checkpoint failure: reply=%+v err=%v model=%d moderation=%d order=%v", reply, err, modelCalls, moderationCalls, order)
		}
	})

	t.Run("input terminal skips before hook", func(t *testing.T) {
		modelCalls, moderationCalls := 0, 0
		var order []string
		r := newRouter(&modelCalls, &moderationCalls, &order)
		r.dispatch = func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error) {
			moderationCalls++
			return Result{Object: []byte(`{"verdict":"crisis"}`)}, nil
		}
		c := Call{Scope: scope, Task: Scoring, Mode: JSONObject, BeforeGenerate: func(context.Context) error {
			t.Fatal("authorized a terminal input")
			return nil
		}}
		reply, err := r.Run(t.Context(), c)
		if err != nil || reply.Terminal == nil || !reply.Terminal.Safety || modelCalls != 0 || moderationCalls != 1 {
			t.Fatalf("input terminal: reply=%+v err=%v model=%d moderation=%d", reply, err, modelCalls, moderationCalls)
		}
	})

	t.Run("generated replay skips model and checkpoint hook", func(t *testing.T) {
		modelCalls, moderationCalls := 0, 0
		var order []string
		id := uuid.New()
		r := newRouter(&modelCalls, &moderationCalls, &order)
		c := Call{Scope: scope, Task: Scoring, Mode: JSONObject, BeforeGenerate: func(context.Context) error {
			order = append(order, "before")
			return nil
		}, OnGenerated: func(context.Context, uuid.UUID, string) error {
			t.Fatal("rewrote an existing checkpoint")
			return nil
		}, Generated: &Generated{Task: Scoring, Raw: raw, CallID: id}}
		reply, err := r.Run(t.Context(), c)
		if err != nil || string(reply.Result.Object) != raw || reply.CallID != id || modelCalls != 0 || moderationCalls != 2 || !reflect.DeepEqual(order, []string{"moderate", "before", "moderate"}) {
			t.Fatalf("generated replay: reply=%+v err=%v model=%d moderation=%d order=%v", reply, err, modelCalls, moderationCalls, order)
		}
	})
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
			r := Router{resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
				return uuid.New(), "fixture", nil
			}, first: time.Second, total: 2 * time.Second, review: time.Second, load: func(context.Context, Call) (plan, error) { return plan{primary: p, backup: b, moderator: m}, nil }, record: func(_ context.Context, _ Call, s attemptStat) error { stats = append(stats, s); return nil }, stop: func(_ context.Context, got Scope, _ Terminal) error {
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
