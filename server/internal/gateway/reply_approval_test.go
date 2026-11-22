package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Exercise the production T10 router (not a fake result validator). The only
// controlled parts are config, append-only audit sink and upstream transport.
func TestReplyWholeObjectApproval(t *testing.T) {
	const full = `{"possible_feeling":"可能在担心","possible_need":"明确时间","suggestions":[{"style":"确认","text":"要对齐时间吗？","reason":"求证"},{"style":"直接","text":"周三交。","reason":"明确承诺"}]}`
	for _, verdict := range []string{"allow", "crisis", "unknown", "timeout"} {
		t.Run(verdict, func(t *testing.T) {
			model, review := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
			checked := 0
			stops := 0
			generations := 0
			r := Router{first: time.Second, total: time.Second, review: time.Second,
				resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
					return uuid.New(), "synthetic coaching instruction", nil
				},
				load: func(context.Context, Call) (plan, error) { return plan{primary: model, moderator: review}, nil },
				record: func(_ context.Context, c Call, a attemptStat) error {
					if c.Messages != nil || c.Variables != nil || len(a.usage.Object) != 0 || a.usage.Text != "" {
						return errors.New("content in telemetry")
					}
					return nil
				}, stop: func(context.Context, Scope, Terminal) error { stops++; return nil }}
			r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, q Request) (Result, error) {
				if k == Model {
					generations++
					mid := strings.Index(full, `"suggestions"`)
					for _, chunk := range []string{full[:mid], full[mid:]} {
						if e := q.OnDelta(chunk); e != nil {
							return Result{}, e
						}
					}
					return Result{}, nil
				}
				checked++
				if checked == 1 {
					if !strings.Contains(q.Messages[1].Content, "synthetic chat") {
						t.Fatal("input not reviewed")
					}
					return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
				}
				if checked != 2 || q.Messages[1].Content != full {
					t.Fatal("review was not of the whole output")
				}
				if verdict == "timeout" {
					return Result{}, context.DeadlineExceeded
				}
				return Result{Object: json.RawMessage(`{"verdict":"` + verdict + `"}`)}, nil
			}
			out, e := r.Run(context.Background(), Call{Task: ReplySuggestion, Mode: JSONObject, Scope: Scope{User: uuid.New(), Operation: uuid.New()}, Messages: []Message{{"user", "synthetic chat"}}})
			if e != nil || checked != 2 || generations != 1 {
				t.Fatal("routing/approval mismatch", e)
			}
			if verdict == "allow" {
				if stops != 0 || out.Terminal != nil || string(out.Result.Object) != full {
					t.Fatal("not approved result")
				}
			} else if stops != 1 || out.Terminal == nil || out.Terminal.Safety != (verdict == "crisis") || len(out.Result.Object) != 0 || out.CallID != uuid.Nil {
				t.Fatal("leaked or misclassified blocked output")
			}
		})
	}
}

func TestReplySuggestionCannotDeclareCrisis(t *testing.T) {
	model, review := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	generations, stops := 0, 0
	r := Router{first: time.Second, total: time.Second, review: time.Second,
		resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "synthetic instruction", nil
		},
		load: func(context.Context, Call) (plan, error) {
			return plan{primary: model, moderator: review}, nil
		},
		record: func(context.Context, Call, attemptStat) error { return nil },
		stop: func(context.Context, Scope, Terminal) error {
			stops++
			return nil
		},
	}
	const unsafe = `{"safety_flag":true}`
	r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, q Request) (Result, error) {
		if k == Model {
			generations++
			return Result{}, q.OnDelta(unsafe)
		}
		return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
	}
	out, e := r.Run(context.Background(), Call{Task: ReplySuggestion, Mode: JSONObject, Scope: Scope{User: uuid.New(), Operation: uuid.New()}, Messages: []Message{{"user", "synthetic chat"}}})
	if e != nil || generations != 1 || stops != 0 || out.Terminal != nil || string(out.Result.Object) != unsafe {
		t.Fatalf("reply model self-declared crisis: err=%v generations=%d stops=%d terminal=%+v object=%s", e, generations, stops, out.Terminal, out.Result.Object)
	}
}

