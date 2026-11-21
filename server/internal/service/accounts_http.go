package service

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/gin-gonic/gin"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/privacy"
)

func accountError(c *gin.Context, e error) {
	switch {
	case accounts.IsAuth(e), errors.Is(e, privacy.ErrHidden):
		problem(c, 401, "unauthenticated", "验证已失效，请重新登录", false)
	case errors.Is(e, accounts.ErrInvalid):
		problem(c, 400, "invalid_argument", "请检查填写内容及授权版本", false)
	case errors.Is(e, accounts.ErrQuota):
		problem(c, 429, "quota_exceeded", "验证码请求过于频繁，请稍后再试", true)
	case errors.Is(e, accounts.ErrConflict):
		problem(c, 409, "conflict", "登录方式已绑定。可保留当前账号，或重新验证后切换；不会合并数据。", false)
	default:
		problem(c, 500, "internal_error", "服务暂不可用，可重试", true)
	}
}
func reply(c *gin.Context, v any, e error) {
	if e != nil {
		accountError(c, e)
		return
	}
	c.JSON(200, v)
}
func input(c *gin.Context, v any) bool {
	d := json.NewDecoder(http.MaxBytesReader(c.Writer, c.Request.Body, 32<<10))
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil || d.Decode(new(any)) != io.EOF {
		accountError(c, accounts.ErrInvalid)
		return false
	}
	return true
}
func principal(c *gin.Context) accounts.Principal { return c.MustGet("principal").(accounts.Principal) }

var ack = app.Ack{Ok: true}

func (a appAPI) RequestCode(c *gin.Context) {
	var in app.RequestCodeInput
	if !input(c, &in) {
		return
	}
	reply(c, ack, a.accounts.RequestCode(c.Request.Context(), in.Phone))
}
func (a appAPI) Login(c *gin.Context) {
	var in app.LoginInput
	if !input(c, &in) {
		return
	}
	v, e := a.accounts.Login(c.Request.Context(), in, false)
	reply(c, v, e)
}
func (a appAPI) SwitchIdentity(c *gin.Context) {
	var in app.SwitchIdentityInput
	if !input(c, &in) {
		return
	}
	v, e := a.accounts.Login(c.Request.Context(), app.LoginInput{Credential: in.Credential}, true)
	reply(c, v, e)
}
func (a appAPI) RefreshTokens(c *gin.Context) {
	var in app.RefreshTokensInput
	if !input(c, &in) {
		return
	}
	v, e := a.accounts.Refresh(c.Request.Context(), in.RefreshToken)
	reply(c, v, e)
}
func (a appAPI) Logout(c *gin.Context) {
	var in app.LogoutInput
	if !input(c, &in) {
		return
	}
	reply(c, ack, a.accounts.Logout(c.Request.Context(), principal(c), in.RefreshToken))
}
func (a appAPI) GetMe(c *gin.Context) {
	v, e := a.accounts.Me(c.Request.Context(), principal(c), nil)
	reply(c, v, e)
}
func (a appAPI) UpdateMe(c *gin.Context) {
	var in app.UpdateMeInput
	if !input(c, &in) {
		return
	}
	v, e := a.accounts.Me(c.Request.Context(), principal(c), &in.Timezone)
	reply(c, v, e)
}
func (a appAPI) BindIdentity(c *gin.Context) {
	var in app.BindIdentityInput
	if !input(c, &in) {
		return
	}
	v, e := a.accounts.Bind(c.Request.Context(), principal(c), in.CurrentProof, in.Credential)
	reply(c, v, e)
}
func (a appAPI) FreezeAccount(c *gin.Context) {
	var in app.FreezeAccountInput
	if !input(c, &in) {
		return
	}
	v, e := a.accounts.Freeze(c.Request.Context(), principal(c), in.Proof)
	reply(c, v, e)
}
func (a appAPI) CancelClosure(c *gin.Context) {
	reply(c, ack, a.accounts.CancelClosure(c.Request.Context(), principal(c)))
}
func (a appAPI) ListConsents(c *gin.Context, p app.ListConsentsParams) {
	v, e := a.accounts.ListConsents(c.Request.Context(), principal(c), p)
	reply(c, v, e)
}
func (a appAPI) SetConsent(c *gin.Context, p app.SetConsentParamsPurpose) {
	var in struct {
		Version string `json:"version"`
		Granted *bool  `json:"granted"`
	}
	if !input(c, &in) {
		return
	}
	if in.Granted == nil {
		accountError(c, accounts.ErrInvalid)
		return
	}
	v, e := a.accounts.Consent(c.Request.Context(), principal(c), string(p), in.Version, *in.Granted)
	reply(c, v, e)
}
