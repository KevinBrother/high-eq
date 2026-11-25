package privacy

import (
	"context"
	"errors"
	"time"

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
		channel  *string
		at       *time.Time
		replay   int
	}
	var after *uuid.UUID
	for {
		rows, err := c.db.Query(ctx, `
			select r.user_id,r.root_id,r.scope,p.root_id is not null,w.channel,w.starts_at
			from erasure_roots r left join pending_erasure p on p.root_id=r.root_id
			left join signal_windows w on r.scope='signal_windows' and w.purge_id=r.root_id and w.user_id=r.user_id
			where $1::uuid is null or r.root_id>$1 order by r.root_id limit 256`, after)
		if err != nil {
			return err
		}
		items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (work, error) {
			var w work
			err := row.Scan(&w.user, &w.id, &w.scope, &w.pending, &w.channel, &w.at)
			return w, err
		})
		if err != nil || len(items) == 0 {
			return err
		}
		ids := make([]uuid.UUID, len(items), 2*len(items))
		// A snapshot can contain an older random root for the same logical
		// window. Look up its replay key alongside the physical root.
		for i := range items {
			w := &items[i]
			ids[i] = w.id
			if w.scope != "signal_windows" {
				continue
			}
			if w.channel == nil || w.at == nil {
				return ErrUnavailable
			}
			id, err := c.signalWindowReplayID(w.user, *w.channel, *w.at)
			if err != nil {
				return err
			}
			w.replay = len(ids)
			ids = append(ids, id)
		}
		hits, err := c.ledger.lookup(ctx, ids)
		if err != nil {
			return err
		}
		if len(hits) != len(ids) {
			return ErrUnavailable
		}
		for i, w := range items {
			if !w.pending && hits[i] == 0 && (w.replay == 0 || hits[w.replay] == 0) {
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
		after = &items[len(items)-1].id
	}
}

// RetryPending handles only committed SQL intents during live maintenance.
// A failed root remains pending while the rest of the pass can make progress.
// Ledger-only recovery belongs to Resume, before serving traffic.
func (c *Coordinator) RetryPending(ctx context.Context) error {
	const batchSize = 256
	type work struct {
		user, id uuid.UUID
		scope    string
	}
	var after *uuid.UUID
	var retryErr error
	for {
		rows, err := c.db.Query(ctx, `
			select r.user_id,p.root_id,r.scope
			from pending_erasure p join erasure_roots r on r.root_id=p.root_id
			where $1::uuid is null or p.root_id>$1
			order by p.root_id limit $2`, after, batchSize)
		if err != nil {
			return err
		}
		items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (work, error) {
			var w work
			err := row.Scan(&w.user, &w.id, &w.scope)
			return w, err
		})
		if err != nil {
			return err
		}
		for _, w := range items {
			if err := ctx.Err(); err != nil {
				return err
			}
			d := Deletion{UserID: w.user, Scope: w.scope, OperationID: uuid.New()}
			if w.scope != "account" {
				d.SourceID = w.id
			}
			// ExecuteDeletion revalidates ownership and the pending root under
			// the account lock. A concurrently completed intent is a no-op.
			if err := c.ExecuteDeletion(ctx, DeletionIntent{deletion: d, rootID: w.id}); err != nil && retryErr == nil {
				retryErr = err
			}
		}
		if len(items) < batchSize {
			return retryErr
		}
		after = &items[len(items)-1].id
	}
}
