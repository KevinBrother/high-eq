// Package privacy serializes account reads, event projections and erasure. A
// module must not access personal data outside the guarded transaction.
package privacy

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var (
	ErrHidden   = errors.New("data unavailable")
	ErrNotFound = errors.New("data not found")
)

type Coordinator struct {
	db       *pgxpool.Pool
	ledger   *Ledger
	registry *Registry
}

func NewCoordinator(p *pgxpool.Pool, l *Ledger, r *Registry) *Coordinator {
	return &Coordinator{p, l, r}
}

type root struct {
	id      uuid.UUID
	scope   string
	childOf *uuid.UUID
	pending bool
}

func (r root) isChildOf(id uuid.UUID) bool {
	return r.childOf != nil && *r.childOf == id
}

func roots(ctx context.Context, tx pgx.Tx, user uuid.UUID) ([]root, error) {
	var locked uuid.UUID
	if e := tx.QueryRow(ctx, `select id from users where id=$1 for update`, user).Scan(&locked); e != nil {
		return nil, e
	}
	rows, e := tx.Query(ctx, `select root_id,scope,parent_id,p.root_id is not null from erasure_roots left join pending_erasure p using(root_id) where user_id=$1 order by root_id`, user)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	var roots []root
	for rows.Next() {
		var r root
		if e := rows.Scan(&r.id, &r.scope, &r.childOf, &r.pending); e != nil {
			return nil, e
		}
		roots = append(roots, r)
	}
	return roots, rows.Err()
}

// accountAccessTx carries the identity actually guarded by Access. It is
// deliberately unexported: event keys alone do not authorize a source read.
type accountAccessTx struct {
	pgx.Tx
	owner uuid.UUID
}

func AccessOwnedBy(tx pgx.Tx, owner uuid.UUID) bool {
	guarded, ok := tx.(*accountAccessTx)
	return ok && guarded != nil && owner != uuid.Nil && guarded.owner == owner
}

// Access conservatively hides the whole account while any source is pending:
// derived rows may not themselves carry the deleted source key.
func (c *Coordinator) Access(ctx context.Context, user uuid.UUID, fn func(pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, c.db, func(tx pgx.Tx) error {
		if err := c.GuardTx(ctx, tx, user); err != nil {
			return err
		}
		var frozen bool
		if e := tx.QueryRow(ctx, "select closure_requested_at is not null from users where id=$1", user).Scan(&frozen); e != nil {
			return e
		}
		if frozen {
			return ErrHidden
		}
		return fn(&accountAccessTx{Tx: tx, owner: user})
	})
}

// DiscardProfileInference removes only this account's abandoned processing
// reservation. It deliberately bypasses the freeze check (a frozen account
// still needs failed inference cleanup) while retaining the deletion barrier,
// account lock, and account-scoped predicate.
func (c *Coordinator) DiscardProfileInference(ctx context.Context, user, request uuid.UUID) error {
	if user == uuid.Nil || request == uuid.Nil {
		return errors.New("invalid inference cleanup")
	}
	return pgx.BeginFunc(ctx, c.db, func(tx pgx.Tx) error {
		if err := c.GuardTx(ctx, tx, user); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `delete from profile_inference_requests where user_id=$1 and request_id=$2 and state='processing'`, user, request)
		return err
	})
}

// GuardTx extends the deletion barrier to caller-owned login/recovery transactions.
// Locks remain held through its commit. Never perform business reads before this check.
func (c *Coordinator) GuardTx(ctx context.Context, tx pgx.Tx, user uuid.UUID) error {
	rr, e := roots(ctx, tx, user)
	if e != nil {
		return e
	}
	ids := make([]uuid.UUID, 0, len(rr))
	for _, r := range rr {
		if r.pending {
			return ErrHidden
		}
		ids = append(ids, r.id)
	}
	blocked, e := c.ledger.blocked(ctx, ids)
	if e != nil {
		return e
	}
	if blocked {
		return ErrHidden
	}
	return nil
}

type Deletion struct {
	OperationID, UserID, SourceID uuid.UUID
	Scope                         string
}

