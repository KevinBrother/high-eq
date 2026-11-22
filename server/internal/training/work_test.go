package training

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"high-eq/server/internal/membership"
)

type settlementFenceRow struct {
	pending bool
	outcome string
	state   string
	worker  *uuid.UUID
}

func (r settlementFenceRow) Scan(dest ...any) error {
	*dest[0].(*bool) = r.pending
	*dest[1].(*string) = r.outcome
	*dest[2].(*string) = r.state
	*dest[3].(**uuid.UUID) = r.worker
	return nil
}

type settlementFenceTx struct {
	pgx.Tx
	worker *uuid.UUID
	exec   bool
}

func (tx *settlementFenceTx) QueryRow(context.Context, string, ...any) pgx.Row {
	return settlementFenceRow{state: "moderation_unavailable", worker: tx.worker}
}

func (tx *settlementFenceTx) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	tx.exec = true
	return pgconn.CommandTag{}, nil
}

func TestSettlePendingRejectsStaleWorker(t *testing.T) {
	original := uuid.New()
	for _, tc := range []struct {
		name string
		run  uuid.UUID
	}{
		{name: "different worker", run: uuid.New()},
		{name: "missing worker token", run: uuid.Nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx := &settlementFenceTx{worker: &original}
			err := (&Service{}).settlePendingTx(context.Background(), tx, job{record: record{Session: Session{SessionSummary: SessionSummary{ID: uuid.New()}}}, run: tc.run})
			if !errors.Is(err, membership.ErrConflict) {
				t.Fatalf("got %v want worker fence conflict", err)
			}
			if tx.exec {
				t.Fatal("stale worker reached settlement writes")
			}
		})
	}
}
