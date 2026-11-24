package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestAttemptAccountingRequiresDispatchedReceipt(t *testing.T) {
	records := 0
	r := &Router{record: func(context.Context, Call, attemptStat) error {
		records++
		return nil
	}}
	err := r.log(context.Background(), Call{
		Scope: Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
		Task:  ProfileInference,
	}, attemptStat{
		id:      uuid.New(),
		model:   endpoint{id: uuid.New(), inputPrice: "2", outputPrice: "3"},
		start:   time.Now(),
		outcome: "failed",
	})
	if err != nil {
		t.Fatal(err)
	}
	if records != 0 {
		t.Fatalf("recorded %d attempt(s) without proof that an adapter received the request", records)
	}
}

type idempotentLedgerTx struct {
	pgx.Tx
	rows map[uuid.UUID]bool
}

func (tx *idempotentLedgerTx) Exec(_ context.Context, query string, args ...any) (pgconn.CommandTag, error) {
	if !strings.Contains(query, "insert into ai_calls") || len(args) == 0 {
		return pgconn.NewCommandTag("INSERT 0 0"), nil
	}
	id, ok := args[0].(uuid.UUID)
	if !ok {
		return pgconn.CommandTag{}, errors.New("synthetic attempt id missing")
	}
	if tx.rows[id] {
		if !strings.Contains(strings.ToLower(query), "on conflict (id) do nothing") {
			return pgconn.CommandTag{}, errors.New("synthetic duplicate attempt")
		}
		return pgconn.NewCommandTag("INSERT 0 0"), nil
	}
	tx.rows[id] = true
	return pgconn.NewCommandTag("INSERT 0 1"), nil
}

func TestAttemptAccountingIsIdempotentForOneDispatch(t *testing.T) {
	tx := &idempotentLedgerTx{rows: map[uuid.UUID]bool{}}
	store := routingStore{access: func(_ context.Context, _ uuid.UUID, fn func(pgx.Tx) error) error {
		return fn(tx)
	}}
	call := Call{
		Scope: Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
		Task:  ProfileInference,
	}
	stat := attemptStat{
		id:      uuid.New(),
		model:   endpoint{id: uuid.New(), inputPrice: "2", outputPrice: "3"},
		start:   time.Now(),
		usage:   Result{UsageKnown: true, InputTokens: 10, OutputTokens: 5},
		outcome: "ok",
	}
	for i := 0; i < 2; i++ {
		if err := store.record(context.Background(), call, stat); err != nil {
			t.Fatalf("replay %d: %v", i+1, err)
		}
	}
	stat.id = uuid.New()
	stat.usage = Result{UsageKnown: true, InputTokens: 20, OutputTokens: 6}
	if err := store.record(context.Background(), call, stat); err != nil {
		t.Fatal(err)
	}
	if len(tx.rows) != 2 {
		t.Fatalf("ledger rows=%d, want one row per real attempt and no replay duplicate", len(tx.rows))
	}
}

type testAdapterFunc func(context.Context, target, Request) (Result, error)

func (f testAdapterFunc) chat(ctx context.Context, t target, r Request) (Result, error) {
	return f(ctx, t, r)
}

type syntheticTx struct{ pgx.Tx }

type stateChangeError struct{ state string }

func (e stateChangeError) Error() string { return "synthetic authorization state: " + e.state }

type syntheticStateFence struct {
	tx    pgx.Tx
	lock  sync.Mutex
	state atomic.Value
}

func newSyntheticStateFence(tx pgx.Tx) *syntheticStateFence {
	f := &syntheticStateFence{tx: tx}
	f.state.Store("live")
	return f
}

func (f *syntheticStateFence) current() string { return f.state.Load().(string) }

func (f *syntheticStateFence) authorize(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
	f.lock.Lock()
	defer f.lock.Unlock()
	if state := f.current(); state != "live" {
		return stateChangeError{state: state}
	}
	return send(ctx, f.tx)
}

func (f *syntheticStateFence) move(state string) {
	f.lock.Lock()
	f.state.Store(state)
	f.lock.Unlock()
}

func (f *syntheticStateFence) moveAtBoundary(state string) (<-chan struct{}, <-chan struct{}) {
	started, committed := make(chan struct{}), make(chan struct{})
	go func() {
		close(started)
		f.lock.Lock()
		f.state.Store(state)
		f.lock.Unlock()
		close(committed)
	}()
	return started, committed
}

