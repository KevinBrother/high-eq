package service

import (
	"errors"
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/replies"
)

func (s *Runtime) replyService() *replies.Service {
	if s == nil {
		return nil
	}
	return s.Replies
}
func (a appAPI) CreateReply(c *gin.Context) {
	var in app.CreateReplyInput
	if !input(c, &in) {
		return
	}
	v, e := a.replies.Create(c.Request.Context(), principal(c), in)
	if errors.Is(e, replies.ErrGeneration) {
		problem(c, 500, "internal_error", "此次未生成可用建议，未扣次。可重新发起请求", false)
		return
	}
	if errors.Is(e, replies.ErrConsent) {
		problem(c, 403, "forbidden", "请先确认聊天记录的使用及保留说明", false)
		return
	}
	if errors.Is(e, replies.ErrDifferentInput) {
		problem(c, 409, "conflict", "这个请求编号已用于其他内容，请为新内容创建新的请求编号", false)
		return
	}
	if errors.Is(e, replies.ErrRequestDeleted) {
		problem(c, 409, "conflict", "这个请求编号对应的回复已删除，请为新内容创建新的请求编号", false)
		return
	}
	if errors.Is(e, replies.ErrModeration) {
		problem(c, 503, "moderation_unavailable", gateway.UnavailableMessage, true)
		return
	}
	if e != nil {
		rightsError(c, e)
		return
	}
	c.JSON(v.Status, v.Body)
}
func (a appAPI) RateReply(c *gin.Context, id uuid.UUID) {
	var in struct {
		Index      *int                          `json:"index"`
		Outcome    string                        `json:"outcome"`
		SelfReport *app.RateReplyInputSelfReport `json:"self_report"`
	}
	if !input(c, &in) {
		return
	}
	if in.Index == nil {
		accountError(c, accounts.ErrInvalid)
		return
	}
	e := a.replies.Feedback(c.Request.Context(), principal(c), id, app.RateReplyInput{Index: *in.Index, Outcome: in.Outcome, SelfReport: in.SelfReport})
	if errors.Is(e, replies.ErrMissing) {
		problem(c, 404, "not_found", "未找到这条回复", false)
		return
	}
	if e != nil {
		rightsError(c, e)
		return
	}
	c.JSON(200, ack)
}
