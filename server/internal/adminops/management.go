package adminops

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"high-eq/server/internal/gateway"
)

var badInput = errors.New("invalid management input")

// Exact, single JSON object: reject missing, duplicate, null (unless declared) and
// unknown keys rather than letting Go zero-values authorize a free tariff or approval.
func object(c *gin.Context, allowed, required, nullable string) (map[string]json.RawMessage, error) {
	d := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 16384))
	t, e := d.Token()
	if e != nil || t != json.Delim('{') {
		return nil, badInput
	}
	m := map[string]json.RawMessage{}
	for d.More() {
		t, e = d.Token()
		k, ok := t.(string)
		if e != nil || !ok || !slices.Contains(strings.Fields(allowed), k) || m[k] != nil {
			return nil, badInput
		}
		var v json.RawMessage
		if d.Decode(&v) != nil || string(v) == "null" && !slices.Contains(strings.Fields(nullable), k) {
			return nil, badInput
		}
		m[k] = v
	}
	if _, e = d.Token(); e != nil || len(m) == 0 || d.Decode(&struct{}{}) != io.EOF {
		return nil, badInput
	}
	for _, k := range strings.Fields(required) {
		if m[k] == nil {
			return nil, badInput
		}
	}
	return m, nil
}
func decodeObject(c *gin.Context, dst any, fields, required, nullable string) bool {
	m, e := object(c, fields, required, nullable)
	b, _ := json.Marshal(m)
	if e != nil || json.Unmarshal(b, dst) != nil {
		reject(c, 400)
		return false
	}
	return true
}

// Only configuration writes take the revision lock. A probe holds shared locks on
// its single destination, not a global lock across a network call.
func (a api) manage(c *gin.Context, notify bool, run func(context.Context, pgx.Tx) (any, error)) {
	var out any
	var businessError error
	e := a.commitWrite(c, func(ctx context.Context, tx pgx.Tx) error {
		if a.catalog == nil {
			return errors.New("catalog unavailable")
		}
		if notify {
			if _, e := tx.Exec(ctx, `select version from gateway_revision where singleton for update`); e != nil {
				return e
			}
		}
		out, businessError = run(ctx, tx)
		return businessError
	})
	if e != nil {
		status := 500
		var p *pgconn.PgError
		switch {
		case businessError == nil: // commit or success audit failed
		case errors.Is(e, badInput):
			status = 400
		case errors.Is(e, pgx.ErrNoRows):
			status = 404
		case errors.Is(e, gateway.ErrConfig):
			status = 409
		case errors.As(e, &p) && strings.HasPrefix(p.Code, "23"):
			status = 409
		case errors.As(e, &p) && strings.HasPrefix(p.Code, "22"):
			status = 400
		}
		reject(c, status)
		return
	}
	if notify {
		ctx, cancel := context.WithTimeout(c.Request.Context(), time.Second)
		_ = a.catalog.Notify(ctx)
		cancel()
	}
	c.JSON(200, out)
}
func auditObject(ctx context.Context, tx pgx.Tx, c *gin.Context, id uuid.UUID) error {
	_, e := tx.Exec(ctx, `update admin_audit_logs set target=$1 where id=$2`, id.String(), current(c).audit)
	return e
}

// Only constant projections enter this helper. Keys are unique, immutable and order
// by the same expression as the cursor predicate (including task's text ordering).
func (a api) listConfig(c *gin.Context, projection, key string, cursor *string, limit *int) {
	n := 20
	after := ""
	if limit != nil {
		n = *limit
	}
	if cursor != nil {
		after = *cursor
	}
	if n < 1 || n > 100 || len(after) > 1024 {
		reject(c, 400)
		return
	}
	rows, e := a.db.Query(c.Request.Context(), `select row_to_json(q),`+key+` from (`+projection+`) q where `+key+`>$1 order by `+key+` limit $2`, after, n+1)
	if e != nil {
		reject(c, 500)
		return
	}
	defer rows.Close()
	items := []json.RawMessage{}
	var next *string
	var last string
	for rows.Next() {
		var v json.RawMessage
		var k string
		if rows.Scan(&v, &k) != nil {
			reject(c, 500)
			return
		}
		if len(items) == n {
			next = &last
			break
		}
		items = append(items, v)
		last = k
	}
	if rows.Err() != nil {
		reject(c, 500)
		return
	}
	c.JSON(200, gin.H{"items": items, "next_cursor": next})
}
