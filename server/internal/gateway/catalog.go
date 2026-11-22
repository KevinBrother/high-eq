package gateway

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/fieldcrypt"
)

const changeChannel = "gateway:config:changed"

type entry struct {
	endpoint, model, protocol string
	kind                      Kind
	envelope                  []byte
}
type snapshot struct {
	version uuid.UUID
	entries map[uuid.UUID]entry
}
type Catalog struct {
	db        *pgxpool.Pool
	cache     *redis.Client
	fields    *fieldcrypt.Cipher
	adapters  map[string]adapter
	state     atomic.Pointer[snapshot]
	refreshMu sync.Mutex
	sub       *redis.PubSub
	cancel    context.CancelFunc
	done      chan struct{}
}

// Start subscribes before loading. Its startup context may be released on return.
// Close the catalog before closing its pool/client.
func Start(ctx context.Context, db *pgxpool.Pool, cache *redis.Client, fields *fieldcrypt.Cipher) (*Catalog, error) {
	if fields == nil || db == nil || cache == nil {
		return nil, ErrConfig
	}
	sub := cache.Subscribe(ctx, changeChannel)
	if _, err := sub.Receive(ctx); err != nil {
		sub.Close()
		return nil, ErrConfig
	}
	run, cancel := context.WithCancel(context.Background())
	c := &Catalog{db: db, cache: cache, fields: fields, adapters: builtinAdapters(), sub: sub, cancel: cancel, done: make(chan struct{})}
	if err := c.refresh(ctx); err != nil {
		sub.Close()
		cancel()
		return nil, err
	}
	go c.watch(run)
	return c, nil
}
func (c *Catalog) Close() { c.cancel(); c.sub.Close(); <-c.done }
func (c *Catalog) watch(ctx context.Context) {
	defer close(c.done)
	ch := c.sub.Channel()
	for {
		select {
		case <-ctx.Done():
			return
		case _, ok := <-ch:
			if !ok {
				return
			}
			attempt, cancel := context.WithTimeout(ctx, 5*time.Second)
			_ = c.refresh(attempt)
			cancel()
		}
	}
}
func (c *Catalog) version() uuid.UUID {
	if s := c.state.Load(); s != nil {
		return s.version
	}
	return uuid.Nil
}

// Publish only a coherent revision and its rows. Never cache decrypted credentials.
func (c *Catalog) refresh(ctx context.Context) error {
	c.refreshMu.Lock()
	defer c.refreshMu.Unlock()
	observed := c.state.Load()
	var next snapshot
	err := pgx.BeginTxFunc(ctx, c.db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		var version uuid.UUID
		if err := tx.QueryRow(ctx, `select version from gateway_revision where singleton`).Scan(&version); err != nil {
			return err
		}
		if observed != nil && observed.version == version {
			return nil
		}
		var err error
		next, err = loadSnapshot(ctx, tx)
		if err != nil {
			return err
		}
		if next.version != version {
			return pgx.ErrTxClosed
		}
		return nil
	})
	if err != nil {
		return ErrConfig
	}
	c.publishIfUnchanged(observed, &next)
	return nil
}

// loadSnapshot reads the revision and every enabled, admitted row in one
// statement. The caller must reuse its transaction for both the row returned
// for that revision and the subsequent provider call.
func loadSnapshot(ctx context.Context, tx pgx.Tx) (snapshot, error) {
	rows, err := tx.Query(ctx, `select v.version,
 coalesce(m.id,'00000000-0000-0000-0000-000000000000'::uuid),
 coalesce(m.endpoint,''),coalesce(m.model_name,''),coalesce(m.protocol,''),coalesce(m.kind,''),coalesce(m.api_key_enc,''::bytea)
 from gateway_revision v
 left join (
   select m.id,m.endpoint,m.model_name,m.protocol,m.kind,m.api_key_enc
   from model_configs m join provider_admissions a
   on (a.ref,a.provider,a.endpoint,a.kind)=(m.active_ref,m.provider,m.endpoint,m.kind)
   where m.enabled
 ) m on true
 where v.singleton`)
	if err != nil {
		return snapshot{}, err
	}
	defer rows.Close()
	s := snapshot{entries: make(map[uuid.UUID]entry)}
	for rows.Next() {
		var id uuid.UUID
		var e entry
		var kind string
		if err := rows.Scan(&s.version, &id, &e.endpoint, &e.model, &e.protocol, &kind, &e.envelope); err != nil {
			return snapshot{}, err
		}
		e.kind = Kind(kind)
		if id != uuid.Nil {
			s.entries[id] = e
		}
	}
	if err := rows.Err(); err != nil {
		return snapshot{}, err
	}
	if s.version == uuid.Nil {
		return snapshot{}, pgx.ErrNoRows
	}
	return s, nil
}

func (c *Catalog) publishIfUnchanged(observed *snapshot, next *snapshot) {
	if next == nil || next.entries == nil {
		return
	}
	// A slower refresh must not replace a snapshot published from a different
	// revision while it was loading. The caller can still use its local copy.
	c.state.CompareAndSwap(observed, next)
}

func (c *Catalog) lookup(ctx context.Context, id uuid.UUID, kind Kind) (adapter, target, error) {
	return c.lookupAt(ctx, nil, id, kind, uuid.Nil)
}

// lookupAt reuses the authorization transaction when supplied. It must never
// refresh through the pool in that case: the caller still holds the account
// lock on the same connection, and a strict pool may have no second connection.
func (c *Catalog) lookupAt(ctx context.Context, tx pgx.Tx, id uuid.UUID, kind Kind, revision uuid.UUID) (adapter, target, error) {
	// Redis Pub/Sub is a hint; a lost notification cannot extend approval.
	var v uuid.UUID
	var err error
	if tx != nil {
		err = tx.QueryRow(ctx, `select version from gateway_revision where singleton`).Scan(&v)
	} else {
		err = c.db.QueryRow(ctx, `select version from gateway_revision where singleton`).Scan(&v)
	}
	if err != nil {
		return nil, target{}, ErrConfig
	}
	if tx != nil && (revision == uuid.Nil || v != revision) {
		return nil, target{}, ErrConfig
	}
	if revision != uuid.Nil && v != revision {
		return nil, target{}, ErrConfig
	}
	state := c.state.Load()
	if state == nil || state.version != v {
		if tx == nil {
			if err := c.refresh(ctx); err != nil {
				return nil, target{}, err
			}
			state = c.state.Load()
		} else {
			next, err := loadSnapshot(ctx, tx)
			if err != nil || next.version != v {
				return nil, target{}, ErrConfig
			}
			c.publishIfUnchanged(state, &next)
			state = &next
		}
	}
	if state == nil || state.version != v || revision != uuid.Nil && state.version != revision {
		return nil, target{}, ErrConfig
	}
	e, ok := state.entries[id]
	a := c.adapters[e.protocol]
	if !ok || e.kind != kind || a == nil || !validEndpoint(e.endpoint) {
		return nil, target{}, ErrConfig
	}
	key, err := c.fields.Open(e.envelope, keyAAD(id))
	if err != nil || len(key) == 0 {
		return nil, target{}, ErrConfig
	}
	return a, target{e.endpoint, e.model, string(key)}, nil
}