func waitSignal(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %s", what)
	}
}

func assertSignalBlocked(t *testing.T, ch <-chan struct{}, what string) {
	t.Helper()
	select {
	case <-ch:
		t.Fatalf("%s committed inside the provider authorization boundary", what)
	default:
	}
}

func TestProfileOwnerRequiresAuthorizeBeforeLoad(t *testing.T) {
	loads, dispatchCalls := 0, 0
	r := &Router{
		load: func(context.Context, Call) (plan, error) {
			loads++
			return plan{}, nil
		},
		dispatch: func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error) {
			dispatchCalls++
			return Result{}, nil
		},
		stop: func(context.Context, Scope, Terminal) error { return nil },
	}
	_, err := r.Run(context.Background(), Call{
		Scope:        Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
		Task:         ProfileInference,
		Mode:         JSONObject,
		ProfileOwner: uuid.New(),
		Messages:     []Message{{Role: "user", Content: "synthetic material"}},
	})
	if !errors.Is(err, ErrConfig) || loads != 0 || dispatchCalls != 0 {
		t.Fatalf("err=%v loads=%d dispatches=%d, want ErrConfig before load/dispatch", err, loads, dispatchCalls)
	}
}

func TestProfileAuthorizationStateIsFencedAtAdapterBoundary(t *testing.T) {
	states := []string{"consent_withdrawn", "account_frozen", "deletion_pending", "owner_replaced"}
	for _, state := range states {
		t.Run(state+"/before_authorize", func(t *testing.T) {
			tx := &syntheticTx{}
			fence := newSyntheticStateFence(tx)
			fence.move(state)
			lookups, adapterCalls, records := 0, 0, 0
			r := &Router{
				routed: true,
				dispatch: routedDispatch(func(context.Context, pgx.Tx, uuid.UUID, Kind, uuid.UUID) (adapter, target, error) {
					lookups++
					return nil, target{}, errors.New("lookup must not run")
				}),
				record: func(context.Context, Call, attemptStat) error { records++; return nil },
			}
			ctx, receipt := withDispatchReceipt(context.Background(), uuid.New())
			err := r.dispatchAuthorized(ctx, Call{Authorize: fence.authorize}, func(sendCtx context.Context, gotTx pgx.Tx) error {
				if gotTx != tx {
					return errors.New("authorization transaction was not propagated")
				}
				_, err := r.dispatchOnce(sendCtx, uuid.Nil, endpoint{id: uuid.New()}, Model, Request{})
				return err
			})
			var changed stateChangeError
			if !errors.As(err, &changed) || changed.state != state || lookups != 0 || adapterCalls != 0 || receipt.dispatched.Load() {
				t.Fatalf("err=%v state=%q lookups=%d adapter=%d dispatched=%v", err, changed.state, lookups, adapterCalls, receipt.dispatched.Load())
			}
			if err := r.log(ctx, Call{}, attemptStat{id: receipt.id}); err != nil {
				t.Fatal(err)
			}
			if records != 0 {
				t.Fatalf("unreachable adapter produced %d accounting rows", records)
			}
		})

		t.Run(state+"/precheck_to_adapter", func(t *testing.T) {
			tx := &syntheticTx{}
			fence := newSyntheticStateFence(tx)
			model := endpoint{id: uuid.New(), inputPrice: "2", outputPrice: "3"}
			prechecked := make(chan struct{})
			lookupStarted := make(chan struct{})
			releaseLookup := make(chan struct{})
			adapterStarted := make(chan struct{})
			releaseAdapter := make(chan struct{})
			records, prechecks, lookups, adapterCalls := 0, 0, 0, 0
			lookup := func(ctx context.Context, gotTx pgx.Tx, id uuid.UUID, kind Kind, rev uuid.UUID) (adapter, target, error) {
				lookups++
				if gotTx != tx || id != model.id || kind != Model {
					return nil, target{}, errors.New("routed lookup escaped authorization transaction")
				}
				if ctx.Err() != nil {
					return nil, target{}, ctx.Err()
				}
				close(lookupStarted)
				select {
				case <-releaseLookup:
				case <-ctx.Done():
					return nil, target{}, ctx.Err()
				}
				return testAdapterFunc(func(ctx context.Context, _ target, _ Request) (Result, error) {
					adapterCalls++
					if got := fence.current(); got != "live" {
						return Result{}, errors.New("adapter entered after authorization loss: " + got)
					}
					close(adapterStarted)
					select {
					case <-releaseAdapter:
					case <-ctx.Done():
						return Result{}, ctx.Err()
					}
					return Result{UsageKnown: true, InputTokens: 7, OutputTokens: 3}, nil
				}), target{}, nil
			}
			r := &Router{
				routed:   true,
				dispatch: routedDispatch(lookup),
				record:   func(context.Context, Call, attemptStat) error { records++; return nil },
			}
			call := Call{
				Scope:        Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
				Task:         ProfileInference,
				Mode:         JSONObject,
				ProfileOwner: uuid.New(),
				Authorize:    fence.authorize,
				BeforeAttempt: func(attemptCtx context.Context) error {
					prechecks++
					if got := authorizedTx(attemptCtx); got != tx {
						return errors.New("precheck escaped authorization transaction")
					}
					if got := fence.current(); got != "live" {
						return stateChangeError{state: got}
					}
					close(prechecked)
					return nil
				},
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			ctx, receipt := withDispatchReceipt(ctx, uuid.New())
			done := make(chan error, 1)
			go func() {
				done <- r.dispatchAuthorized(ctx, call, func(sendCtx context.Context, gotTx pgx.Tx) error {
					if gotTx != tx {
						return errors.New("authorization transaction was not propagated")
					}
					if err := r.beforeAttempt(sendCtx, call); err != nil {
						return err
					}
					_, err := r.dispatchOnce(sendCtx, uuid.Nil, model, Model, Request{})
					return err
				})
			}()
			waitSignal(t, prechecked, "authorization precheck")
			started, committed := fence.moveAtBoundary(state)
			waitSignal(t, started, "state transition attempt")
			assertSignalBlocked(t, committed, state)
			waitSignal(t, lookupStarted, "route lookup")
			assertSignalBlocked(t, committed, state)
			close(releaseLookup)
			waitSignal(t, adapterStarted, "provider adapter")
			assertSignalBlocked(t, committed, state)
			close(releaseAdapter)
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("authorized dispatch did not finish")
			}
			waitSignal(t, committed, "state transition after provider return")
			if fence.current() != state || prechecks != 1 || lookups != 1 || adapterCalls != 1 || !receipt.dispatched.Load() {
				t.Fatalf("state=%q prechecks=%d lookups=%d adapter=%d dispatched=%v", fence.current(), prechecks, lookups, adapterCalls, receipt.dispatched.Load())
			}
			stat := attemptStat{
				id: receipt.id, model: model, start: time.Now(),
				usage: Result{UsageKnown: true, InputTokens: 7, OutputTokens: 3}, outcome: "ok",
			}
			if err := r.log(ctx, call, stat); err != nil {
				t.Fatal(err)
			}
			if records != 1 {
				t.Fatalf("accounting rows=%d, want one for the real adapter attempt after owner/state loss", records)
			}
		})
	}
}

