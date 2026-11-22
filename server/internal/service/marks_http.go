package service

import (
	"errors"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/marks"
	"high-eq/server/internal/privacy"
)

func markReply(c *gin.Context, v any, e error) {
	switch {
	case errors.Is(e, marks.ErrConsent):
		problem(c, 400, "invalid_argument", "请先同意手动标记的用途和保留期", false)
	case errors.Is(e, marks.ErrDeleted):
		problem(c, 409, "conflict", "这次标记已删除，请重新记录", false)
	case errors.Is(e, pgx.ErrNoRows):
		problem(c, 404, "not_found", "这条标记已不存在", false)
	default:
		reply(c, v, e)
	}
}

func (a appAPI) CreateMark(c *gin.Context) {
	var in app.CreateMarkInput
	if !input(c, &in) {
		return
	}
	p := principal(c)
	ctx := c.Request.Context()
	var out app.Mark
	e := a.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var e error
		out, e = a.marks.Create(ctx, tx, p.User, in, time.Now())
		return e
	})
	markReply(c, out, e)
}

func (a appAPI) EditMark(c *gin.Context, id uuid.UUID) {
	var in *marks.Patch
	if !input(c, &in) {
		return
	}
	if in == nil {
		problem(c, 400, "invalid_argument", "需要标记字段", false)
		return
	}
	p := principal(c)
	ctx := c.Request.Context()
	var out app.Mark
	e := a.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var e error
		out, e = a.marks.Edit(ctx, tx, p.User, id, *in, time.Now())
		return e
	})
	markReply(c, out, e)
}

func (a appAPI) ListMarks(c *gin.Context, in app.ListMarksParams) {
	p := principal(c)
	ctx := c.Request.Context()
	var out app.ListMarksResult
	e := a.accounts.WithSession(ctx, p, false, func(tx pgx.Tx) error {
		var e error
		out, e = a.marks.List(ctx, tx, p.User, in, time.Now())
		return e
	})
	markReply(c, out, e)
}

func (a appAPI) DeleteMark(c *gin.Context, id uuid.UUID) {
	p := principal(c)
	ctx := c.Request.Context()
	found, e := a.marks.Data.DeleteSource(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: p.User, SourceID: id, Scope: "manual_marks"}, func(tx pgx.Tx) (bool, error) {
		if e := a.accounts.ValidateSessionTx(ctx, tx, p, false); e != nil {
			return false, e
		}
		var exists bool
		e := tx.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, p.User, id).Scan(&exists)
		return exists, e
	})
	if e == nil && !found {
		e = pgx.ErrNoRows
	}
	markReply(c, ack, e)
}
