package gateway

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type profileAccountingTx struct {
	pgx.Tx
	query string
	args  []any
	err   error
}

func (tx *profileAccountingTx) Exec(_ context.Context, query string, args ...any) (pgconn.CommandTag, error) {
	tx.query, tx.args = query, append([]any(nil), args...)
	if tx.err != nil {
		return pgconn.CommandTag{}, tx.err
	}
	return pgconn.NewCommandTag("INSERT 0 1"), nil
}

func TestProfileAccountingBindsAttemptToExactAccountAndRequest(t *testing.T) {
	scope := Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New(), Activity: uuid.New(), PromptVersion: uuid.New()}
	owner, attempt := uuid.New(), uuid.New()
	model := endpoint{id: uuid.New(), inputPrice: "1000", outputPrice: "2000"}
	tx := &profileAccountingTx{}
	store := routingStore{access: func(_ context.Context, user uuid.UUID, fn func(pgx.Tx) error) error {
		if user != scope.User {
			t.Fatalf("accounting locked user %s, want %s", user, scope.User)
		}
		return fn(tx)
	}}
	err := store.record(t.Context(), Call{Scope: scope, Task: ProfileInference, ProfileOwner: owner}, attemptStat{
		id: attempt, model: model, start: time.Now(), elapsed: 25 * time.Millisecond,
		usage: Result{UsageKnown: true, InputTokens: 12, OutputTokens: 3}, outcome: "ok",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(strings.ToLower(tx.query), "on conflict (id) do nothing") {
		t.Fatal("attempt ledger write is not idempotent by attempt id")
	}
	want := []any{attempt, scope.Operation, scope.User, scope.Activity, scope.Contact, ProfileInference,
		model.id, scope.PromptVersion, tx.args[8], "ok", int64(25), 12, 3, "1000", "2000"}
	if len(tx.args) != len(want) {
		t.Fatalf("ledger args=%d want %d", len(tx.args), len(want))
	}
	for i := range want {
		if i == 8 {
			if _, ok := tx.args[i].(time.Time); !ok {
				t.Fatalf("started_at has type %T, want time.Time", tx.args[i])
			}
			continue
		}
		if !reflect.DeepEqual(tx.args[i], want[i]) {
			t.Fatalf("ledger arg %d=%#v want %#v", i, tx.args[i], want[i])
		}
	}
}

func TestProfileAccountingRequiresDispatchedReceiptAndPreservesAuditErrors(t *testing.T) {
	databaseErr := errors.New("synthetic database failure")
	for _, tc := range []struct {
		name       string
		dispatched bool
		recordErr  error
		wantWrites int
		wantErr    error
	}{
		{name: "not dispatched"},
		{name: "dispatched", dispatched: true, wantWrites: 1},
		{name: "dispatched database failure", dispatched: true, recordErr: databaseErr, wantWrites: 1, wantErr: errAudit},
	} {
		t.Run(tc.name, func(t *testing.T) {
			writes := 0
			r := &Router{record: func(context.Context, Call, attemptStat) error {
				writes++
				return tc.recordErr
			}}
			call := Call{Scope: Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()}, Task: ProfileInference}
			stat := attemptStat{id: uuid.New(), model: endpoint{id: uuid.New()}}
			ctx, receipt := withDispatchReceipt(t.Context(), stat.id)
			receipt.dispatched.Store(tc.dispatched)
			err := r.log(ctx, call, stat)
			if !errors.Is(err, tc.wantErr) || writes != tc.wantWrites {
				t.Fatalf("audit err=%v writes=%d, want %v/%d", err, writes, tc.wantErr, tc.wantWrites)
			}
		})
	}
}

func TestProfileAccountingTxFailureIsAuditError(t *testing.T) {
	databaseErr := errors.New("synthetic transaction failure")
	tx := &syntheticTx{}
	writes, fallbackWrites := 0, 0
	r := &Router{
		record: func(context.Context, Call, attemptStat) error {
			fallbackWrites++
			return nil
		},
		recordTx: func(_ context.Context, gotTx pgx.Tx, _ Call, _ attemptStat) error {
			if gotTx != tx {
				t.Fatal("accounting lost the caller transaction")
			}
			writes++
			return databaseErr
		},
	}
	stat := attemptStat{id: uuid.New(), model: endpoint{id: uuid.New()}}
	ctx, receipt := withDispatchReceipt(t.Context(), stat.id)
	receipt.dispatched.Store(true)
	err := r.logTx(ctx, tx, Call{Scope: Scope{User: uuid.New(), Contact: uuid.New(), Operation: uuid.New()}, Task: ProfileInference}, stat)
	if !errors.Is(err, errAudit) || writes != 1 || fallbackWrites != 0 {
		t.Fatalf("audit err=%v tx writes=%d fallback writes=%d", err, writes, fallbackWrites)
	}
}
