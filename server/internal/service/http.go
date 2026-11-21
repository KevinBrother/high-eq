package service

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/app"
)

func problem(c *gin.Context, status int, code, msg string, retry bool) {
	c.AbortWithStatusJSON(status, gin.H{"code": code, "message": msg, "retryable": retry})
}

// The operation gate keeps unimplemented generated methods unreachable.
type appAPI struct {
	app.ServerInterface
	health   func(context.Context) error
	accounts *accounts.Service
}

func (a appAPI) CheckHealth(c *gin.Context) {
	ctx, cancel := context.WithTimeout(c.Request.Context(), 3*time.Second)
	defer cancel()
	if e := a.health(ctx); e != nil {
		problem(c, 500, "internal_error", "服务暂不可用，可重试", true)
		return
	}
	c.JSON(200, app.Ack{Ok: true})
}

// Only list implemented methods. GET and DELETE intentionally have different
// frozen-account permissions from PATCH and POST on the same paths.
var accountRoutes = map[string]bool{
	"POST /v1/auth/sms": false, "POST /v1/auth/login": false, "POST /v1/auth/refresh": false,
	"POST /v1/auth/logout": true, "POST /v1/auth/switch": false, "GET /v1/me": true, "PATCH /v1/me": false,
	"POST /v1/me/bindings": false, "POST /v1/me/closure": false, "DELETE /v1/me/closure": true,
	"GET /v1/me/consents": false, "PUT /v1/me/consents/:purpose": false,
}

func gate(auth *accounts.Service) func(*gin.Context) {
	return func(c *gin.Context) {
		_, user := c.Get(app.BearerScopes)
		allowFrozen, implemented := accountRoutes[c.Request.Method+" "+c.FullPath()]
		if user && auth == nil {
			accountError(c, accounts.ErrAuth)
			return
		}
		if user {
			token, ok := strings.CutPrefix(c.GetHeader("Authorization"), "Bearer ")
			if !ok {
				accountError(c, accounts.ErrAuth)
				return
			}
			p, e := auth.Parse(token)
			if e == nil {
				e = auth.WithSession(c.Request.Context(), p, allowFrozen, nil)
			}
			if e != nil {
				accountError(c, e)
				return
			}
			c.Set("principal", p)
		}
		if c.FullPath() != "/v1/health" && (!implemented || auth == nil) {
			problem(c, 501, "not_implemented", "此功能尚未开放", false)
		}
	}
}
func newRouter(health func(context.Context) error, auth *accounts.Service, adminDB *pgxpool.Pool) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(func(c *gin.Context) {
		start := time.Now()
		id := uuid.NewString()
		c.Header("X-Request-ID", id)
		defer func() {
			if recover() != nil {
				problem(c, 500, "internal_error", "服务暂不可用，可重试", true)
			}
			slog.Info("request", "module", "http", "request_id", id, "result", c.Writer.Status(), "latency_ms", time.Since(start).Milliseconds())
		}()
		c.Next()
	})
	invalid := func(c *gin.Context, _ error, _ int) { problem(c, 400, "invalid_argument", "请求参数无效", false) }
	app.RegisterHandlersWithOptions(r, appAPI{health: health, accounts: auth}, app.GinServerOptions{Middlewares: []app.MiddlewareFunc{gate(auth)}, ErrorHandler: invalid})
	adminops.Register(r, adminDB)
	r.NoRoute(func(c *gin.Context) { problem(c, 404, "not_found", "未找到此接口", false) })
	return r
}
