package service

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/recordlocator"
)

// ListDataRecords returns only public deletion locators for the authenticated
// account. It deliberately does not depend on membership, consent, or export
// content readers.
func (a appAPI) ListDataRecords(c *gin.Context, kind app.ListDataRecordsParamsKind, params app.ListDataRecordsParams) {
	if err := validateDataRecordQuery(c.Request.URL.RawQuery); err != nil {
		problem(c, http.StatusBadRequest, "invalid_argument", "请求参数无效", false)
		return
	}
	if a.accounts == nil {
		problem(c, http.StatusInternalServerError, "internal_error", "服务暂不可用，可重试", true)
		return
	}
	p := principal(c)
	var page recordlocator.Page
	err := a.accounts.WithSession(c.Request.Context(), p, false, func(tx pgx.Tx) error {
		var queryErr error
		page, queryErr = recordlocator.QueryTx(c.Request.Context(), tx, p.User, recordlocator.Request{
			Kind:   string(kind),
			Cursor: params.Cursor,
			Limit:  params.Limit,
		})
		return queryErr
	})
	if err != nil {
		if errors.Is(err, recordlocator.ErrInvalidQuery) {
			problem(c, http.StatusBadRequest, "invalid_argument", "请求参数无效", false)
			return
		}
		accountError(c, err)
		return
	}

	out, err := dataRecordPage(recordlocator.Kind(kind), page)
	if err != nil {
		problem(c, http.StatusInternalServerError, "internal_error", "服务暂不可用，可重试", true)
		return
	}
	c.JSON(http.StatusOK, out)
}
