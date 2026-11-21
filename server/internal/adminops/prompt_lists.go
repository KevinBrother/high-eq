package adminops

import (
	"encoding/base64"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/prompts"
)

// Keyset pagination over the release PK / per-task version index, never offsets.
func promptPage(limit *int, cursor *string) (int, *admin.Task, string, bool) {
	n := 20
	if limit != nil {
		n = *limit
	}
	if n < 1 || n > 100 {
		return 0, nil, "", false
	}
	if cursor == nil {
		return n, nil, "", true
	}
	if len(*cursor) > 128 {
		return 0, nil, "", false
	}
	v, e := base64.RawURLEncoding.DecodeString(*cursor)
	a, b, ok := strings.Cut(string(v), "|")
	task := admin.Task(a)
	return n, &task, b, e == nil && ok && prompts.ValidTask(task)
}
func sendPage[T any](c *gin.Context, rows pgx.Rows, n int, scan func() (T, error), key func(T) string) {
	defer rows.Close()
	items := make([]T, 0, n)
	var next *string
	for rows.Next() {
		if len(items) == n {
			s := base64.RawURLEncoding.EncodeToString([]byte(key(items[n-1])))
			next = &s
			break
		}
		v, e := scan()
		if e != nil {
			reject(c, 500)
			return
		}
		items = append(items, v)
	}
	if rows.Err() != nil {
		reject(c, 500)
		return
	}
	c.JSON(200, gin.H{"items": items, "next_cursor": next})
}
func (a api) ListPromptVersions(c *gin.Context, p admin.ListPromptVersionsParams) {
	n, task, key, ok := promptPage(p.Limit, p.Cursor)
	var ver int
	if task != nil {
		var e error
		ver, e = strconv.Atoi(key)
		ok = ok && e == nil && ver > 0 && ver <= 2147483647 && (p.Task == nil || *p.Task == *task)
	}
	if !ok || p.Task != nil && !prompts.ValidTask(*p.Task) {
		reject(c, 400)
		return
	}
	rows, e := a.db.Query(c.Request.Context(), `select id,task,version,template,created_at from prompt_versions where ($1::ai_task is null or task=$1) and ($2::ai_task is null or task>$2 or (task=$2 and version<$3)) order by task,version desc limit $4`, p.Task, task, ver, n+1)
	if e != nil {
		reject(c, 500)
		return
	}
	sendPage(c, rows, n, func() (v admin.PromptVersion, e error) {
		e = rows.Scan(&v.Id, &v.Task, &v.Version, &v.Template, &v.CreatedAt)
		return
	}, func(v admin.PromptVersion) string { return string(v.Task) + "|" + strconv.Itoa(v.Version) })
}
func (a api) ListPromptReleases(c *gin.Context, p admin.ListPromptReleasesParams) {
	n, task, key, ok := promptPage(p.Limit, p.Cursor)
	var id uuid.UUID
	if task != nil {
		var e error
		id, e = uuid.Parse(key)
		ok = ok && e == nil
	}
	if !ok {
		reject(c, 400)
		return
	}
	rows, e := a.db.Query(c.Request.Context(), `select task,model_id,primary_version_id,experiment_version_id,experiment_percent from prompt_releases where ($1::ai_task is null or (task,model_id)>($1,$2::uuid)) order by task,model_id limit $3`, task, id, n+1)
	if e != nil {
		reject(c, 500)
		return
	}
	sendPage(c, rows, n, func() (v admin.PromptRelease, e error) {
		e = rows.Scan(&v.Task, &v.ModelId, &v.PrimaryVersionId, &v.ExperimentVersionId, &v.ExperimentPercent)
		return
	}, func(v admin.PromptRelease) string { return string(v.Task) + "|" + v.ModelId.String() })
}
