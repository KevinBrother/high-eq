package adminops

import (
	"encoding/base64"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"high-eq/server/internal/api/admin"
)

type entry struct {
	ID     uuid.UUID `json:"id"`
	Actor  uuid.UUID `json:"actor_id"`
	Time   time.Time `json:"occurred_at"`
	Action string    `json:"action"`
	Target string    `json:"target"`
	Result string    `json:"result"`
}

func (a api) ListAuditLogs(c *gin.Context, p admin.ListAuditLogsParams) {
	limit := 20
	if p.Limit != nil {
		limit = *p.Limit
	}
	if limit < 1 || limit > 100 || (p.From != nil && p.Until != nil && !p.From.Before(*p.Until)) {
		reject(c, 400)
		return
	}
	var before *time.Time
	var last uuid.UUID
	if p.Cursor != nil {
		if len(*p.Cursor) > 128 {
			reject(c, 400)
			return
		}
		v, e := base64.RawURLEncoding.DecodeString(*p.Cursor)
		stamp, id, ok := strings.Cut(string(v), "|")
		t, e2 := time.Parse(time.RFC3339Nano, stamp)
		var e3 error
		last, e3 = uuid.Parse(id)
		if e != nil || !ok || e2 != nil || e3 != nil {
			reject(c, 400)
			return
		}
		before = &t
	}
	rows, e := a.db.Query(c.Request.Context(), `select id,actor_id,occurred_at,action,target,result from admin_audit_logs where ($1::uuid is null or actor_id=$1) and ($2::timestamptz is null or occurred_at>=$2) and ($3::timestamptz is null or occurred_at<$3) and ($4::timestamptz is null or (occurred_at,id)<($4,$5::uuid)) order by occurred_at desc,id desc limit $6`, p.ActorId, p.From, p.Until, before, last, limit+1)
	if e != nil {
		reject(c, 500)
		return
	}
	defer rows.Close()
	items := make([]entry, 0, limit)
	var next *string
	for rows.Next() {
		var v entry
		if e := rows.Scan(&v.ID, &v.Actor, &v.Time, &v.Action, &v.Target, &v.Result); e != nil {
			reject(c, 500)
			return
		}
		if len(items) == limit {
			end := items[limit-1]
			cursor := base64.RawURLEncoding.EncodeToString([]byte(end.Time.UTC().Format(time.RFC3339Nano) + "|" + end.ID.String()))
			next = &cursor
			break
		}
		items = append(items, v)
	}
	if rows.Err() != nil {
		reject(c, 500)
		return
	}
	c.JSON(200, gin.H{"items": items, "next_cursor": next})
}
