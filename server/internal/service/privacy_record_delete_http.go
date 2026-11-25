package service

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/privacy"
)

func (a appAPI) DeleteSource(c *gin.Context, kind app.DeleteSourceParamsKind, id uuid.UUID) {
	if a.data == nil || a.accounts == nil {
		problem(c, http.StatusInternalServerError, "internal_error", "服务暂不可用，可重试", true)
		return
	}
	if id == uuid.Nil || !validDeleteKind(kind) {
		accountError(c, accounts.ErrInvalid)
		return
	}
	ctx := c.Request.Context()
	p := principal(c)
	err := a.data.DeleteAuthorized(ctx, privacy.Deletion{
		OperationID: uuid.New(), UserID: p.User, SourceID: id, Scope: string(kind),
	}, func(tx pgx.Tx) error {
		return a.accounts.ValidateSessionTx(ctx, tx, p, false)
	})
	if errors.Is(err, privacy.ErrNotFound) {
		problem(c, http.StatusNotFound, "not_found", "未找到这条记录", false)
		return
	}
	reply(c, ack, err)
}

func validDeleteKind(kind app.DeleteSourceParamsKind) bool {
	switch kind {
	case app.DeleteSourceParamsKindAssessments,
		app.DeleteSourceParamsKindSessions,
		app.DeleteSourceParamsKindReviews,
		app.DeleteSourceParamsKindReplies,
		app.DeleteSourceParamsKindContacts,
		app.DeleteSourceParamsKindManualMarks,
		app.DeleteSourceParamsKindSignalEvents:
		return true
	default:
		return false
	}
}
