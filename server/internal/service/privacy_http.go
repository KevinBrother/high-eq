package service

import (
	"archive/zip"
	"errors"
	"io"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/privacy"
)

func (a appAPI) ExportData(c *gin.Context) {
	if a.data == nil {
		problem(c, 500, "internal_error", "服务暂不可用，可重试", true)
		return
	}
	if a.accounts == nil {
		accountError(c, accounts.ErrAuth)
		return
	}
	p := principal(c)
	c.Header("Content-Type", "application/zip")
	c.Header("Content-Disposition", `attachment; filename="high-eq-export.zip"`)
	a.streamExport(c, func(z *zip.Writer) error {
		return a.accounts.WithSession(c.Request.Context(), p, false, func(tx pgx.Tx) error {
			return a.data.ExportTx(c.Request.Context(), tx, privacy.ExportRequest{
				OperationID: uuid.New(),
				UserID:      p.User,
			}, z)
		})
	})
}

func (a appAPI) streamExport(c *gin.Context, produce func(*zip.Writer) error) {
	e := withStreamingExport(c.Writer, produce)
	if e == nil {
		return
	}
	// Once any archive byte is written, the status and headers are committed.
	// ErrAbortHandler makes net/http close an HTTP/1.1 chunked response without
	// its terminating chunk, or reset an HTTP/2 stream, so clients cannot treat
	// the failed export as a successfully completed body.
	if c.Writer.Written() {
		panic(http.ErrAbortHandler)
	}
	c.Header("Content-Type", "application/json; charset=utf-8")
	c.Header("Content-Disposition", "")
	if accounts.IsAuth(e) || errors.Is(e, privacy.ErrHidden) {
		accountError(c, e)
		return
	}
	problem(c, http.StatusInternalServerError, "internal_error", "服务暂不可用，可重试", true)
}

// withStreamingExport treats produce as the authority transaction: module data
// is written directly to dst, and the ZIP central directory is emitted only
// after the transaction has committed successfully.
func withStreamingExport(dst io.Writer, produce func(*zip.Writer) error) error {
	if produce == nil {
		return errors.New("missing export producer")
	}
	z := zip.NewWriter(dst)
	if err := produce(z); err != nil {
		return err
	}
	return z.Close()
}