func TestAttemptAccountingRequiresAdapterBoundary(t *testing.T) {
	rejected := errors.New("synthetic authorization rejected")
	lookupErr := errors.New("synthetic routed lookup failed")
	for _, tc := range []struct {
		name          string
		routed        bool
		authorize     func(context.Context, pgx.Tx, func(context.Context, pgx.Tx) error) error
		beforeAttempt func(context.Context) error
		lookup        func(context.Context, pgx.Tx, uuid.UUID, Kind, uuid.UUID) (adapter, target, error)
		want          error
		wantLookups   int
		wantAdapters  int
	}{
		{
			name: "authorize rejected",
			authorize: func(context.Context, pgx.Tx, func(context.Context, pgx.Tx) error) error {
				return rejected
			},
			want: rejected,
		},
		{
			name: "authorize silently skipped",
			authorize: func(context.Context, pgx.Tx, func(context.Context, pgx.Tx) error) error {
				return nil
			},
			want: errAuthorizationSkipped,
		},
		{
			name: "before attempt rejected",
			authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
				return send(ctx, nil)
			},
			beforeAttempt: func(context.Context) error { return rejected },
			want:          rejected,
		},
		{
			name:   "route lookup failed before adapter",
			routed: true,
			authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
				return send(ctx, nil)
			},
			lookup: func(context.Context, pgx.Tx, uuid.UUID, Kind, uuid.UUID) (adapter, target, error) {
				return nil, target{}, lookupErr
			},
			want:        lookupErr,
			wantLookups: 1,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			records, adapters := 0, 0
			r := &Router{
				routed: tc.routed,
				record: func(context.Context, Call, attemptStat) error { records++; return nil },
				dispatch: func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error) {
					adapters++
					return Result{}, nil
				},
			}
			if tc.lookup != nil {
				r.dispatch = routedDispatch(tc.lookup)
			}
			call := Call{Authorize: tc.authorize, BeforeAttempt: tc.beforeAttempt}
			ctx, receipt := withDispatchReceipt(context.Background(), uuid.New())
			err := r.dispatchAuthorized(ctx, call, func(sendCtx context.Context, _ pgx.Tx) error {
				if err := r.beforeAttempt(sendCtx, call); err != nil {
					return err
				}
				_, err := r.dispatchOnce(sendCtx, uuid.Nil, endpoint{id: uuid.New()}, Model, Request{})
				return err
			})
			if !errors.Is(err, tc.want) {
				t.Fatalf("err=%v want %v", err, tc.want)
			}
			if receipt.dispatched.Load() || adapters != tc.wantAdapters {
				t.Fatalf("dispatched=%v adapters=%d want %d", receipt.dispatched.Load(), adapters, tc.wantAdapters)
			}
			if err := r.log(ctx, call, attemptStat{id: receipt.id}); err != nil {
				t.Fatal(err)
			}
			if records != 0 {
				t.Fatalf("accounting rows=%d before an adapter received the attempt", records)
			}
		})
	}
}

