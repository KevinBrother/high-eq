package service

import (
	"context"
	"log/slog"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
)

func problem(c *gin.Context, status int, code, msg string, retry bool) {
	c.AbortWithStatusJSON(status, gin.H{"code": code, "message": msg, "retryable": retry})
}

// Unimplemented operations are stopped by the generated operation middleware
// before dispatch. Only CheckHealth reaches this adapter in T04.
type appAPI struct {
	app.ServerInterface
	health func(context.Context) error
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
func gate(c *gin.Context) {
	_, user := c.Get(app.BearerScopes)
	_, operator := c.Get(admin.AdminBearerScopes)
	if user || operator {
		problem(c, 401, "unauthenticated", "请先登录", false)
		return
	}
	if c.FullPath() != "/v1/health" {
		problem(c, 501, "not_implemented", "此功能尚未开放", false)
	}
}
func Router(health func(context.Context) error) *gin.Engine {
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
	app.RegisterHandlersWithOptions(r, appAPI{health: health}, app.GinServerOptions{Middlewares: []app.MiddlewareFunc{gate}, ErrorHandler: invalid})
	admin.RegisterHandlersWithOptions(r, nil, admin.GinServerOptions{Middlewares: []admin.MiddlewareFunc{gate}, ErrorHandler: invalid})
	r.NoRoute(func(c *gin.Context) { problem(c, 404, "not_found", "未找到此接口", false) })
	return r
}
