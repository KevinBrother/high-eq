package adminops

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"unicode/utf8"

	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/prompts"
)

// Enforce required fields including nullable experiment_version_id. In particular,
// accidentally omitting experiment_percent must not silently disable a live experiment.
func promptBody(c *gin.Context, out any, fields ...string) bool {
	rawRequest, err := io.ReadAll(http.MaxBytesReader(c.Writer, c.Request.Body, 512<<10))
	if err != nil || !utf8.Valid(rawRequest) {
		return false
	}
	var body map[string]json.RawMessage
	dec := json.NewDecoder(bytes.NewReader(rawRequest))
	if dec.Decode(&body) != nil || dec.Decode(&struct{}{}) != io.EOF || len(body) != len(fields) {
		return false
	}
	for _, key := range fields {
		v, ok := body[key]
		if !ok || key != "experiment_version_id" && bytes.Equal(v, []byte("null")) {
			return false
		}
	}
	raw, err := json.Marshal(body)
	return err == nil && json.Unmarshal(raw, out) == nil
}
func promptError(c *gin.Context, e error) {
	switch {
	case errors.Is(e, prompts.ErrVariable):
		rejectMessage(c, 400, "invalid_argument", "提示词变量不受支持，或用合法输入渲染后为空、超过 256 KiB")
	case errors.Is(e, prompts.ErrTemplate):
		rejectMessage(c, 400, "invalid_argument", "提示词模板语法无效或超过 64 KiB")
	case errors.Is(e, prompts.ErrRelease):
		reject(c, 400)
	case errors.Is(e, prompts.ErrNotFound):
		reject(c, 404)
	default:
		reject(c, 500)
	}
}
func (a api) CreatePromptVersion(c *gin.Context) {
	var v admin.CreatePromptVersionJSONBody
	if !promptBody(c, &v, "task", "template") {
		reject(c, 400)
		return
	}
	var out admin.PromptVersion
	e := a.commitWrite(c, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		out, err = prompts.Create(ctx, tx, v)
		return err
	})
	if e != nil {
		promptError(c, e)
		return
	}
	c.JSON(200, out)
}
func (a api) SetPromptRelease(c *gin.Context) {
	var v admin.PromptRelease
	if !promptBody(c, &v, "task", "model_id", "primary_version_id", "experiment_version_id", "experiment_percent") {
		reject(c, 400)
		return
	}
	e := a.commitWrite(c, func(ctx context.Context, tx pgx.Tx) error { return prompts.Publish(ctx, tx, v) })
	if e != nil {
		promptError(c, e)
		return
	}
	c.JSON(200, v)
}