func TestEveryReviewPrimaryAndFallbackAttemptHasOneReceipt(t *testing.T) {
	primary := endpoint{id: uuid.New(), inputPrice: "2", outputPrice: "3", includeUsage: true}
	backup := endpoint{id: uuid.New(), inputPrice: "4", outputPrice: "5"}
	moderator := endpoint{id: uuid.New(), inputPrice: "1", outputPrice: "1"}
	r := &Router{
		first: time.Second, total: 2 * time.Second, review: time.Second,
		resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "synthetic profile instruction", nil
		},
		load: func(context.Context, Call) (plan, error) {
			return plan{primary: primary, backup: backup, moderator: moderator}, nil
		},
		stop: func(context.Context, Scope, Terminal) error { return nil },
	}
	var dispatchSequence []string
	dispatchIDs := map[uuid.UUID]bool{}
	var recordIDs []uuid.UUID
	r.record = func(_ context.Context, _ Call, s attemptStat) error {
		recordIDs = append(recordIDs, s.id)
		return nil
	}
	authorizations := 0
	r.dispatch = func(ctx context.Context, _ uuid.UUID, e endpoint, k Kind, req Request) (Result, error) {
		receipt := dispatchReceiptFrom(ctx)
		if receipt == nil || !receipt.dispatched.Load() {
			return Result{}, errors.New("attempt reached adapter without a marked receipt")
		}
		dispatchIDs[receipt.id] = true
		slot := "moderator"
		if e.id == primary.id {
			slot = "primary"
		} else if e.id == backup.id {
			slot = "backup"
		}
		dispatchSequence = append(dispatchSequence, string(k)+"/"+slot)
		if k == Moderation {
			return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
		}
		if e.id == primary.id {
			return Result{}, ErrProvider
		}
		if err := req.OnDelta(`{"ok":true}`); err != nil {
			return Result{}, err
		}
		return Result{}, nil
	}
	out, err := r.Run(context.Background(), Call{
		Scope:        Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
		Task:         ProfileInference,
		Mode:         JSONObject,
		ProfileOwner: uuid.New(),
		Messages:     []Message{{Role: "user", Content: "synthetic material"}},
		Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			authorizations++
			return send(ctx, nil)
		},
	})
	if err != nil || string(out.Result.Object) != `{"ok":true}` {
		t.Fatalf("result=%q err=%v", out.Result.Object, err)
	}
	wantSequence := []string{"moderation/moderator", "model/primary", "moderation/moderator", "model/backup", "moderation/moderator"}
	if !slices.Equal(dispatchSequence, wantSequence) {
		t.Fatalf("dispatch sequence=%v want %v", dispatchSequence, wantSequence)
	}
	// Input review, primary generation, fallback input review, fallback
	// generation, and final output review are five external dispatches. Each
	// must hold its own authorization scope and own accounting receipt.
	if authorizations != 5 {
		t.Fatalf("authorizations=%d, want one external scope per provider dispatch", authorizations)
	}
	if len(dispatchIDs) != 5 || len(recordIDs) != 5 {
		t.Fatalf("dispatch receipts=%d records=%d, want five distinct attempts", len(dispatchIDs), len(recordIDs))
	}
	seen := map[uuid.UUID]bool{}
	for _, id := range recordIDs {
		if !dispatchIDs[id] {
			t.Fatalf("accounting id %s has no matching adapter receipt", id)
		}
		if seen[id] {
			t.Fatalf("attempt %s was accounted more than once", id)
		}
		seen[id] = true
	}
}

