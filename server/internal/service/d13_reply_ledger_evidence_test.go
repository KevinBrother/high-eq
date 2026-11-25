//go:build integration && d13flutter

package service

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// d13ReplyLedgerWitness contains only counts and state predicates. It never
// carries a user, request key, ticket, chat text, or generated reply text.
type d13ReplyLedgerWitness struct {
	KeyRows                   int
	KeyUsers                  int
	RequestRows               int
	RequestUsers              int
	ReplyActivities           int
	ReplyActivityUsers        int
	MatchedKeys               int
	OutageKeys                int
	CompleteKeys              int
	OutageWithoutLedger       int
	CompleteWithResult        int
	CompleteUnrefundedLedger  int
	CompleteSettledAttempt    int
	ReplyAttempts             int
	HeldAttempts              int
	ReplyLedgerRows           int
	ReplyUnrefundedLedgerRows int
	ReplyRefundedLedgerRows   int
	ReplyUsageUsers           int
	ReplyUsageTotal           int
}

type d13ContactInferenceWitness struct {
	BoundGrants int
	SourceRows  int
	Rows        int
	Users       int
	Invalidated int
	Complete    int
	Processing  int
}

func (w d13ContactInferenceWitness) validate() error {
	switch {
	case w.Processing != 0:
		return fmt.Errorf("profile inference processing rows = %d, want 0", w.Processing)
	case w.Rows != 2:
		return fmt.Errorf("profile inference rows = %d, want 2", w.Rows)
	case w.Users != 1:
		return fmt.Errorf("profile inference owners = %d, want 1", w.Users)
	case w.Invalidated != 1:
		return fmt.Errorf("invalidated profile inference rows = %d, want 1", w.Invalidated)
	case w.Complete != 1:
		return fmt.Errorf("complete profile inference rows = %d, want 1", w.Complete)
	case w.BoundGrants != 2:
		return fmt.Errorf("profile inference rows bound to the owner's grants = %d, want 2", w.BoundGrants)
	case w.SourceRows != 0:
		return fmt.Errorf("new historical-import source rows = %d, want 0", w.SourceRows)
	default:
		return nil
	}
}

func (w d13ReplyLedgerWitness) validate() error {
	switch {
	case w.KeyRows != 2:
		return fmt.Errorf("reply key rows = %d, want 2", w.KeyRows)
	case w.KeyUsers != 1:
		return fmt.Errorf("reply key owners = %d, want 1", w.KeyUsers)
	case w.RequestRows != 2:
		return fmt.Errorf("reply request rows = %d, want 2", w.RequestRows)
	case w.RequestUsers != 1:
		return fmt.Errorf("reply request owners = %d, want 1", w.RequestUsers)
	case w.ReplyActivities != 2:
		return fmt.Errorf("reply activity rows = %d, want 2", w.ReplyActivities)
	case w.ReplyActivityUsers != 1:
		return fmt.Errorf("reply activity owners = %d, want 1", w.ReplyActivityUsers)
	case w.MatchedKeys != 2:
		return fmt.Errorf("keys with matching request and activity ownership = %d, want 2", w.MatchedKeys)
	case w.OutageKeys != 1:
		return fmt.Errorf("moderation-outage keys = %d, want 1", w.OutageKeys)
	case w.CompleteKeys != 1:
		return fmt.Errorf("complete keys = %d, want 1", w.CompleteKeys)
	case w.OutageWithoutLedger != 1:
		return fmt.Errorf("outage keys without a ledger row = %d, want 1", w.OutageWithoutLedger)
	case w.CompleteWithResult != 1:
		return fmt.Errorf("complete keys with persisted result = %d, want 1", w.CompleteWithResult)
	case w.CompleteUnrefundedLedger != 1:
		return fmt.Errorf("complete keys with an unrefunded ledger row = %d, want 1", w.CompleteUnrefundedLedger)
	case w.CompleteSettledAttempt != 1:
		return fmt.Errorf("complete keys with a matching settled attempt = %d, want 1", w.CompleteSettledAttempt)
	case w.ReplyAttempts != 2:
		return fmt.Errorf("reply attempt rows = %d, want 2", w.ReplyAttempts)
	case w.HeldAttempts != 0:
		return fmt.Errorf("held reply attempts after settlement = %d, want 0", w.HeldAttempts)
	case w.ReplyLedgerRows != 1:
		return fmt.Errorf("reply ledger rows = %d, want 1", w.ReplyLedgerRows)
	case w.ReplyUnrefundedLedgerRows != 1:
		return fmt.Errorf("unrefunded reply ledger rows = %d, want 1", w.ReplyUnrefundedLedgerRows)
	case w.ReplyRefundedLedgerRows != 0:
		return fmt.Errorf("refunded reply ledger rows = %d, want 0", w.ReplyRefundedLedgerRows)
	case w.ReplyUsageUsers != 1:
		return fmt.Errorf("reply usage owners = %d, want 1", w.ReplyUsageUsers)
	case w.ReplyUsageTotal != 1:
		return fmt.Errorf("reply usage total = %d, want 1", w.ReplyUsageTotal)
	default:
		return nil
	}
}

