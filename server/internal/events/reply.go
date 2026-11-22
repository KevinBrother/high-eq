package events

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// DispatchReplySelfTx is the transactional outbox variant of PublishFeedback.
// Publisher holds the coordinator's account lock; verify the exact live source
// and original timestamp before dispatching, never a chat or inferred state.
func (b *Bus) DispatchReplySelfTx(ctx context.Context, tx pgx.Tx, v Feedback) error {
	if v.Subject != "self" || v.ContactID != nil || v.SourceKind != "reply" {
		return errors.New("invalid reply feedback subject")
	}
	var ok bool
	e := tx.QueryRow(ctx, `select exists(select from reply_feedback f join activities a on a.id=f.activity_id where f.id=$1 and a.user_id=$2 and a.source_id=$3 and f.occurred_at=$4 and f.pending and f.self_report)`, v.FeedbackID, v.UserID, v.SourceID, v.OccurredAt).Scan(&ok)
	if e != nil {
		return e
	}
	if !ok {
		return pgx.ErrNoRows
	}
	return b.ProfileFeedback.dispatch(ctx, tx, v)
}

// DispatchReplyOutcomeTx is the transactional outbox variant for ordinary
// suggestion outcomes. It rechecks the exact live source and original
// timestamp while the caller holds the account lock, and emits no chat or
// effect text. Self-reported profile feedback has its own queue.
func (b *Bus) DispatchReplyOutcomeTx(ctx context.Context, tx pgx.Tx, v ReplyOutcome) error {
	if v.FeedbackID == uuid.Nil || v.UserID == uuid.Nil || v.SourceID == uuid.Nil || v.SourceKind != "reply" || v.OccurredAt.IsZero() {
		return errors.New("invalid reply outcome")
	}
	var ok bool
	e := tx.QueryRow(ctx, `select exists(
 select from reply_feedback f
 join reply_requests r on r.activity_id=f.activity_id and r.user_id=$2
 join activities a on a.id=f.activity_id
 where f.id=$1 and a.user_id=$2 and a.source_id=$3 and f.occurred_at=$4
   and a.kind='reply' and a.state='complete' and f.outcome_pending)`, v.FeedbackID, v.UserID, v.SourceID, v.OccurredAt).Scan(&ok)
	if e != nil {
		return e
	}
	if !ok {
		return pgx.ErrNoRows
	}
	return b.ReplyOutcome.dispatch(ctx, tx, v)
}
