package adminops

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
)

type api struct {
	admin.ServerInterface
	db      *pgxpool.Pool
	catalog *gateway.Catalog
	fields  *fieldcrypt.Cipher
}
type rule struct {
	action, target string
	super, live    bool
}

// Exact route templates only. New routes are closed unless explicitly reviewed.
var rules = map[string]rule{
	"GET /admissions":         {"listAdmissions", "admissions", true, true},
	"POST /admissions":        {"createAdmission", "admissions", true, true},
	"DELETE /admissions/:ref": {"revokeAdmission", "admissions", true, true},

	"POST /auth/login":      {"adminLogin", "session", false, true},
	"POST /auth/logout":     {"adminLogout", "session", false, true},
	"GET /audit-logs":       {"listAuditLogs", "audit", true, true},
	"POST /models":          {"createModel", "models", true, true},
	"PATCH /models/:id":     {"updateModel", "models", true, true},
	"POST /models/:id/test": {"testModel", "models", true, true},
	"PUT /routes/:task":     {"setRoute", "routes", true, true},
	"GET /models":           {"listModels", "models", true, true},
	"GET /routes":           {"listRoutes", "routes", true, true},
	"GET /prompt-models":    {"listPromptModels", "prompts", false, true},
	"GET /metrics":          {"getMetrics", "metrics", false, true},
	"GET /prompt-versions":  {"listPromptVersions", "prompts", false, true},
	"POST /prompt-versions": {"createPromptVersion", "prompts", false, true},
	"GET /prompt-releases":  {"listPromptReleases", "prompts", false, true},
	"PUT /prompt-releases":  {"setPromptRelease", "prompts", false, true},
}

func Register(r gin.IRouter, db *pgxpool.Pool, catalogs ...*gateway.Catalog) {
	var catalog *gateway.Catalog
	if len(catalogs) > 0 {
		catalog = catalogs[0]
	}
	RegisterDashboard(r, db, catalog, nil)
}

func RegisterDashboard(r gin.IRouter, db *pgxpool.Pool, catalog *gateway.Catalog, fields *fieldcrypt.Cipher) {
	a := api{db: db, catalog: catalog, fields: fields}
	admin.RegisterHandlersWithOptions(r.Group("", a.guard), a, admin.GinServerOptions{ErrorHandler: func(c *gin.Context, _ error, _ int) { reject(c, 400) }})
}
func reject(c *gin.Context, status int) {
	code, msg := "internal_error", "服务暂不可用，请稍后重试"
	switch status {
	case 400:
		code, msg = "invalid_argument", "请检查输入或筛选条件"
	case 401:
		code, msg = "unauthenticated", "管理员凭据无效或会话已过期"
	case 403:
		code, msg = "forbidden", "此操作需要超级管理员权限"
	case 404:
		code, msg = "not_found", "指定的配置不存在"
	case 409:
		code, msg = "conflict", "配置仍在使用或不符合准入要求"
	case 501:
		code, msg = "not_implemented", "此功能尚未开放"
	}
	c.AbortWithStatusJSON(status, gin.H{"code": code, "message": msg, "retryable": status == 500})
}

type attempt struct {
	actor identity
	audit uuid.UUID
}

const attemptKey = "adminops.attempt"

func current(c *gin.Context) *attempt { return c.MustGet(attemptKey).(*attempt) }
func (a api) guard(c *gin.Context) {
	c.Header("Cache-Control", "no-store")
	policy, ok := rules[c.Request.Method+" "+strings.TrimPrefix(c.FullPath(), "/admin/v1")]
	if !ok {
		reject(c, 403)
		return
	}
	ctx := c.Request.Context()
	att := &attempt{}
	status := 0
	if policy.action != "adminLogin" {
		var e error
		if a.db == nil {
			reject(c, 401)
			return
		}
		att.actor, e = a.identify(ctx, c.GetHeader("Authorization"))
		switch {
		case errors.Is(e, errCredentials):
			status = 401
		case e != nil:
			status = 500
		case policy.super && att.actor.role != "super_admin":
			status = 403
		}
	}
	if status == 0 && !policy.live {
		status = 501
	}
	if c.Request.Method != "GET" {
		if a.db == nil {
			reject(c, 501)
			return
		}
		target := policy.target
		if id, e := uuid.Parse(c.Param("ref")); e == nil {
			target = id.String()
		}
		if id, e := uuid.Parse(c.Param("id")); e == nil {
			target = id.String()
		}
		switch task := admin.Task(c.Param("task")); task {
		case admin.TaskRolePlay, admin.TaskReplySuggestion, admin.TaskScoring, admin.TaskProfileInference, admin.TaskReviewAnalysis, admin.TaskContentGeneration, admin.TaskClassification:
			target = string(task)
		}
		result := "failed"
		if status == 401 || status == 403 {
			result = "denied"
		}
		if e := a.db.QueryRow(ctx, "insert into admin_audit_logs(actor_id,action,target,result) values ($1,$2,$3,$4) returning id", att.actor.id, policy.action, target, result).Scan(&att.audit); e != nil {
			reject(c, 500)
			return
		}
	}
	if status != 0 {
		reject(c, status)
		return
	}
	c.Set(attemptKey, att)
	c.Next()
}

// commitWrite couples the final success audit to the business mutation. Binding errors,
// rollbacks, crashes or forgotten handlers retain the conservative failed attempt.
func (a api) commitWrite(c *gin.Context, run func(context.Context, pgx.Tx) error) error {
	att := current(c)
	ctx := c.Request.Context()
	return pgx.BeginFunc(ctx, a.db, func(tx pgx.Tx) error {
		if e := run(ctx, tx); e != nil {
			return e
		}
		tag, e := tx.Exec(ctx, "update admin_audit_logs set actor_id=$1,result='ok' where id=$2 and result='failed'", att.actor.id, att.audit)
		if e == nil && tag.RowsAffected() != 1 {
			return errors.New("missing audit")
		}
		return e
	})
}
func (a api) AdminLogin(c *gin.Context) {
	var v admin.AdminLoginJSONBody
	dec := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 4096))
	dec.DisallowUnknownFields()
	if dec.Decode(&v) != nil || dec.Decode(&struct{}{}) != io.EOF || !loginName.MatchString(v.Login) || len(v.Password) == 0 || len(v.Password) > 72 {
		reject(c, 400)
		return
	}
	ctx := c.Request.Context()
	p, e := a.verify(ctx, v.Login, v.Password)
	if errors.Is(e, errCredentials) {
		_, e = a.db.Exec(ctx, "update admin_audit_logs set actor_id=$1,result='denied' where id=$2", p.id, current(c).audit)
		if e != nil {
			reject(c, 500)
		} else {
			reject(c, 401)
		}
		return
	}
	if e != nil {
		reject(c, 500)
		return
	}
	current(c).actor = p
	var s admin.AdminSession
	e = a.commitWrite(c, func(ctx context.Context, tx pgx.Tx) error { var e error; s, e = issue(ctx, tx, p); return e })
	if e != nil {
		reject(c, 500)
		return
	}
	c.JSON(200, s)
}
func (a api) AdminLogout(c *gin.Context) {
	e := a.commitWrite(c, func(ctx context.Context, tx pgx.Tx) error {
		_, e := tx.Exec(ctx, "delete from admin_sessions where token_hash=$1", current(c).actor.digest)
		return e
	})
	if e != nil {
		reject(c, 500)
		return
	}
	c.JSON(200, admin.Ack{Ok: true})
}
