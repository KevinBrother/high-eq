package service

import (
	"context"
	"log/slog"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/marks"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/payments"
	"high-eq/server/internal/profile"
	"high-eq/server/internal/training"
)

func problem(c *gin.Context, status int, code, msg string, retry bool) {
	c.AbortWithStatusJSON(status, gin.H{"code": code, "message": msg, "retryable": retry})
}

// The operation gate keeps unimplemented generated methods unreachable.
type appAPI struct {
	training *training.Service
	app.ServerInterface
	payments    *payments.Service
	marks       *marks.Service
	profiles    *profile.Service
	signals     *emotion.Service
	assessments *assessment.Service
	health      func(context.Context) error
	accounts    *accounts.Service
	membership  *membership.Service
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
	"GET /v1/marks": false, "POST /v1/marks": false, "PATCH /v1/marks/:id": false, "DELETE /v1/marks/:id": false,
	"GET /v1/levels": false, "GET /v1/sessions": false, "POST /v1/sessions": false, "GET /v1/sessions/:session_id": false, "POST /v1/sessions/:session_id/messages": false, "POST /v1/sessions/:session_id/exit": false, "POST /v1/sessions/:session_id/finish": false,
	"POST /v1/signal-windows": false, "DELETE /v1/signal-windows": false, "GET /v1/signal-baselines": false,
	"POST /v1/signal-events": false, "GET /v1/signal-events": false, "PATCH /v1/signal-events/:id": false,
	"GET /v1/assessments/instrument": false, "GET /v1/assessments": false, "POST /v1/assessments": false,
	"POST /v1/auth/sms": false, "POST /v1/auth/login": false, "POST /v1/auth/refresh": false,
	"POST /v1/auth/logout": true, "POST /v1/auth/switch": false, "GET /v1/me": true, "PATCH /v1/me": false,
	"POST /v1/me/bindings": false, "POST /v1/me/closure": false, "DELETE /v1/me/closure": true,
	"POST /v1/purchases/token": false, "POST /v1/purchases": false, "POST /v1/purchases/restore": false,
	"POST /v1/payment-notifications/apple": false, "POST /v1/payment-notifications/wechat": false, "POST /v1/payment-notifications/alipay": false,
	"GET /v1/contact-questions": false, "GET /v1/contacts": false, "POST /v1/contacts": false,
	"PATCH /v1/contacts/:id": false, "DELETE /v1/contacts/:id": false, "POST /v1/contacts/:id/activate": false,
	"GET /v1/contacts/:id/summary": false, "POST /v1/contacts/:id/infer": false, "POST /v1/profiles/feedback": false,
	"GET /v1/me/profile": false, "GET /v1/emotion-summary": false,
	"GET /v1/entitlements": false,
	"GET /v1/me/consents":  false, "PUT /v1/me/consents/:purpose": false,
}

// Session-bound deletes perform their own validation after taking the account
// lock. The generic preflight must not hide an exact pending deletion from its
// retry transaction.
var deferredSessionRoutes = map[string]bool{"DELETE /v1/marks/:id": true}

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
			if e == nil && !deferredSessionRoutes[c.Request.Method+" "+c.FullPath()] {
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
func newRouter(practice *training.Service, markSvc *marks.Service, pay *payments.Service, profiles *profile.Service, health func(context.Context) error, auth *accounts.Service, mountAdmin func(gin.IRouter), rights *membership.Service, surveys *assessment.Service, signals ...*emotion.Service) *gin.Engine {
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
	var signalService *emotion.Service
	if len(signals) > 0 {
		signalService = signals[0]
	}
	app.RegisterHandlersWithOptions(r, appAPI{training: practice, marks: markSvc, payments: pay, profiles: profiles, signals: signalService, health: health, accounts: auth, assessments: surveys, membership: rights}, app.GinServerOptions{Middlewares: []app.MiddlewareFunc{gate(auth)}, ErrorHandler: invalid})
	if mountAdmin != nil {
		mountAdmin(r)
	} else {
		adminops.Register(r, nil)
	}
	r.NoRoute(func(c *gin.Context) { problem(c, 404, "not_found", "未找到此接口", false) })
	return r
}
