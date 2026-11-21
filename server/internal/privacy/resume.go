package privacy

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Resume is a pre-traffic sweep, not a substitute for T34 verifying backup
// provenance. A pre-deletion PG snapshot can lack the SQL intent entirely.
func (c *Coordinator) Resume(ctx context.Context) error {
	if err := c.ledger.Check(ctx); err != nil {
		return err
	}
	var orphan bool
	if err := c.db.QueryRow(ctx, `select exists(select 1 from pending_erasure p where not exists(select 1 from erasure_roots r where r.root_id=p.root_id))`).Scan(&orphan); err != nil {
		return err
	}
	if orphan {
		return errors.New("unresolvable pending erasure")
	}
	type work struct {
		user, id uuid.UUID
		scope    string
		pending  bool
	}
	var after *uuid.UUID
	for {
		rows, err := c.db.Query(ctx, `select user_id,root_id,scope,p.root_id is not null from erasure_roots left join pending_erasure p using(root_id) where $1::uuid is null or root_id>$1 order by root_id limit 256`, after)
		if err != nil {
			return err
		}
		items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (work, error) {
			var w work
			err := row.Scan(&w.user, &w.id, &w.scope, &w.pending)
			return w, err
		})
		if err != nil || len(items) == 0 {
			return err
		}
		ids := make([]uuid.UUID, len(items))
		for i, w := range items {
			ids[i] = w.id
		}
		hits, err := c.ledger.lookup(ctx, ids)
		if err != nil {
			return err
		}
		if len(hits) != len(items) {
			return ErrUnavailable
		}
		for i, w := range items {
			if !w.pending && hits[i] == 0 {
				continue
			}
			d := Deletion{UserID: w.user, Scope: w.scope, OperationID: uuid.New()}
			if w.scope != "account" {
				d.SourceID = w.id
			}
			if err := c.Delete(ctx, d); err != nil {
				return err
			}
		}
		after = &ids[len(ids)-1]
	}
}
