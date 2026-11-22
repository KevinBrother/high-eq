package replies

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

// T25 records a canonical observation in the transaction that dispatches its
// key. Never infer a self-judgment from suggestions, a third party or prose.
type Recorder interface {
	RecordActivity(context.Context, pgx.Tx, events.Feedback, string, string) error
}

func (s *Service) AttachFeedback(r Recorder) { s.recorder = r } // composition root, before serving

// OutcomeDetails is the minimum source-module data a non-profile consumer
// needs for a reply outcome. The event itself must never carry this prose.
type OutcomeDetails struct {
	Index   int
	Outcome string
}

// ReadOutcomeTx resolves an opaque reply outcome key inside the caller's
// account-guarded transaction. It rechecks the exact live source and the
// contact's current write permission before decrypting any feedback text.
func (s *Service) ReadOutcomeTx(ctx context.Context, tx pgx.Tx, v events.ReplyOutcome) (OutcomeDetails, error) {
	var out OutcomeDetails
	if tx == nil || v.FeedbackID == uuid.Nil || v.UserID == uuid.Nil || v.SourceID == uuid.Nil || v.SourceKind != "reply" || v.OccurredAt.IsZero() {
		return out, accounts.ErrInvalid
	}
	if !privacy.AccessOwnedBy(tx, v.UserID) {
		return out, ErrMissing
	}
	var encrypted []byte
	var contact *uuid.UUID
	e := tx.QueryRow(ctx, `select f.outcome_enc,a.contact_id
 from reply_feedback f
 join reply_requests r on r.activity_id=f.activity_id and r.user_id=$2
 join activities a on a.id=f.activity_id
 where f.id=$1 and a.user_id=$2 and a.source_id=$3 and f.occurred_at=$4
   and a.kind='reply' and a.state='complete' and f.outcome_pending`, v.FeedbackID, v.UserID, v.SourceID, v.OccurredAt).Scan(&encrypted, &contact)
	if errors.Is(e, pgx.ErrNoRows) {
		return out, ErrMissing
	}
	if e != nil {
		return out, e
	}
	if contact != nil {
		if e = s.rights.RequireContact(ctx, tx, v.UserID, contact); e != nil {
			return out, e
		}
	}
	b, e := s.cipher.Open(encrypted, aad(v.UserID, v.FeedbackID, "outcome"))
	if e != nil {
		return out, e
	}
	var in app.RateReplyInput
	if json.Unmarshal(b, &in) != nil || strings.TrimSpace(in.Outcome) == "" || in.Index < 0 || in.Index > 2 {
		return out, accounts.ErrInvalid
	}
	return OutcomeDetails{Index: in.Index, Outcome: in.Outcome}, nil
}

func judgment(tag *app.RateReplyInputSelfReport) string {
	if tag != nil {
		switch *tag {
		case app.RateReplyInputSelfReportOverwhelmed:
			return "本人上头"
		case app.RateReplyInputSelfReportNotOverwhelmed:
			return "本人没有上头"
		}
	}
	return ""
}
func (s *Service) Feedback(ctx context.Context, p accounts.Principal, id uuid.UUID, in app.RateReplyInput) error {
	if strings.TrimSpace(in.Outcome) == "" || in.Index < 0 || in.Index > 2 || in.SelfReport != nil && judgment(in.SelfReport) == "" {
		return accounts.ErrInvalid
	}
	return s.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var contact *uuid.UUID
		var source uuid.UUID
		var enc []byte
		e := tx.QueryRow(ctx, `select source_id,contact_id,content_enc from activities where id=$1 and user_id=$2 and kind='reply' and state='complete'`, id, p.User).Scan(&source, &contact, &enc)
		if errors.Is(e, pgx.ErrNoRows) {
			return ErrMissing
		}
		if e != nil {
			return e
		}
		if contact != nil {
			if e = s.rights.RequireContact(ctx, tx, p.User, contact); e != nil {
				return e
			}
		}
		b, e := s.cipher.Open(enc, aad(p.User, id, "result"))
		if e != nil {
			return e
		}
		var r app.Reply
		if e = json.Unmarshal(b, &r); e != nil {
			return e
		}
		if in.Index >= len(r.Suggestions) {
			return accounts.ErrInvalid
		}
		mac := s.mac(id, in)
		var duplicate, confirmed bool
		e = tx.QueryRow(ctx, `select exists(select from reply_feedback where activity_id=$1 and input_mac=$2),exists(select from reply_feedback where activity_id=$1 and self_report)`, id, mac).Scan(&duplicate, &confirmed)
		if e != nil || duplicate {
			return e
		}
		if in.SelfReport != nil && confirmed {
			return membership.ErrConflict
		}
		fid := uuid.New()
		b, e = json.Marshal(in)
		if e != nil {
			return e
		}
		b, e = s.cipher.Seal(b, aad(p.User, fid, "outcome"))
		if e != nil {
			return e
		}
		v := events.Feedback{FeedbackID: fid, SourceID: source, UserID: p.User, Subject: "self", SourceKind: "reply"}
		e = tx.QueryRow(ctx, `insert into reply_feedback(id,activity_id,outcome_enc,input_mac,self_report,pending,outcome_pending) values($1,$2,$3,$4,$5,$5,true) returning occurred_at`, fid, id, b, mac, in.SelfReport != nil).Scan(&v.OccurredAt)
		if e == nil && in.SelfReport != nil && s.recorder != nil {
			return s.recorder.RecordActivity(ctx, tx, v, judgment(in.SelfReport), "")
		}
		return e
	})
}