func TestD13ReplyLedgerWitnessRejectsReservationWithoutLedger(t *testing.T) {
	witness := d13ReplyLedgerWitness{
		KeyRows:                   2,
		KeyUsers:                  1,
		RequestRows:               2,
		RequestUsers:              1,
		ReplyActivities:           2,
		ReplyActivityUsers:        1,
		MatchedKeys:               2,
		OutageKeys:                1,
		CompleteKeys:              1,
		OutageWithoutLedger:       1,
		CompleteWithResult:        1,
		CompleteUnrefundedLedger:  0,
		CompleteSettledAttempt:    1,
		ReplyAttempts:             2,
		HeldAttempts:              1,
		ReplyLedgerRows:           0,
		ReplyUnrefundedLedgerRows: 0,
		ReplyRefundedLedgerRows:   0,
		ReplyUsageUsers:           1,
		ReplyUsageTotal:           1,
	}
	err := witness.validate()
	if err == nil {
		t.Fatal("reservation-only witness without a durable ledger row was accepted")
	}
	if !strings.Contains(err.Error(), "unrefunded ledger row") {
		t.Fatalf("reservation-only witness failed for the wrong reason: %v", err)
	}
}

func TestD13ReplyLedgerWitnessRejectsHeldAttemptAlongsideLedger(t *testing.T) {
	witness := validD13ReplyLedgerWitness()
	witness.HeldAttempts = 1
	if err := witness.validate(); err == nil {
		t.Fatal("held reservation was accepted as settled ledger evidence")
	}
}

func TestD13ReplyLedgerWitnessAcceptsSettledLedger(t *testing.T) {
	if err := validD13ReplyLedgerWitness().validate(); err != nil {
		t.Fatal(err)
	}
}

func TestD13ContactInferenceWitnessRejectsProcessingReservation(t *testing.T) {
	witness := d13ContactInferenceWitness{
		Rows:        2,
		Users:       1,
		Invalidated: 1,
		Processing:  1,
	}
	err := witness.validate()
	if err == nil {
		t.Fatal("processing profile inference reservation was accepted as settled evidence")
	}
	if !strings.Contains(err.Error(), "processing") {
		t.Fatalf("processing reservation failed for the wrong reason: %v", err)
	}
}

func TestD13ContactInferenceWitnessAcceptsInvalidatedAndComplete(t *testing.T) {
	witness := d13ContactInferenceWitness{
		Rows:        2,
		Users:       1,
		Invalidated: 1,
		Complete:    1,
		BoundGrants: 2,
	}
	if err := witness.validate(); err != nil {
		t.Fatal(err)
	}
}