// DeletionIntent is the committed, authoritative result of an ownership check.
// Its external activity ID has already been resolved to the internal root key.
type DeletionIntent struct {
	deletion Deletion
	rootID   uuid.UUID
	// Only online contact requests recheck the session-bound barrier in cleanup.
	recheckContactBarrier bool
}

var removes = map[string]string{
	"signal_windows": `delete from signal_windows where user_id=$1 and purge_id=$2`,

	"account":       `delete from users where id=$1 and purge_id=$2`,
	"assessments":   `delete from assessments where user_id=$1 and id=$2`,
	"sessions":      `delete from activities where user_id=$1 and source_id=$2 and kind in ('practice','drill')`,
	"reviews":       `delete from activities where user_id=$1 and source_id=$2 and kind='review'`,
	"replies":       `delete from activities where user_id=$1 and source_id=$2 and kind='reply'`,
	"contacts":      `delete from contacts where user_id=$1 and id=$2`,
	"manual_marks":  `delete from manual_marks where user_id=$1 and id=$2`,
	"signal_events": `delete from signal_events where user_id=$1 and id=$2`,
}

// No distributed transaction: first persist a fail-closed intent. A crash at
// any later boundary can be retried from that root, including after ledger TTL.
func (c *Coordinator) Delete(ctx context.Context, d Deletion) error {
	return c.DeleteIf(ctx, d, nil)
}

// DeleteOwned is the account-facing deletion boundary. Unlike the idempotent
// internal Delete, it rejects missing, foreign and wrong-kind resources with
// ErrNotFound. Activity-scoped requests accept the activity ID and resolve the
// source ID under the same account lock used to journal the deletion.
func (c *Coordinator) DeleteOwned(ctx context.Context, d Deletion) error {
	var found bool
	e := c.DeleteIf(ctx, d, func(tx pgx.Tx) (uuid.UUID, bool, error) {
		return c.ownedTarget(ctx, tx, d, &found)
	})
	if e != nil {
		return e
	}
	if !found {
		return ErrNotFound
	}
	return nil
}

