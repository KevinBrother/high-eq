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
	var next snapshot
	err := pgx.BeginTxFunc(ctx, c.db, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `select version from gateway_revision where singleton`).Scan(&next.version); err != nil {
			return err
		}
		if next.version == c.version() {
			return nil
		}
		rows, err := tx.Query(ctx, `select m.id,m.endpoint,m.model_name,m.protocol,m.kind,m.api_key_enc
 from model_configs m join provider_admissions a
 on (a.ref,a.provider,a.endpoint,a.kind)=(m.active_ref,m.provider,m.endpoint,m.kind)
 where m.enabled`)
		if err != nil {
			return err
		}
		defer rows.Close()
		next.entries = make(map[uuid.UUID]entry)
		for rows.Next() {
			var id uuid.UUID
			var e entry
			if err := rows.Scan(&id, &e.endpoint, &e.model, &e.protocol, &e.kind, &e.envelope); err != nil {
				return err
			}
			next.entries[id] = e
		}
		return rows.Err()
	})
	if err != nil {
		return ErrConfig
	}
	if next.entries != nil {
		c.state.Store(&next)
	}
	return nil
}
func (c *Catalog) lookup(ctx context.Context, id uuid.UUID, kind Kind) (adapter, target, error) {
	// Redis Pub/Sub is a hint; a lost notification cannot extend approval.
	var v uuid.UUID
	if err := c.db.QueryRow(ctx, `select version from gateway_revision where singleton`).Scan(&v); err != nil {
		return nil, target{}, ErrConfig
	}
	if v != c.version() {
		if err := c.refresh(ctx); err != nil {
			return nil, target{}, err
		}
	}
	e, ok := c.state.Load().entries[id]
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
