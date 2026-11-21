package service

import (
	"errors"

	"github.com/gin-gonic/gin"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
)

func (a appAPI) GetInstrument(c *gin.Context) { c.JSON(200, a.assessments.Bank) }
func (a appAPI) SubmitAssessment(c *gin.Context) {
	var in app.SubmitAssessmentInput
	if !input(c, &in) {
		return
	}
	v, e := a.assessments.Submit(c.Request.Context(), principal(c), in.Version, in.Answers)
	assessmentReply(c, v, e)
}

func (a appAPI) ListAssessments(c *gin.Context, p app.ListAssessmentsParams) {
	limit := 20
	if p.Limit != nil {
		limit = *p.Limit
	}
	v, e := a.assessments.History(c.Request.Context(), principal(c), p.Cursor, limit)
	assessmentReply(c, v, e)
}

func assessmentReply(c *gin.Context, v any, e error) {
	var wait *assessment.TooSoon
	switch {
	case errors.Is(e, assessment.ErrConsent):
		problem(c, 403, "forbidden", "提交前请单独同意使用本次自评答卷生成雷达图和训练计划", false)
	case errors.Is(e, assessment.ErrInvalid):
		accountError(c, accounts.ErrInvalid)
	case errors.As(e, &wait):
		c.AbortWithStatusJSON(409, gin.H{"code": "conflict", "message": "尚未到复测时间", "retryable": false, "retry_at": wait.RetryAt})
	default:
		reply(c, v, e)
	}
}
