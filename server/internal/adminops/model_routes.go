package adminops

import (
	"context"
	"github.com/gin-gonic/gin"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/gateway"
)

func (a api) ListRoutes(c *gin.Context, p admin.ListRoutesParams) {
	a.listConfig(c, `select task::text,primary_model,fallback_model,canary_model,canary_percent,moderation_model from model_routes`, "task", p.Cursor, p.Limit)
}
func (a api) SetRoute(c *gin.Context, task admin.Task) {
	switch task {
	case admin.TaskRolePlay, admin.TaskReplySuggestion, admin.TaskScoring, admin.TaskProfileInference, admin.TaskReviewAnalysis, admin.TaskContentGeneration, admin.TaskClassification:
	default:
		reject(c, 400)
		return
	}
	const fields = "primary_model fallback_model canary_model canary_percent moderation_model"
	var v admin.SetRouteJSONBody
	if !decodeObject(c, &v, fields, fields, "canary_model") {
		return
	}
	if v.CanaryPercent < 0 || v.CanaryPercent > 100 || v.CanaryPercent > 0 && v.CanaryModel == nil {
		reject(c, 400)
		return
	}
	a.manage(c, true, func(ctx context.Context, tx pgx.Tx) (any, error) {
		if e := gateway.ValidateRouteTx(ctx, tx, v.PrimaryModel, v.FallbackModel, v.ModerationModel, v.CanaryModel); e != nil {
			return nil, e
		}
		_, e := tx.Exec(ctx, `insert into model_routes(task,primary_model,fallback_model,canary_model,canary_percent,moderation_model) values($1,$2,$3,$4,$5,$6) on conflict(task) do update set primary_model=excluded.primary_model,fallback_model=excluded.fallback_model,canary_model=excluded.canary_model,canary_percent=excluded.canary_percent,moderation_model=excluded.moderation_model`, task, v.PrimaryModel, v.FallbackModel, v.CanaryModel, v.CanaryPercent, v.ModerationModel)
		return admin.Route{Task: task, PrimaryModel: v.PrimaryModel, FallbackModel: v.FallbackModel, CanaryModel: v.CanaryModel, CanaryPercent: v.CanaryPercent, ModerationModel: &v.ModerationModel}, e
	})
}
