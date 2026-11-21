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

var ErrHidden = errors.New("data unavailable")

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
		return fn(tx)
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

var removes = map[string]string{
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

// DeleteIf rechecks a candidate under the same account lock that records the
// irreversible intent. Discovery queries may have seen a stale MVCC snapshot.
func (c *Coordinator) DeleteIf(ctx context.Context, d Deletion, eligible func(pgx.Tx) (bool, error)) error {
	if _, ok := removes[d.Scope]; !ok || d.UserID == uuid.Nil || d.OperationID == uuid.Nil || (d.Scope == "account") != (d.SourceID == uuid.Nil) {
		return errors.New("invalid deletion")
	}
	if len(c.registry.modules) == 0 {
		return errors.New("no active data modules")
	}
	var target uuid.UUID
	e := pgx.BeginFunc(ctx, c.db, func(tx pgx.Tx) error {
		rr, e := roots(ctx, tx, d.UserID)
		if errors.Is(e, pgx.ErrNoRows) {
			return nil
		}
		if e != nil {
			return e
		}
		if eligible != nil {
			ok, e := eligible(tx)
			if e != nil || !ok {
				return e
			}
		}
		for _, r := range rr {
			if r.scope == d.Scope && (d.Scope == "account" || r.id == d.SourceID) {
				target = r.id
				_, e := tx.Exec(ctx, `insert into pending_erasure values($1) on conflict do nothing`, target)
				return e
			}
		}
		return nil
	})
	if e != nil {
		return e
	}
	if target == uuid.Nil {
		return c.ledger.Check(ctx)
	}
	return c.finish(ctx, d, target)
}
func (c *Coordinator) finish(ctx context.Context, d Deletion, target uuid.UUID) error {
	return pgx.BeginFunc(ctx, c.db, func(tx pgx.Tx) error {
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
			if r.id == target || d.Scope == "account" || (d.Scope == "contacts" && r.childOf != nil && *r.childOf == target) {
				ids = append(ids, r.id)
			}
		}
		if !found {
			return nil
		}
		if e := c.ledger.mark(ctx, ids); e != nil {
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
	})
}
