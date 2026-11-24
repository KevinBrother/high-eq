package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"high-eq/server/internal/privacy"
)

func TestNewRouterWiresRoutedAccountingTransactions(t *testing.T) {
	stop := func(context.Context, Scope, Terminal) error { return nil }
	r, err := (&Catalog{}).NewRouter(privacy.NewCoordinator(nil, nil, nil), stop)
	if err != nil {
		t.Fatal(err)
	}
	if !r.routed || r.dispatch == nil || r.load == nil || r.record == nil || r.recordTx == nil {
		t.Fatalf("production router wiring: routed=%v dispatch=%v load=%v record=%v recordTx=%v", r.routed, r.dispatch != nil, r.load != nil, r.record != nil, r.recordTx != nil)
	}
}

type callbackLedgerTx struct {
	pgx.Tx
	rows map[uuid.UUID]bool
}

func (tx *callbackLedgerTx) Exec(_ context.Context, query string, args ...any) (pgconn.CommandTag, error) {
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

func TestRoutedAccountingUsesCallerTxForProviderFailureAndReplay(t *testing.T) {
	tx := &callbackLedgerTx{rows: map[uuid.UUID]bool{}}
	store := routingStore{access: func(context.Context, uuid.UUID, func(pgx.Tx) error) error {
		return errors.New("transactional accounting must not borrow another account session")
	}}
	model := endpoint{id: uuid.New(), inputPrice: "2", outputPrice: "3"}
	adapterCalls := 0
	r := &Router{
		routed: true,
		dispatch: routedDispatch(func(_ context.Context, gotTx pgx.Tx, id uuid.UUID, kind Kind, _ uuid.UUID) (adapter, target, error) {
			if gotTx != tx || id != model.id || kind != Model {
				return nil, target{}, errors.New("routed lookup escaped the caller transaction")
			}
			return testAdapterFunc(func(context.Context, target, Request) (Result, error) {
				adapterCalls++
				return Result{}, ErrProvider
			}), target{}, nil
		}),
		record: func(context.Context, Call, attemptStat) error {
			return errors.New("dispatched attempt was wrongly recorded outside the caller transaction")
		},
		recordTx: store.recordTx,
	}
	call := Call{
		Scope:        Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
		Task:         ProfileInference,
		Mode:         JSONObject,
		ProfileOwner: uuid.New(),
		Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			return send(ctx, tx)
		},
	}
	ctx, receipt := withDispatchReceipt(context.Background(), uuid.New())
	stat := attemptStat{id: receipt.id, model: model, start: time.Now(), outcome: "failed"}
	err := r.dispatchAuthorized(ctx, call, func(sendCtx context.Context, gotTx pgx.Tx) error {
		if gotTx != tx {
			return errors.New("authorization transaction was not propagated")
		}
		_, dispatchErr := r.dispatchOnce(sendCtx, uuid.Nil, model, Model, Request{})
		if logErr := r.logTx(sendCtx, gotTx, call, stat); logErr != nil {
			return logErr
		}
		if !tx.rows[receipt.id] {
			return errors.New("attempt was not visible in the caller transaction before authorization returned")
		}
		// A provider failure after crossing the adapter boundary remains a real
		// billable attempt. Repeated logging of that exact attempt is idempotent.
		for i := 0; i < 2; i++ {
			if logErr := r.logTx(sendCtx, gotTx, call, stat); logErr != nil {
				return logErr
			}
		}
		return dispatchErr
	})
	if !errors.Is(err, ErrProvider) {
		t.Fatalf("dispatch error=%v want %v", err, ErrProvider)
	}
	if adapterCalls != 1 || len(tx.rows) != 1 || !tx.rows[receipt.id] || !receipt.dispatched.Load() {
		t.Fatalf("adapter=%d ledger=%v receipt=%s dispatched=%v", adapterCalls, tx.rows, receipt.id, receipt.dispatched.Load())
	}
}

func TestProviderFailureIsAccountedBeforeAuthorizationReturns(t *testing.T) {
	tests := []struct {
		name       string
		kind       Kind
		dispatchAt int
	}{
		{name: "review failure", kind: Moderation, dispatchAt: 1},
		{name: "model failure", kind: Model, dispatchAt: 2},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			records, authorizations := 0, 0
			var callbackErr error
			var recordsInside int
			model := endpoint{id: uuid.New(), inputPrice: "2", outputPrice: "3"}
			moderator := endpoint{id: uuid.New(), inputPrice: "1", outputPrice: "1"}
			r := &Router{
				first:  time.Second,
				total:  2 * time.Second,
				review: time.Second,
				resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
					return uuid.New(), "synthetic profile instruction", nil
				},
				load: func(context.Context, Call) (plan, error) {
					return plan{primary: model, moderator: moderator}, nil
				},
				record: func(context.Context, Call, attemptStat) error {
					records++
					return nil
				},
				stop: func(context.Context, Scope, Terminal) error { return nil },
			}
			r.dispatch = func(_ context.Context, _ uuid.UUID, _ endpoint, kind Kind, _ Request) (Result, error) {
				if kind == Moderation && kind != tc.kind {
					return Result{Object: json.RawMessage(`{"verdict":"allow"}`)}, nil
				}
				if kind == Model && tc.kind == Model {
					return Result{}, ErrProvider
				}
				if kind == tc.kind {
					return Result{}, ErrProvider
				}
				return Result{}, errors.New("unexpected synthetic dispatch")
			}
			_, _ = r.Run(context.Background(), Call{
				Scope:        Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
				Task:         ProfileInference,
				Mode:         JSONObject,
				ProfileOwner: uuid.New(),
				Messages:     []Message{{Role: "user", Content: "synthetic material"}},
				Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
					authorizations++
					if authorizations != tc.dispatchAt {
						return send(ctx, nil)
					}
					before := records
					callbackErr = send(ctx, nil)
					recordsInside = records - before
					// A failed callback rolls back the caller-owned transaction.
					return callbackErr
				},
			})
			if callbackErr != nil || recordsInside != 1 {
				t.Fatalf("authorization callback error=%v accounting rows inside transaction=%d, want nil/1", callbackErr, recordsInside)
			}
		})
	}
}

func TestReviewTimeoutIsAccountedWithoutCancelingControlContext(t *testing.T) {
	records := 0
	model, moderator := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	r := &Router{
		first: time.Second, total: 2 * time.Second, review: 10 * time.Millisecond,
		resolvePrompt: func(context.Context, string, uuid.UUID, uuid.UUID, map[string]string) (uuid.UUID, string, error) {
			return uuid.New(), "synthetic profile instruction", nil
		},
		load: func(context.Context, Call) (plan, error) {
			return plan{primary: model, moderator: moderator}, nil
		},
		record: func(ctx context.Context, _ Call, _ attemptStat) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			records++
			return nil
		},
		stop: func(context.Context, Scope, Terminal) error { return nil },
	}
	r.dispatch = func(ctx context.Context, _ uuid.UUID, _ endpoint, _ Kind, _ Request) (Result, error) {
		<-ctx.Done()
		return Result{}, ctx.Err()
	}
	_, err := r.Run(context.Background(), Call{
		Scope:        Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()},
		Task:         ProfileInference,
		Mode:         JSONObject,
		ProfileOwner: uuid.New(),
		Messages:     []Message{{Role: "user", Content: "synthetic material"}},
		Authorize: func(ctx context.Context, _ pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			return send(ctx, nil)
		},
	})
	if err != nil || records != 1 {
		t.Fatalf("err=%v records=%d, want unavailable terminal with one durable accounting write", err, records)
	}
}
