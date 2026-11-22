package service

import (
	"errors"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/reviews"
	"high-eq/server/internal/scoring"
)

func reviewError(c *gin.Context, e error) {
	switch {
	case errors.Is(e, reviews.ErrConsent):
		problem(c, 403, "forbidden", "请先确认复盘及所选关系人信息的用途和保留时间", false)
	case errors.Is(e, reviews.ErrModeration):
		problem(c, 503, "moderation_unavailable", gateway.UnavailableMessage, true)
	case errors.Is(e, pgx.ErrNoRows):
		problem(c, 404, "not_found", "未找到这次复盘", false)
	case errors.Is(e, reviews.ErrDeleted):
		problem(c, 409, "conflict", "这次复盘已删除，原请求编号不可再次使用", false)
	case errors.Is(e, reviews.ErrDifferentInput):
		problem(c, 409, "conflict", "这个请求编号已用于不同内容，修改后请重新提交", false)
	case errors.Is(e, reviews.ErrRecoveryExpired):
		problem(c, 409, "conflict", "审核恢复窗口已过期，请使用新的请求编号重新提交", false)
	case errors.Is(e, reviews.ErrGeneration), errors.Is(e, scoring.ErrSchema), errors.Is(e, gateway.ErrProvider):
		problem(c, 500, "internal_error", "本次未生成完整复盘，未扣次。可重新发起复盘", false)
	default:
		rightsError(c, e)
	}
}
func (a appAPI) CreateReview(c *gin.Context) {
	var in app.ReviewInput
	if !input(c, &in) {
		return
	}
	v, e := a.reviews.Create(c.Request.Context(), principal(c), in)
	if e != nil {
		reviewError(c, e)
		return
	}
	c.JSON(v.Status, v.Body)
}
func (a appAPI) GetReview(c *gin.Context, id uuid.UUID) {
	var v app.Review
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		var e error
		v, e = a.reviews.Get(c.Request.Context(), tx, principal(c).User, id)
		return e
	})
	if e != nil {
		reviewError(c, e)
		return
	}
	c.JSON(200, v)
}
func (a appAPI) ListReviews(c *gin.Context, p app.ListReviewsParams) {
	var v app.ListReviewsResult
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		var e error
		v, e = a.reviews.List(c.Request.Context(), tx, principal(c).User, p)
		return e
	})
	if e != nil {
		reviewError(c, e)
		return
	}
	c.JSON(200, v)
}
func (a appAPI) DeleteReview(c *gin.Context, id uuid.UUID) {
	ctx := c.Request.Context()
	u := principal(c).User
	var source uuid.UUID
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `select source_id from activities where kind='review' and id=$1 and user_id=$2`, id, u).Scan(&source)
	})
	if e == nil {
		e = a.reviews.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: u, SourceID: source, Scope: "reviews"})
	}
	if e != nil {
		reviewError(c, e)
		return
	}
	c.JSON(200, ack)
}