func validD13ReplyLedgerWitness() d13ReplyLedgerWitness {
	return d13ReplyLedgerWitness{
		KeyRows:                   2,
		KeyUsers:                  1,
		RequestRows:               2,
		RequestUsers:              1,
		ReplyActivities:           2,
		ReplyActivityUsers:        1,
		MatchedKeys:               2,
		OutageKeys:                1,
		CompleteKeys:              1,
		OutageWithoutLedger:       1,
		CompleteWithResult:        1,
		CompleteUnrefundedLedger:  1,
		CompleteSettledAttempt:    1,
		ReplyAttempts:             2,
		HeldAttempts:              0,
		ReplyLedgerRows:           1,
		ReplyUnrefundedLedgerRows: 1,
		ReplyRefundedLedgerRows:   0,
		ReplyUsageUsers:           1,
		ReplyUsageTotal:           1,
	}
}

// verifyD13ReplyLedger reads the committed fixture through a connection and
// read-only repeatable-read transaction that are independent of the service
// pool. It runs only after the real Flutter-to-Go flow has completed.
func verifyD13ReplyLedger(ctx context.Context, t *testing.T, databaseURL string) error {
	t.Helper()

	conn, err := pgx.Connect(ctx, databaseURL)
	if err != nil {
		return fmt.Errorf("connect independently for D13 ledger evidence: %w", err)
	}
	defer conn.Close(context.Background())
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{
		IsoLevel:   pgx.RepeatableRead,
		AccessMode: pgx.ReadOnly,
	})
	if err != nil {
		return fmt.Errorf("begin independent D13 ledger evidence transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()

	replyWitness, err := loadD13ReplyLedgerWitness(ctx, tx)
	if err != nil {
		return fmt.Errorf("read D13 reply ledger evidence: %w", err)
	}
	if err = replyWitness.validate(); err != nil {
		return fmt.Errorf("D13 durable reply ledger evidence: %w", err)
	}
	contactWitness, err := loadD13ContactInferenceWitness(ctx, tx)
	if err != nil {
		return fmt.Errorf("read D13 contact inference evidence: %w", err)
	}
	if err = contactWitness.validate(); err != nil {
		return fmt.Errorf("D13 contact inference evidence: %w", err)
	}
	if err = tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit independent D13 ledger evidence transaction: %w", err)
	}
	t.Logf("D13_LEDGER_STAGE:verified keys=%d outage_keys=%d complete_keys=%d ledger=%d unrefunded=%d held=0", replyWitness.KeyRows, replyWitness.OutageKeys, replyWitness.CompleteKeys, replyWitness.ReplyLedgerRows, replyWitness.ReplyUnrefundedLedgerRows)
	t.Logf("D13_CONTACT_INFERENCE_STAGE:verified rows=%d invalidated=%d complete=%d processing=0", contactWitness.Rows, contactWitness.Invalidated, contactWitness.Complete)
	return nil
}

func loadD13ContactInferenceWitness(ctx context.Context, tx pgx.Tx) (d13ContactInferenceWitness, error) {
	const query = `
select count(*), count(distinct i.user_id),
       count(*) filter (where i.state='invalidated' and i.owner_id is null and i.lease_expires_at is null),
       count(*) filter (where i.state='complete' and i.owner_id is null and i.lease_expires_at is null),
       count(*) filter (where i.state='processing'),
       count(*) filter (where chat.id is not null and contacts.id is not null
         and exists(select from reply_requests r where r.user_id=i.user_id)),
       (select count(*) from chat_imports)
from profile_inference_requests i
left join consents chat on chat.id=i.chat_consent_id and chat.user_id=i.user_id
  and chat.purpose='chat_import' and chat.version='2026-11'
left join consents contacts on contacts.id=i.contacts_consent_id and contacts.user_id=i.user_id
  and contacts.purpose='contacts' and contacts.version='2026-11'`

	var witness d13ContactInferenceWitness
	err := tx.QueryRow(ctx, query).Scan(
		&witness.Rows,
		&witness.Users,
		&witness.Invalidated,
		&witness.Complete,
		&witness.Processing,
		&witness.BoundGrants,
		&witness.SourceRows,
	)
	if err != nil {
		return d13ContactInferenceWitness{}, err
	}
	return witness, nil
}