func TestDispatchedAttemptAccountsAfterOwnerLossAndReplayIsIdempotent(t *testing.T) {
	ledger := &idempotentLedgerTx{rows: map[uuid.UUID]bool{}}
	store := routingStore{access: func(_ context.Context, _ uuid.UUID, fn func(pgx.Tx) error) error {
		return fn(ledger)
	}}
	dispatched := false
	r := &Router{
		dispatch: func(context.Context, uuid.UUID, endpoint, Kind, Request) (Result, error) {
			dispatched = true
			return Result{}, nil
		},
		record: store.record,
	}
	call := Call{
		Scope:        Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
		Task:         ProfileInference,
		ProfileOwner: uuid.New(),
	}
	model := endpoint{id: uuid.New(), inputPrice: "2", outputPrice: "3"}
	ctx, cancel := context.WithCancel(context.Background())
	ctx, receipt := withDispatchReceipt(ctx, uuid.New())
	if _, err := r.dispatchOnce(ctx, uuid.Nil, model, Model, Request{}); err != nil {
		t.Fatal(err)
	}
	if !dispatched || !receipt.dispatched.Load() {
		t.Fatal("synthetic adapter boundary was not crossed")
	}
	// Owner replacement and request cancellation happen after material reached
	// the adapter. The provider cost must still be retained exactly once.
	cancel()
	stat := attemptStat{
		id: receipt.id, model: model, start: time.Now(),
		usage: Result{UsageKnown: true, InputTokens: 11, OutputTokens: 4}, outcome: "ok",
	}
	for i := 0; i < 2; i++ {
		if err := r.log(ctx, call, stat); err != nil {
			t.Fatalf("late accounting replay %d: %v", i+1, err)
		}
	}

	// A different executor that never crossed the adapter boundary owns no
	// accounting receipt and must not write. A replacement executor that did
	// dispatch is a distinct real attempt and must be retained.
	loserCtx, loserReceipt := withDispatchReceipt(context.Background(), uuid.New())
	if err := r.log(loserCtx, call, attemptStat{id: loserReceipt.id, model: model, start: time.Now(), outcome: "failed"}); err != nil {
		t.Fatal(err)
	}
	replacementCtx, replacementReceipt := withDispatchReceipt(context.Background(), uuid.New())
	if _, err := r.dispatchOnce(replacementCtx, uuid.Nil, model, Model, Request{}); err != nil {
		t.Fatal(err)
	}
	replacementCall := call
	replacementCall.ProfileOwner = uuid.New()
	if err := r.log(replacementCtx, replacementCall, attemptStat{
		id: replacementReceipt.id, model: model, start: time.Now(),
		usage: Result{UsageKnown: true, InputTokens: 13, OutputTokens: 5}, outcome: "ok",
	}); err != nil {
		t.Fatal(err)
	}
	if len(ledger.rows) != 2 || !ledger.rows[receipt.id] || !ledger.rows[replacementReceipt.id] || ledger.rows[loserReceipt.id] {
		t.Fatalf("ledger rows=%v, want exactly the two dispatched attempts", ledger.rows)
	}
}