func TestCallAuthorizeGuardsEveryUpstreamDispatch(t *testing.T) {
	for _, tc := range []struct {
		name           string
		revokeAt       int
		wantAuth       int
		wantDispatches int
		wantErr        bool
	}{
		{name: "all allowed", wantAuth: 3, wantDispatches: 3},
		{name: "revoked before input review", revokeAt: 1, wantAuth: 1, wantDispatches: 0, wantErr: true},
		{name: "revoked before model", revokeAt: 2, wantAuth: 2, wantDispatches: 1, wantErr: true},
		{name: "revoked before output review", revokeAt: 3, wantAuth: 3, wantDispatches: 2, wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			model, review := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
			revoked := errors.New("consent withdrawn")
			authorizations, dispatches := 0, 0
			r := Router{first: time.Second, total: time.Second, review: time.Second,
				resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
					return uuid.New(), "synthetic instruction", nil
				},
				load: func(context.Context, Call) (plan, error) {
					return plan{primary: model, moderator: review}, nil
				},
				record: func(context.Context, Call, attemptStat) error { return nil },
				stop:   func(context.Context, Scope, Terminal) error { return nil },
			}
			r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, q Request) (Result, error) {
				dispatches++
				if k == Moderation {
					return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
				}
				return Result{}, q.OnDelta(`{"possible_feeling":"担心","possible_need":"时间","suggestions":[{"style":"确认","text":"周三可以吗？","reason":"确认时间"},{"style":"直接","text":"周三给你。","reason":"给出承诺"}]}`)
			}
			_, e := r.Run(context.Background(), Call{
				Task: ReplySuggestion, Mode: JSONObject,
				Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
				Messages: []Message{{"user", "synthetic chat"}},
				Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
					authorizations++
					if authorizations == tc.revokeAt {
						return revoked
					}
					return send(ctx, nil)
				},
			})
			if dispatches != tc.wantDispatches || authorizations != tc.wantAuth || (tc.wantErr && !errors.Is(e, revoked)) || (!tc.wantErr && e != nil) {
				t.Fatalf("authorizations=%d dispatches=%d err=%v", authorizations, dispatches, e)
			}
		})
	}
}

func TestCallAuthorizeCannotSilentlySkipDispatch(t *testing.T) {
	for _, tc := range []struct {
		name           string
		skipAt         int
		wantDispatches int
	}{
		{name: "before input review", skipAt: 1, wantDispatches: 0},
		{name: "before output review", skipAt: 3, wantDispatches: 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			model, review := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
			authorizations, dispatches := 0, 0
			r := Router{first: time.Second, total: time.Second, review: time.Second,
				resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
					return uuid.New(), "synthetic instruction", nil
				},
				load: func(context.Context, Call) (plan, error) {
					return plan{primary: model, moderator: review}, nil
				},
				record: func(context.Context, Call, attemptStat) error { return nil },
				stop:   func(context.Context, Scope, Terminal) error { return nil },
			}
			r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, q Request) (Result, error) {
				dispatches++
				if k == Moderation {
					return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
				}
				return Result{}, q.OnDelta(`{"possible_feeling":"担心","possible_need":"时间","suggestions":[{"style":"确认","text":"周三可以吗？","reason":"确认时间"},{"style":"直接","text":"周三给你。","reason":"给出承诺"}]}`)
			}
			out, e := r.Run(context.Background(), Call{
				Task: ReplySuggestion, Mode: JSONObject,
				Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
				Messages: []Message{{Role: "user", Content: "synthetic chat"}},
				Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
					authorizations++
					if authorizations == tc.skipAt {
						return nil
					}
					return send(ctx, nil)
				},
			})
			if !errors.Is(e, errAuthorizationSkipped) || dispatches != tc.wantDispatches || out.Terminal != nil || len(out.Result.Object) != 0 {
				t.Fatalf("authorizations=%d dispatches=%d terminal=%+v object=%q err=%v", authorizations, dispatches, out.Terminal, out.Result.Object, e)
			}
		})
	}
}

func TestCallAuthorizeGuardsBackupDispatch(t *testing.T) {
	primary, backup, review := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	revoked := errors.New("consent withdrawn")
	authorizations, dispatches := 0, 0
	r := Router{first: time.Second, total: time.Second, review: time.Second,
		resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "synthetic instruction", nil
		},
		load: func(context.Context, Call) (plan, error) {
			return plan{primary: primary, backup: backup, moderator: review}, nil
		},
		record: func(context.Context, Call, attemptStat) error { return nil },
		stop:   func(context.Context, Scope, Terminal) error { return nil },
	}
	r.dispatch = func(_ context.Context, _ uuid.UUID, model endpoint, kind Kind, _ Request) (Result, error) {
		dispatches++
		if kind == Moderation {
			return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
		}
		if model == primary {
			return Result{}, ErrProvider
		}
		t.Fatal("backup model dispatched after authorization was revoked")
		return Result{}, nil
	}
	_, e := r.Run(context.Background(), Call{
		Task: ReplySuggestion, Mode: JSONObject,
		Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
		Messages: []Message{{Role: "user", Content: "synthetic chat"}},
		Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			authorizations++
			if authorizations == 4 {
				return revoked
			}
			return send(ctx, nil)
		},
	})
	if !errors.Is(e, revoked) || authorizations != 4 || dispatches != 3 {
		t.Fatalf("authorizations=%d dispatches=%d err=%v", authorizations, dispatches, e)
	}
}

