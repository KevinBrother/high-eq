package privacy

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

var ErrUnavailable = errors.New("deletion ledger unavailable or unsafe")

const sealKey = "ledger:identity"

type Ledger struct {
	r   *redis.Client
	id  string
	ttl time.Duration
}

// BindLedger is only allowed to initialize an empty, unbound installation.
// Losing the identity on an existing installation never initializes a new ledger.
func BindLedger(ctx context.Context, p *pgxpool.Pool, r *redis.Client, days int) (*Ledger, error) {
	if days < 1 || days > 36500 {
		return nil, errors.New("invalid backup retention")
	}
	l := &Ledger{r: r, ttl: time.Duration(max(days, 30)) * 24 * time.Hour}
	e := pgx.BeginFunc(ctx, p, func(tx pgx.Tx) error {
		if _, e := tx.Exec(ctx, `lock table ledger_binding in exclusive mode`); e != nil {
			return e
		}
		e := tx.QueryRow(ctx, `select ledger_id from ledger_binding`).Scan(&l.id)
		if errors.Is(e, pgx.ErrNoRows) {
			var populated bool
			if e := tx.QueryRow(ctx, `select exists(select 1 from users) or exists(select 1 from pending_erasure)`).Scan(&populated); e != nil {
				return e
			}
			if populated {
				return ErrUnavailable
			}
			if e := l.settings(ctx); e != nil {
				return e
			}
			l.id = uuid.NewString()
			n, e := r.Eval(ctx, `if redis.call('dbsize')~=0 then return 0 end redis.call('set',KEYS[1],ARGV[1]);return 1`, []string{sealKey}, l.seal()).Int()
			if e != nil || n != 1 {
				return ErrUnavailable
			}
			_, e = tx.Exec(ctx, `insert into ledger_binding values(true,$1)`, l.id)
			if e != nil {
				return e
			}
		} else if e != nil {
			return e
		}
		return l.Check(ctx)
	})
	return l, e
}
func (l *Ledger) settings(ctx context.Context) error {
	cmd := redis.NewMapStringStringCmd(ctx, "CONFIG", "GET", "appendonly", "appendfsync", "maxmemory-policy", "no-appendfsync-on-rewrite", "aof-load-truncated")
	if e := l.r.Process(ctx, cmd); e != nil {
		return ErrUnavailable
	}
	m, e := cmd.Result()
	if e != nil || m["appendonly"] != "yes" || m["appendfsync"] != "always" || m["maxmemory-policy"] != "noeviction" || m["no-appendfsync-on-rewrite"] != "no" || m["aof-load-truncated"] != "no" {
		return ErrUnavailable
	}
	return nil
}
func (l *Ledger) Check(ctx context.Context) error {
	if e := l.settings(ctx); e != nil {
		return e
	}
	v, e := l.r.Get(ctx, sealKey).Result()
	if e != nil || v != l.seal() {
		return ErrUnavailable
	}
	return nil
}

// Validate identity inside the same command that reads or writes the opaque keys.
const guard = `if redis.call('get',KEYS[1])~=ARGV[1] then return redis.error_reply('ledger identity mismatch') end `

func (l *Ledger) keys(ids []uuid.UUID) []string {
	ks := []string{sealKey}
	for _, id := range ids {
		ks = append(ks, "deleted:"+id.String())
	}
	return ks
}

func (l *Ledger) blocked(ctx context.Context, ids []uuid.UUID) (bool, error) {
	if e := l.settings(ctx); e != nil {
		return false, e
	}
	n, e := l.r.Eval(ctx, guard+`
		for i=2,#KEYS do
			if redis.call('exists',KEYS[i])==1 then return 1 end
		end
		return 0`, l.keys(ids), l.seal()).Int()
	return n == 1, e
}

//go:embed ledger_write.lua
var ledgerWrite string

func (l *Ledger) checkCascade(ctx context.Context, other, cascade []uuid.UUID) error {
	if e := l.settings(ctx); e != nil {
		return e
	}
	keys := append(l.keys(other), l.keys(cascade)[1:]...)
	n, e := l.r.Eval(ctx, ledgerWrite, keys, l.seal(), 0, len(other)+2).Int()
	return checkedCascade(n, e)
}

func checkedCascade(n int, err error) error {
	if err != nil {
		return err
	}
	if n != 1 {
		return ErrHidden
	}
	return nil
}

func (l *Ledger) mark(ctx context.Context, ids []uuid.UUID) error {
	return l.write(ctx, l.keys(ids), 0, 0)
}

func (l *Ledger) markWindow(ctx context.Context, root, replay uuid.UUID, uploadUntil time.Time) error {
	return l.write(ctx, l.keys([]uuid.UUID{root, replay}), 0, uploadUntil.UnixMilli())
}

// cascade starts with the contact root, followed by its currently locked children.
func (l *Ledger) markCascade(ctx context.Context, other, cascade []uuid.UUID) error {
	keys := append(l.keys(other), l.keys(cascade)[1:]...)
	return l.write(ctx, keys, len(other)+2, 0)
}

func (l *Ledger) write(ctx context.Context, keys []string, parent int, keepUntil int64) error {
	if e := l.settings(ctx); e != nil {
		return e
	}
	conn := l.r.Conn()
	defer conn.Close()
	num, e := conn.Eval(ctx, ledgerWrite, keys, l.seal(), l.ttl.Milliseconds(), parent, keepUntil).Int()
	if e := checkedCascade(num, e); e != nil {
		return e
	}
	cmd := redis.NewCmd(ctx, "WAITAOF", 1, 0, 3000)
	if e := conn.Process(ctx, cmd); e != nil {
		return e
	}
	n, e := cmd.Int64Slice()
	if e != nil || len(n) != 2 || n[0] != 1 {
		return fmt.Errorf("%w: durability not acknowledged", ErrUnavailable)
	}
	return nil
}

// A changed retention policy must be provisioned offline, after covering the
// existing ledger. Never silently authorize longer-lived snapshots on restart.
func (l *Ledger) seal() string { return fmt.Sprintf("%s:%d", l.id, int(l.ttl/(24*time.Hour))) }
func (l *Ledger) lookup(ctx context.Context, ids []uuid.UUID) ([]int64, error) {
	if e := l.settings(ctx); e != nil {
		return nil, e
	}
	return l.r.Eval(ctx, guard+`local hits={} for i=2,#KEYS do hits[i-1]=redis.call('exists',KEYS[i]) end return hits`, l.keys(ids), l.seal()).Int64Slice()
}
