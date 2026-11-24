package service

import (
	"context"
	"errors"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/profile"
)

func profileReply(c *gin.Context, v any, e error) {
	if errors.Is(e, pgx.ErrNoRows) || errors.Is(e, profile.ErrContactNotFound) {
		problem(c, 404, "not_found", "未找到这条记录", false)
		return
	}
	if e != nil {
		rightsError(c, e)
		return
	}
	if t, ok := v.(*gateway.Terminal); ok && !t.Safety {
		problem(c, 503, "moderation_unavailable", gateway.UnavailableMessage, true)
		return
	}
	c.JSON(200, v)
}
func (a appAPI) profileTx(c *gin.Context, fn func(context.Context, pgx.Tx, uuid.UUID) (any, error)) {
	var out any
	e := a.withRights(c, "", func(tx pgx.Tx) error { var e error; out, e = fn(c.Request.Context(), tx, principal(c).User); return e })
	profileReply(c, out, e)
}
func (a appAPI) GetContactQuestions(c *gin.Context) { c.JSON(200, gin.H{"items": profile.Questions()}) }
func (a appAPI) CreateContact(c *gin.Context) {
	var in app.CreateContactInput
	if !input(c, &in) {
		return
	}
	a.profileTx(c, func(ctx context.Context, tx pgx.Tx, u uuid.UUID) (any, error) {
		return a.profiles.Create(ctx, tx, u, in)
	})
}
func (a appAPI) ListContacts(c *gin.Context, p app.ListContactsParams) {
	a.profileTx(c, func(ctx context.Context, tx pgx.Tx, u uuid.UUID) (any, error) { return a.profiles.List(ctx, tx, u, p) })
}
func (a appAPI) EditContact(c *gin.Context, id uuid.UUID) {
	var in app.EditContactInput
	if !input(c, &in) {
		return
	}
	a.profileTx(c, func(ctx context.Context, tx pgx.Tx, u uuid.UUID) (any, error) {
		return a.profiles.Edit(ctx, tx, u, id, in)
	})
}
func (a appAPI) ChooseContact(c *gin.Context, id uuid.UUID) {
	a.profileTx(c, func(ctx context.Context, tx pgx.Tx, u uuid.UUID) (any, error) {
		return a.profiles.Choose(ctx, tx, u, id)
	})
}
func (a appAPI) GetContactSummary(c *gin.Context, id uuid.UUID) {
	var contact app.Contact
	err := a.withRights(c, "", func(tx pgx.Tx) error {
		var err error
		contact, err = a.profiles.Contact(c.Request.Context(), tx, principal(c).User, id)
		return err
	})
	if errors.Is(err, profile.ErrContactNotFound) {
		problem(c, 404, "contact_not_found", "未找到这条记录", false)
		return
	}
	profileReply(c, contact.Profile, err)
}
func (a appAPI) InferProfile(c *gin.Context, id uuid.UUID) {
	var in app.InferProfileInput
	if !input(c, &in) {
		return
	}
	p := principal(c)
	session := func(ctx context.Context, fn func(pgx.Tx) error) error {
		return a.accounts.WithSession(ctx, p, false, fn)
	}
	v, e := a.profiles.Infer(c.Request.Context(), session, a.profiles.Data.DiscardProfileInference, p.User, id, in)
	if errors.Is(e, profile.ErrInferencePending) {
		c.JSON(202, gin.H{"request_id": in.RequestId, "status": "in_progress"})
		return
	}
	profileReply(c, v, e)
}
func (a appAPI) DeleteContact(c *gin.Context, id uuid.UUID) {
	if id == uuid.Nil {
		accountError(c, accounts.ErrInvalid)
		return
	}
	ctx := c.Request.Context()
	p := principal(c)
	e := a.profiles.Data.DeleteAuthorized(ctx, privacy.Deletion{UserID: p.User, OperationID: uuid.New(), SourceID: id, Scope: "contacts"}, func(tx pgx.Tx) error {
		return a.accounts.ValidateSessionTx(ctx, tx, p, false)
	})
	if errors.Is(e, privacy.ErrNotFound) {
		e = pgx.ErrNoRows
	}
	profileReply(c, ack, e)
}
func (a appAPI) SendProfileFeedback(c *gin.Context) {
	var in app.SendProfileFeedbackInput
	if !input(c, &in) {
		return
	}
	a.profileTx(c, func(ctx context.Context, tx pgx.Tx, u uuid.UUID) (any, error) {
		return ack, a.profiles.Explicit(ctx, tx, u, in)
	})
}
func (a appAPI) GetProfile(c *gin.Context) {
	a.profileTx(c, func(ctx context.Context, tx pgx.Tx, u uuid.UUID) (any, error) {
		v, e := a.profiles.Personal(ctx, tx, u)
		return gin.H{"summary": v}, e
	})
}
func (a appAPI) EmotionSummary(c *gin.Context) {
	a.profileTx(c, func(ctx context.Context, tx pgx.Tx, u uuid.UUID) (any, error) {
		g, e := a.profiles.Groups(ctx, tx, u)
		return gin.H{"groups": g}, e
	})
}