func TestCallAuthorizeReusesInFlightAuthorizationForNestedModeration(t *testing.T) {
	model, review := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	authorizations, dispatches := 0, 0
	active := false
	var emitted []string
	r := Router{first: time.Second, total: time.Second, review: time.Second,
		resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "synthetic instruction", nil
		},
		load: func(context.Context, Call) (plan, error) {
			return plan{primary: model, moderator: review}, nil
		},
		record: func(context.Context, Call, attemptStat) error { return nil },
		stop:   func(context.Context, Scope, Terminal) error { return nil },
	}
	r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, k Kind, q Request) (Result, error) {
		if !active {
			t.Fatal("dispatch escaped its authorization scope")
		}
		dispatches++
		if k == Moderation {
			return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
		}
		return Result{}, q.OnDelta("第一句。")
	}
	_, e := r.Run(context.Background(), Call{
		Task: ContentGeneration, Mode: Stream,
		Scope:    Scope{User: uuid.New(), Operation: uuid.New()},
		Messages: []Message{{Role: "user", Content: "synthetic chat"}},
		Emit: func(_ context.Context, v Event) error {
			emitted = append(emitted, v.Text)
			return nil
		},
		Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			authorizations++
			active = true
			defer func() { active = false }()
			return send(ctx, nil)
		},
	})
	if e != nil || authorizations != 3 || dispatches != 4 || strings.Join(emitted, "") != "第一句。" {
		t.Fatalf("authorizations=%d dispatches=%d emitted=%q err=%v", authorizations, dispatches, strings.Join(emitted, ""), e)
	}
}

type blockingAdapter struct {
	started chan struct{}
	release chan struct{}
	delta   string
}

func (a blockingAdapter) chat(ctx context.Context, _ target, r Request) (Result, error) {
	close(a.started)
	select {
	case <-a.release:
		return Result{}, r.OnDelta(a.delta)
	case <-ctx.Done():
		return Result{}, ctx.Err()
	}
}

// The production dispatch closure does a revision lookup before opening the
// provider request. A withdrawal must not commit during either phase, and the
// provider request must not start until the lookup has returned.
func TestCallAuthorizeHoldsScopeThroughRoutedLookupAndProvider(t *testing.T) {
	model, review := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	lookupStarted := make(chan struct{})
	releaseLookup := make(chan struct{})
	providerStarted := make(chan struct{})
	releaseProvider := make(chan struct{})

	lookup := func(ctx context.Context, _ pgx.Tx, id uuid.UUID, kind Kind, rev uuid.UUID) (adapter, target, error) {
		if id != model.id || kind != Model || rev != uuid.Nil {
			return nil, target{}, errors.New("unexpected provider lookup")
		}
		close(lookupStarted)
		select {
		case <-releaseLookup:
			return blockingAdapter{started: providerStarted, release: releaseProvider, delta: `{"ok":true}`}, target{}, nil
		case <-ctx.Done():
			return nil, target{}, ctx.Err()
		}
	}
	r := Router{first: 5 * time.Second, total: 5 * time.Second, review: 5 * time.Second,
		resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "synthetic instruction", nil
		},
		load: func(context.Context, Call) (plan, error) {
			return plan{primary: model, moderator: review}, nil
		},
		record: func(context.Context, Call, attemptStat) error { return nil },
		stop:   func(context.Context, Scope, Terminal) error { return nil },
	}
	r.dispatch = func(ctx context.Context, rev uuid.UUID, e endpoint, k Kind, q Request) (Result, error) {
		if k == Moderation {
			return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
		}
		return routedDispatch(lookup)(ctx, rev, e, k, q)
	}

	var account sync.Mutex
	withdrawn := make(chan struct{})
	authorizations := 0
	authorize := func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
		authorizations++
		if authorizations != 2 {
			return send(ctx, nil)
		}
		account.Lock()
		defer account.Unlock()
		return send(ctx, nil)
	}
	type result struct {
		out Reply
		err error
	}
	done := make(chan result, 1)
	go func() {
		out, err := r.Run(context.Background(), Call{
			Task: ReplySuggestion, Mode: JSONObject,
			Scope:     Scope{User: uuid.New(), Operation: uuid.New()},
			Messages:  []Message{{Role: "user", Content: "synthetic chat"}},
			Authorize: authorize,
		})
		done <- result{out, err}
	}()

	select {
	case <-lookupStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("provider lookup did not start")
	}
	go func() {
		account.Lock()
		close(withdrawn)
		account.Unlock()
	}()
	select {
	case <-withdrawn:
		t.Fatal("withdrawal committed during revision lookup")
	default:
	}
	select {
	case <-providerStarted:
		t.Fatal("provider request started before revision lookup returned")
	default:
	}

	close(releaseLookup)
	select {
	case <-providerStarted:
	case <-time.After(5 * time.Second):
		t.Fatal("provider request did not start")
	}
	select {
	case <-withdrawn:
		t.Fatal("withdrawal committed during provider request")
	default:
	}
	close(releaseProvider)

	select {
	case got := <-done:
		if got.err != nil || got.out.Terminal != nil || string(got.out.Result.Object) != `{"ok":true}` {
			t.Fatalf("routing result: terminal=%+v object=%q err=%v", got.out.Terminal, got.out.Result.Object, got.err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("routing did not finish")
	}
	select {
	case <-withdrawn:
	case <-time.After(5 * time.Second):
		t.Fatal("withdrawal did not commit after dispatch returned")
	}
	if authorizations != 3 {
		t.Fatalf("authorizations=%d, want input/model/output review", authorizations)
	}
}
