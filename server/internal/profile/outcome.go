package profile

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/events"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/replies"
)

// OutcomeReader is the source-module boundary for a non-profile reply outcome.
// Reading resolves the encrypted effect text only inside the source module.
type OutcomeReader interface {
	ReadOutcomeTx(context.Context, pgx.Tx, events.ReplyOutcome) (replies.OutcomeDetails, error)
}

// ConsumeReplyOutcome records a durable, non-profile delivery receipt for a
// reply outcome. It deliberately does not create a profile observation: another
// person's reaction is not evidence about the user, and effect prose is never
// copied out of the reply source.
func (s *Service) ConsumeReplyOutcome(ctx context.Context, tx pgx.Tx, v events.ReplyOutcome, reader OutcomeReader) error {
	if tx == nil || reader == nil || v.FeedbackID == uuid.Nil || v.UserID == uuid.Nil || v.SourceID == uuid.Nil || v.SourceKind != "reply" || v.OccurredAt.IsZero() {
		return accounts.ErrInvalid
	}

	if !privacy.AccessOwnedBy(tx, v.UserID) {
		return replies.ErrMissing
	}
	receipt, found, err := readOutcomeReceipt(ctx, tx, v.FeedbackID)
	if err != nil {
		return err
	}
	if found {
		if receipt.UserID != v.UserID || receipt.SourceID != v.SourceID || receipt.SourceKind != v.SourceKind || !receipt.OccurredAt.Equal(v.OccurredAt) {
			return accounts.ErrInvalid
		}
		return nil
	}

	details, err := reader.ReadOutcomeTx(ctx, tx, v)
	if err != nil {
		return err
	}
	if details.Index < 0 || details.Index > 2 {
		return accounts.ErrInvalid
	}
	_, err = tx.Exec(ctx, `insert into reply_outcome_receipts(feedback_id,user_id,source_id,source_kind,occurred_at,suggestion_index) values($1,$2,$3,$4,$5,$6) on conflict(feedback_id) do nothing`, v.FeedbackID, v.UserID, v.SourceID, v.SourceKind, v.OccurredAt, details.Index)
	if err != nil {
		return err
	}

	// A concurrent identical delivery may have inserted first. Re-read so a
	// different key for the same feedback ID is rejected rather than mistaken
	// for an idempotent replay.
	receipt, found, err = readOutcomeReceipt(ctx, tx, v.FeedbackID)
	if err != nil {
		return err
	}
	if !found || receipt.UserID != v.UserID || receipt.SourceID != v.SourceID || receipt.SourceKind != v.SourceKind || !receipt.OccurredAt.Equal(v.OccurredAt) {
		return accounts.ErrInvalid
	}
	return nil
}

type outcomeReceipt struct {
	UserID     uuid.UUID
	SourceID   uuid.UUID
	SourceKind string
	OccurredAt time.Time
}

func readOutcomeReceipt(ctx context.Context, tx pgx.Tx, feedbackID uuid.UUID) (outcomeReceipt, bool, error) {
	var v outcomeReceipt
	err := tx.QueryRow(ctx, `select user_id,source_id,source_kind,occurred_at from reply_outcome_receipts where feedback_id=$1`, feedbackID).Scan(&v.UserID, &v.SourceID, &v.SourceKind, &v.OccurredAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return outcomeReceipt{}, false, nil
	}
	if err != nil {
		return outcomeReceipt{}, false, err
	}
	return v, true, nil
}
