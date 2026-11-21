package service

import (
	"errors"
	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/membership"
)

// withRights is the transaction middleware for future protected app operations.
// Authorize and perform the protected business write/read under the SAME lock.
func (a appAPI) withRights(c *gin.Context, capability membership.Capability, fn func(pgx.Tx) error) error {
	ctx := c.Request.Context()
	p := principal(c)
	return a.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		if capability != "" {
			if e := a.membership.Require(ctx, tx, p.User, capability); e != nil {
				return e
			}
		}
		return fn(tx)
	})
}
func rightsError(c *gin.Context, e error) {
	switch {
	case errors.Is(e, membership.ErrForbidden):
		problem(c, 403, "forbidden", "当前权益不支持此功能", false)
	case errors.Is(e, membership.ErrLimit):
		problem(c, 429, "quota_exceeded", "今日该功能的次数已用完，请在重置后再试", true)
	case errors.Is(e, membership.ErrConflict):
		problem(c, 409, "conflict", "操作状态已改变，请刷新后再试", false)
	default:
		accountError(c, e)
	}
}
func (a appAPI) GetEntitlements(c *gin.Context) {
	var out app.Entitlements
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		var e error
		out, e = a.membership.Entitlements(c.Request.Context(), tx, principal(c).User)
		return e
	})
	if e != nil {
		rightsError(c, e)
		return
	}
	c.JSON(200, out)
}
