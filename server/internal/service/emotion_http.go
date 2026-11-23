package service

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

func signalReply(c *gin.Context, v any, e error) {
	switch {
	case e == nil:
		c.JSON(200, v)
	case errors.Is(e, emotion.Invalid):
		problem(c, 400, "invalid_argument", "请检查窗口统计或事件标注", false)
	case errors.Is(e, emotion.Forbidden), errors.Is(e, membership.ErrForbidden):
		problem(c, 403, "forbidden", "需要相应会员权益和单独授权", false)
	case errors.Is(e, emotion.Conflict):
		problem(c, 409, "conflict", "记录已存在或仍在提醒冷却期", false)
	case errors.Is(e, pgx.ErrNoRows):
		problem(c, 404, "not_found", "未找到这条记录", false)
	default:
		accountError(c, e)
	}
}
func (a appAPI) UploadWindow(c *gin.Context) {
	var w emotion.Window
	if !input(c, &w) {
		return
	}
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		if e := a.membership.RequireCollectionFrom(c.Request.Context(), tx, principal(c).User, w.At); e != nil {
			return e
		}
		return a.signals.Upload(c.Request.Context(), tx, principal(c).User, w, time.Now())
	})
	signalReply(c, ack, e)
}

// Check the original precision before time.Parse can truncate a fractional second.
var alignedBaselineWindow = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:(00|30)(\.0+)?([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$`)

func parseBaselineWindow(rawQuery string, value *string) (*time.Time, error) {
	// The generated binder uses URL.Query(), which drops malformed values.
	if _, err := url.ParseQuery(rawQuery); err != nil {
		for field := range strings.SplitSeq(rawQuery, "&") {
			key, _, _ := strings.Cut(field, "=")
			if name, _ := url.QueryUnescape(key); name == "for_window" {
				return nil, emotion.Invalid
			}
		}
	}
	if value == nil {
		return nil, nil
	}
	if !alignedBaselineWindow.MatchString(*value) {
		return nil, emotion.Invalid
	}
	at, err := time.Parse(time.RFC3339, strings.ToUpper(*value))
	if err != nil || at.IsZero() {
		return nil, emotion.Invalid
	}
	utc := at.UTC()
	return &utc, nil
}

func (a appAPI) GetBaselines(c *gin.Context, p app.GetBaselinesParams) {
	window, parseErr := parseBaselineWindow(c.Request.URL.RawQuery, p.ForWindow)
	ctx, u := c.Request.Context(), principal(c).User
	var b emotion.Baselines
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		var e error
		if window == nil && parseErr == nil {
			if e = a.membership.Require(ctx, tx, u, membership.Collection); e != nil {
				return e
			}
			b, e = a.signals.Baselines(ctx, tx, u, time.Now())
			return e
		}
		now := time.Now()
		start, e := a.membership.CollectionStart(ctx, tx, u, now)
		if e != nil {
			return e
		}
		if parseErr != nil {
			return parseErr
		}
		if e = emotion.ValidateWindowTime(now, *window); e != nil {
			return e
		}
		if window.Before(start) {
			return membership.ErrForbidden
		}
		b, e = a.signals.BaselinesForWindow(ctx, tx, u, now, *window)
		return e
	})
	signalReply(c, b, e)
}
func (a appAPI) ReportSignalEvent(c *gin.Context) {
	var in app.ReportSignalEventJSONBody
	if !input(c, &in) {
		return
	}
	ctx := c.Request.Context()
	u := principal(c).User
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		if in.StartsAt.IsZero() {
			return emotion.Invalid
		}
		if e := a.membership.RequireCollectionFrom(ctx, tx, u, in.StartsAt); e != nil {
			return e
		}
		err := a.membership.Require(ctx, tx, u, membership.WatchAlert)
		if err != nil && !errors.Is(err, membership.ErrForbidden) {
			return err
		}
		return a.signals.Report(ctx, tx, u, in, time.Now(), err == nil)
	})
	signalReply(c, ack, e)
}
func (a appAPI) ListSignalEvents(c *gin.Context, p app.ListSignalEventsParams) {
	var page emotion.Page
	e := a.withRights(c, membership.Collection, func(tx pgx.Tx) error {
		var e error
		page, e = a.signals.List(c.Request.Context(), tx, principal(c).User, p, time.Now())
		return e
	})
	signalReply(c, page, e)
}
func (a appAPI) AnnotateSignalEvent(c *gin.Context, id uuid.UUID) {
	var in emotion.Annotation
	if !input(c, &in) {
		return
	}
	var v app.SignalEvent
	e := a.withRights(c, membership.Collection, func(tx pgx.Tx) error {
		var e error
		v, e = a.signals.Annotate(c.Request.Context(), tx, principal(c).User, id, in, time.Now(), a.membership.RequireContact)
		return e
	})
	signalReply(c, v, e)
}
func (a appAPI) DeleteWindow(c *gin.Context, p app.DeleteWindowParams) {
	ctx := c.Request.Context()
	u := principal(c).User
	var id uuid.UUID
	e := a.withRights(c, "", func(tx pgx.Tx) error {
		var e error
		id, e = emotion.WindowKey(ctx, tx, u, string(p.Channel), p.StartsAt)
		return e
	})
	if e == nil {
		e = a.signals.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: u, SourceID: id, Scope: "signal_windows"})
	}
	signalReply(c, ack, e)
}
