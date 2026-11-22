package service

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/training"
)

func practiceError(c *gin.Context, e error) {
	switch {
	case errors.Is(e, training.ErrMissing):
		problem(c, 404, "not_found", "没有找到这场练习或关卡", false)
	case errors.Is(e, training.ErrConsent):
		problem(c, 403, "forbidden", "开始前请确认对练内容的用途和保留期限", false)
	case errors.Is(e, training.ErrCap):
		problem(c, 409, "conflict", "本场已达长度上限，请结束并查看反馈", false)
	case errors.Is(e, training.ErrGeneration):
		problem(c, 500, "internal_error", "本次未完成，请查看会话结算", false)
	default:
		rightsError(c, e)
	}
}
func practiceReply(c *gin.Context, v any, e error) {
	if e != nil {
		practiceError(c, e)
		return
	}
	if t, ok := v.(*gateway.Terminal); ok && !t.Safety {
		c.JSON(503, v)
		return
	}
	c.JSON(200, v)
}
func (a appAPI) ListLevels(c *gin.Context, p app.ListLevelsParams) {
	v, e := training.Levels(p)
	practiceReply(c, v, e)
}
func (a appAPI) CreateSession(c *gin.Context) {
	var in training.Input
	if !input(c, &in) {
		return
	}
	v, e := a.training.Create(c.Request.Context(), principal(c), in)
	practiceReply(c, v, e)
}
func (a appAPI) GetSession(c *gin.Context, id uuid.UUID) {
	v, e := a.training.Get(c.Request.Context(), principal(c), id)
	practiceReply(c, v, e)
}
func (a appAPI) ListSessions(c *gin.Context, p app.ListSessionsParams) {
	v, e := a.training.List(c.Request.Context(), principal(c), p)
	practiceReply(c, v, e)
}
func (a appAPI) ExitSession(c *gin.Context, id uuid.UUID) {
	v, e := a.training.Exit(c.Request.Context(), principal(c), id)
	practiceReply(c, v, e)
}
func (a appAPI) FinishSession(c *gin.Context, id uuid.UUID) {
	v, e := a.training.Finish(c.Request.Context(), principal(c), id)
	practiceReply(c, v, e)
}
func (a appAPI) SendMessage(c *gin.Context, id uuid.UUID) {
	var in app.SendMessageInput
	if !input(c, &in) {
		return
	}
	e := a.training.Send(c.Request.Context(), principal(c), id, in, func(f training.Frame) error {
		b, e := json.Marshal(f.Data)
		if e != nil {
			return e
		}
		if !c.Writer.Written() {
			c.Header("Content-Type", "text/event-stream; charset=utf-8")
			c.Header("Cache-Control", "no-store")
			c.Header("X-Accel-Buffering", "no")
		}
		rc := http.NewResponseController(c.Writer)
		_ = rc.SetWriteDeadline(time.Now().Add(3 * time.Second))
		defer rc.SetWriteDeadline(time.Time{})
		if _, e = fmt.Fprintf(c.Writer, "event: %s\ndata: %s\n\n", f.Name, b); e != nil {
			return e
		}
		return rc.Flush()
	})
	if e != nil && !c.Writer.Written() {
		practiceError(c, e)
	}
}