func loadD13ReplyLedgerWitness(ctx context.Context, tx pgx.Tx) (d13ReplyLedgerWitness, error) {
	const query = `
with key_rows as (
  select k.user_id as key_user_id, k.request_id as key_request_id,
         k.activity_id as key_activity_id, a.state as activity_state,
         a.content_enc, r.user_id as request_user_id,
         r.activity_id as request_activity_id, c.id as bound_grant_id,
         k.input_mac as key_input_mac, r.input_mac as request_input_mac,
         q.state as attempt_state, q.metered, q.held_day,
         l.activity_id as ledger_activity_id, l.charged_day, l.refunded_at
  from reply_request_keys k
  left join reply_requests r
    on r.user_id=k.user_id and r.request_id=k.request_id
  left join consents c on c.id=r.chat_consent_id and c.user_id=r.user_id
    and c.purpose='reply_chat_import' and c.version='2026-11-reply'
  left join activities a
    on a.id=k.activity_id and a.user_id=k.user_id and a.kind='reply'
  left join quota_attempts q on q.activity_id=a.id
  left join quota_ledger l on l.activity_id=a.id
)
select
  (select count(*) from reply_request_keys),
  (select count(distinct user_id) from reply_request_keys),
  (select count(*) from reply_requests),
  (select count(distinct user_id) from reply_requests),
  (select count(*) from activities where kind='reply'),
  (select count(distinct user_id) from activities where kind='reply'),
  count(*) filter (where request_activity_id=key_activity_id
    and request_user_id=key_user_id and request_input_mac=key_input_mac
    and activity_state is not null and bound_grant_id is not null),
  count(*) filter (where activity_state='moderation_unavailable'),
  count(*) filter (where activity_state='complete'),
  count(*) filter (where activity_state='moderation_unavailable'
    and ledger_activity_id is null),
  count(*) filter (where activity_state='complete'
    and coalesce(octet_length(content_enc),0)>0),
  count(*) filter (where activity_state='complete'
    and ledger_activity_id=key_activity_id and refunded_at is null),
  count(*) filter (where activity_state='complete'
    and attempt_state='complete' and metered
    and held_day=charged_day and refunded_at is null),
  (select count(*) from quota_attempts q join activities a on a.id=q.activity_id
    where a.kind='reply'),
  (select count(*) from quota_attempts q join activities a on a.id=q.activity_id
    where a.kind='reply' and q.state='held'),
  (select count(*) from quota_ledger l join activities a on a.id=l.activity_id
    where a.kind='reply'),
  (select count(*) from quota_ledger l join activities a on a.id=l.activity_id
    where a.kind='reply' and l.refunded_at is null),
  (select count(*) from quota_ledger l join activities a on a.id=l.activity_id
    where a.kind='reply' and l.refunded_at is not null),
  (select count(distinct user_id) from daily_quota_usage
    where feature='reply' and used>0),
  (select coalesce(sum(used),0)::int from daily_quota_usage where feature='reply')
from key_rows`

	var witness d13ReplyLedgerWitness
	err := tx.QueryRow(ctx, query).Scan(
		&witness.KeyRows,
		&witness.KeyUsers,
		&witness.RequestRows,
		&witness.RequestUsers,
		&witness.ReplyActivities,
		&witness.ReplyActivityUsers,
		&witness.MatchedKeys,
		&witness.OutageKeys,
		&witness.CompleteKeys,
		&witness.OutageWithoutLedger,
		&witness.CompleteWithResult,
		&witness.CompleteUnrefundedLedger,
		&witness.CompleteSettledAttempt,
		&witness.ReplyAttempts,
		&witness.HeldAttempts,
		&witness.ReplyLedgerRows,
		&witness.ReplyUnrefundedLedgerRows,
		&witness.ReplyRefundedLedgerRows,
		&witness.ReplyUsageUsers,
		&witness.ReplyUsageTotal,
	)
	if err != nil {
		return d13ReplyLedgerWitness{}, err
	}
	return witness, nil
}