// DeleteAuthorized allows only the exact pending root to be retried by its
// authenticated owner. A different pending root still blocks business access.
// A contact retry can pass tombstones from that exact cascade, but not a
// separately pending or tombstoned child. Session validation, source-key
// resolution, the ledger read and the SQL intent share the account lock;
// tombstone writes and cleanup run only after the intent commits. Online
// contact deletion rechecks the same barrier under the cleanup lock.
func (c *Coordinator) DeleteAuthorized(ctx context.Context, d Deletion, validate func(pgx.Tx) error) error {
	if validate == nil || d.Scope == "account" || removes[d.Scope] == "" || d.UserID == uuid.Nil || d.SourceID == uuid.Nil || d.OperationID == uuid.Nil || len(c.registry.modules) == 0 {
		return errors.New("invalid session-bound deletion")
	}
	var intent DeletionIntent
	err := pgx.BeginFunc(ctx, c.db, func(tx pgx.Tx) error {
		rr, err := roots(ctx, tx, d.UserID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if err = validate(tx); err != nil {
			return err
		}
		var found bool
		id, ok, err := c.ownedTarget(ctx, tx, d, &found)
		if err != nil {
			return err
		}
		if err := c.checkAuthorizedDeletion(ctx, rr, d, id, ok && found); err != nil {
			return err
		}
		if !ok || !found {
			return ErrNotFound
		}
		intent, err = journalRootTx(ctx, tx, d, rr, id)
		if err != nil {
			return err
		}
		if intent.rootID == uuid.Nil {
			return ErrNotFound
		}
		intent.recheckContactBarrier = d.Scope == "contacts"
		return nil
	})
	if err != nil {
		return err
	}
	return c.ExecuteDeletion(ctx, intent)
}

// checkAuthorizedDeletion evaluates the fence for account-owned roots read
// under the current transaction's account lock.
func (c *Coordinator) checkAuthorizedDeletion(ctx context.Context, rr []root, d Deletion, id uuid.UUID, owned bool) error {
	ids, cascade, err := authorizedDeletionRoots(rr, d, id, owned)
	if err != nil {
		return err
	}
	if len(cascade) != 0 {
		return c.ledger.checkCascade(ctx, ids, cascade)
	}
	blocked, err := c.ledger.blocked(ctx, ids)
	if err != nil {
		return err
	}
	if blocked {
		return ErrHidden
	}
	return nil
}

func authorizedDeletionRoots(rr []root, d Deletion, id uuid.UUID, owned bool) (ids, cascade []uuid.UUID, err error) {
	if owned && d.Scope == "contacts" {
		for _, r := range rr {
			if r.id == id && r.scope == d.Scope && r.pending {
				cascade = []uuid.UUID{id}
				break
			}
		}
	}
	ids = make([]uuid.UUID, 0, len(rr))
	for _, r := range rr {
		exact := owned && r.id == id && r.scope == d.Scope
		if r.pending && !exact {
			return nil, nil, ErrHidden
		}
		if len(cascade) != 0 && r.isChildOf(id) {
			cascade = append(cascade, r.id)
		} else if !r.pending {
			ids = append(ids, r.id)
		}
	}
	return ids, cascade, nil
}

// JournalOwnedDeletionTx performs the account-facing ownership check and writes
// durable intent in the caller-owned authority transaction. It deliberately
// does not touch Redis or execute cleanup: callers must commit this transaction
// first, then pass the returned intent to ExecuteDeletion for retryable work.
func (c *Coordinator) JournalOwnedDeletionTx(ctx context.Context, tx pgx.Tx, d Deletion) (DeletionIntent, error) {
	var found bool
	intent, e := c.prepareDeletionTx(ctx, tx, d, func(tx pgx.Tx) (uuid.UUID, bool, error) {
		return c.ownedTarget(ctx, tx, d, &found)
	})
	if e != nil {
		return DeletionIntent{}, e
	}
	if !found || intent.rootID == uuid.Nil {
		return DeletionIntent{}, ErrNotFound
	}
	return intent, nil
}

func (c *Coordinator) ownedTarget(ctx context.Context, tx pgx.Tx, d Deletion, found *bool) (uuid.UUID, bool, error) {
	switch d.Scope {
	case "sessions", "reviews", "replies":
		predicate := map[string]string{
			"sessions": "kind in ('practice','drill')",
			"reviews":  "kind='review'",
			"replies":  "kind='reply'",
		}[d.Scope]
		var source uuid.UUID
		e := tx.QueryRow(ctx, `select source_id from activities where user_id=$1 and id=$2 and `+predicate, d.UserID, d.SourceID).Scan(&source)
		if errors.Is(e, pgx.ErrNoRows) {
			return uuid.Nil, false, nil
		}
		if e != nil {
			return uuid.Nil, false, e
		}
		e = tx.QueryRow(ctx, `select exists(select from erasure_roots where user_id=$1 and scope=$2 and root_id=$3)`, d.UserID, d.Scope, source).Scan(found)
		return source, *found, e
	default:
		e := tx.QueryRow(ctx, `select exists(select from erasure_roots where user_id=$1 and scope=$2 and root_id=$3)`, d.UserID, d.Scope, d.SourceID).Scan(found)
		return d.SourceID, *found, e
	}
}

// DeleteIf rechecks a candidate under the same account lock that records the
// irreversible intent. The optional resolver runs inside that lock and returns
// the source/root ID to journal. Discovery queries may have seen a stale MVCC
// snapshot, so callers must resolve the final candidate here.
func (c *Coordinator) DeleteIf(ctx context.Context, d Deletion, eligible func(pgx.Tx) (uuid.UUID, bool, error)) error {
	var intent DeletionIntent
	e := pgx.BeginFunc(ctx, c.db, func(tx pgx.Tx) error {
		var e error
		intent, e = c.prepareDeletionTx(ctx, tx, d, eligible)
		return e
	})
	if e != nil {
		return e
	}
	if intent.rootID == uuid.Nil {
		return c.ledger.Check(ctx)
	}
	return c.ExecuteDeletion(ctx, intent)
}

func (c *Coordinator) prepareDeletionTx(ctx context.Context, tx pgx.Tx, d Deletion, eligible func(pgx.Tx) (uuid.UUID, bool, error)) (DeletionIntent, error) {
	if _, ok := removes[d.Scope]; !ok || d.UserID == uuid.Nil || d.OperationID == uuid.Nil || (d.Scope == "account") != (d.SourceID == uuid.Nil) {
		return DeletionIntent{}, errors.New("invalid deletion")
	}
	if len(c.registry.modules) == 0 {
		return DeletionIntent{}, errors.New("no active data modules")
	}
	rr, e := roots(ctx, tx, d.UserID)
	if errors.Is(e, pgx.ErrNoRows) {
		return DeletionIntent{}, nil
	}
	if e != nil {
		return DeletionIntent{}, e
	}
	sourceID := d.SourceID
	if eligible != nil {
		var ok bool
		sourceID, ok, e = eligible(tx)
		if e != nil {
			return DeletionIntent{}, e
		}
		if !ok {
			return DeletionIntent{}, nil
		}
	}
	return journalRootTx(ctx, tx, d, rr, sourceID)
}

func journalRootTx(ctx context.Context, tx pgx.Tx, d Deletion, rr []root, sourceID uuid.UUID) (DeletionIntent, error) {
	if d.Scope != "account" {
		d.SourceID = sourceID
	}
	for _, r := range rr {
		if r.scope == d.Scope && (d.Scope == "account" || r.id == sourceID) {
			_, e := tx.Exec(ctx, `insert into pending_erasure values($1) on conflict do nothing`, r.id)
			return DeletionIntent{deletion: d, rootID: r.id}, e
		}
	}
	return DeletionIntent{}, nil
}

// ExecuteDeletion performs the retryable tombstone and physical cleanup for an
// already committed intent. A failed attempt leaves pending_erasure in place.
func (c *Coordinator) ExecuteDeletion(ctx context.Context, intent DeletionIntent) error {
	if intent.rootID == uuid.Nil || intent.deletion.OperationID == uuid.Nil || intent.deletion.UserID == uuid.Nil {
		return errors.New("invalid deletion intent")
	}
	return pgx.BeginFunc(ctx, c.db, func(tx pgx.Tx) error {
		return c.finishTx(ctx, tx, intent)
	})
}

func (c *Coordinator) finishTx(ctx context.Context, tx pgx.Tx, intent DeletionIntent) error {
	d := intent.deletion
	target := intent.rootID
	rr, e := roots(ctx, tx, d.UserID)
	if errors.Is(e, pgx.ErrNoRows) {
		return nil
	}
	if e != nil {
		return e
	}
	var ids []uuid.UUID
	found := false
	for _, r := range rr {
		if r.id == target && r.pending && r.scope == d.Scope {
			found = true
		}
		if r.id == target || d.Scope == "account" || (d.Scope == "contacts" && r.isChildOf(target)) {
			ids = append(ids, r.id)
		}
	}
	if !found {
		return nil
	}
	// The journal commit released the account lock. Recheck both stores under
	// the cleanup lock, with the Redis check atomic with writing the batch.
	if intent.recheckContactBarrier {
		other, cascade, e := authorizedDeletionRoots(rr, d, target, true)
		if e != nil {
			return e
		}
		if e := c.ledger.markCascade(ctx, other, cascade); e != nil {
			return e
		}
	} else if e := c.ledger.mark(ctx, ids); e != nil {
		return e
	}
	if _, e := tx.Exec(ctx, removes[d.Scope], d.UserID, target); e != nil {
		return e
	}
	for _, m := range c.registry.modules {
		if e := m.Delete(ctx, tx, d); e != nil {
			return e
		}
	}
	_, e = tx.Exec(ctx, `delete from pending_erasure where root_id=any($1::uuid[])`, ids)
	return e
}