// Discovery selects only opaque keys. Each queue rechecks owner/source and
// writable contact under the account lock. A missing subscriber or a failing
// row in one queue never blocks the other queue.
func (s *Service) ReplayPending(ctx context.Context) error {
	var first error
	if s.recorder != nil && s.bus.ProfileFeedback.HasSubscribers() {
		first = s.replay(ctx, `select a.user_id,f.id from reply_feedback f join activities a on a.id=f.activity_id where f.pending and f.self_report and f.id>$1 order by f.id limit 64`, s.deliverSelf)
	}
	if s.bus.ReplyOutcome.HasSubscribers() {
		e := s.replay(ctx, `select a.user_id,f.id from reply_feedback f join activities a on a.id=f.activity_id where f.outcome_pending and f.id>$1 order by f.id limit 64`, s.deliverOutcome)
		first = errors.Join(first, e)
	}
	return first
}

type delivery func(context.Context, uuid.UUID, uuid.UUID) error

func (s *Service) replay(ctx context.Context, query string, deliver delivery) error {
	var after uuid.UUID
	var first error
	for {
		rows, e := s.db.Query(ctx, query, after)
		if e != nil {
			return e
		}
		type key struct{ User, ID uuid.UUID }
		keys, e := pgx.CollectRows(rows, pgx.RowToStructByPos[key])
		if e != nil {
			return e
		}
		if len(keys) == 0 {
			return first
		}
		for _, k := range keys {
			after = k.ID
			e = deliver(ctx, k.User, k.ID)
			if e != nil && first == nil {
				first = e
			}
		}
	}
}

func (s *Service) deliverSelf(ctx context.Context, user, id uuid.UUID) error {
	return s.data.Access(ctx, user, func(tx pgx.Tx) error {
		v := events.Feedback{FeedbackID: id, UserID: user, SourceKind: "reply", Subject: "self"}
		var b []byte
		var contact *uuid.UUID
		e := tx.QueryRow(ctx, `select a.source_id,a.contact_id,f.occurred_at,f.outcome_enc from reply_feedback f join activities a on a.id=f.activity_id where f.id=$1 and a.user_id=$2 and a.kind='reply' and a.state='complete' and f.pending and f.self_report`, id, user).Scan(&v.SourceID, &contact, &v.OccurredAt, &b)
		if errors.Is(e, pgx.ErrNoRows) {
			return nil
		}
		if e != nil {
			return e
		}
		if contact != nil {
			e = s.rights.RequireContact(ctx, tx, user, contact)
			if errors.Is(e, membership.ErrForbidden) {
				return nil
			}
			if e != nil {
				return e
			}
		}
		b, e = s.cipher.Open(b, aad(user, id, "outcome"))
		if e != nil {
			return e
		}
		var in app.RateReplyInput
		if json.Unmarshal(b, &in) != nil || judgment(in.SelfReport) == "" {
			return accounts.ErrInvalid
		}
		if e = s.recorder.RecordActivity(ctx, tx, v, judgment(in.SelfReport), ""); e != nil {
			return e
		}
		if e = s.bus.DispatchReplySelfTx(ctx, tx, v); e != nil {
			return e
		}
		_, e = tx.Exec(ctx, `update reply_feedback set pending=false where id=$1 and pending and self_report`, id)
		return e
	})
}

func (s *Service) deliverOutcome(ctx context.Context, user, id uuid.UUID) error {
	return s.data.Access(ctx, user, func(tx pgx.Tx) error {
		v := events.ReplyOutcome{FeedbackID: id, UserID: user, SourceKind: "reply"}
		var contact *uuid.UUID
		e := tx.QueryRow(ctx, `select a.source_id,a.contact_id,f.occurred_at from reply_feedback f join activities a on a.id=f.activity_id where f.id=$1 and a.user_id=$2 and a.kind='reply' and a.state='complete' and f.outcome_pending`, id, user).Scan(&v.SourceID, &contact, &v.OccurredAt)
		if errors.Is(e, pgx.ErrNoRows) {
			return nil
		}
		if e != nil {
			return e
		}
		if contact != nil {
			e = s.rights.RequireContact(ctx, tx, user, contact)
			if errors.Is(e, membership.ErrForbidden) {
				return nil
			}
			if e != nil {
				return e
			}
		}
		if e = s.bus.DispatchReplyOutcomeTx(ctx, tx, v); e != nil {
			return e
		}
		_, e = tx.Exec(ctx, `update reply_feedback set outcome_pending=false where id=$1 and outcome_pending`, id)
		return e
	})
}
