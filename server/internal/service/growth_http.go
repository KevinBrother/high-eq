package service

import (
	"errors"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	openapi_types "github.com/oapi-codegen/runtime/types"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/membership"
)

type growthCardPage struct {
	Items      []app.GetCardResult `json:"items"`
	NextCursor *string             `json:"next_cursor"`
}

type answerExerciseBody struct {
	ChoiceIndex *int `json:"choice_index"`
}

func (a appAPI) withGrowthSession(c *gin.Context, allowFrozen bool, fn func(pgx.Tx) error) error {
	if a.accounts == nil {
		return growth.ErrUnavailable
	}
	return a.accounts.WithSession(c.Request.Context(), principal(c), allowFrozen, fn)
}

func (a appAPI) GetTodayPlan(c *gin.Context) {
	if a.plans == nil {
		growthReply(c, nil, growth.ErrUnavailable)
		return
	}
	var out app.GetTodayPlanResult
	err := a.withGrowthSession(c, false, func(tx pgx.Tx) error {
		plan, err := a.plans.Today(c.Request.Context(), tx, principal(c).User)
		if err != nil {
			return err
		}
		out, err = todayPlanResponse(plan)
		return err
	})
	growthReply(c, out, err)
}

func (a appAPI) CompletePlanItem(c *gin.Context, id openapi_types.UUID) {
	if a.plans == nil {
		growthReply(c, nil, growth.ErrUnavailable)
		return
	}
	var progress growth.PlanProgress
	err := a.withGrowthSession(c, false, func(tx pgx.Tx) error {
		var err error
		progress, err = a.plans.CompleteItem(c.Request.Context(), tx, principal(c).User, uuid.UUID(id))
		return err
	})
	growthReply(c, planProgressResponse(progress), err)
}

func (a appAPI) GetExercise(c *gin.Context, id openapi_types.UUID) {
	if a.plans == nil {
		growthReply(c, nil, growth.ErrUnavailable)
		return
	}
	var exercise growth.Exercise
	err := a.withGrowthSession(c, false, func(pgx.Tx) error {
		var err error
		exercise, err = a.plans.GetExercise(uuid.UUID(id))
		return err
	})
	growthReply(c, exerciseResponse(exercise), err)
}

func (a appAPI) AnswerExercise(c *gin.Context, id openapi_types.UUID) {
	if a.plans == nil {
		growthReply(c, nil, growth.ErrUnavailable)
		return
	}
	choice, ok := decodeAnswerExercise(c)
	if !ok {
		return
	}
	var (
		correct     bool
		explanation string
	)
	err := a.withGrowthSession(c, false, func(pgx.Tx) error {
		var err error
		correct, explanation, err = a.plans.AnswerExercise(uuid.UUID(id), choice)
		return err
	})
	growthReply(c, app.AnswerExerciseResult{Correct: correct, Explanation: explanation}, err)
}

func decodeAnswerExercise(c *gin.Context) (int, bool) {
	var in answerExerciseBody
	if !input(c, &in) {
		return 0, false
	}
	if in.ChoiceIndex == nil {
		growthReply(c, nil, growth.ErrInvalid)
		return 0, false
	}
	return *in.ChoiceIndex, true
}

func (a appAPI) GetCard(c *gin.Context, id openapi_types.UUID) {
	if a.plans == nil {
		growthReply(c, nil, growth.ErrUnavailable)
		return
	}
	var card growth.Card
	err := a.withGrowthSession(c, false, func(pgx.Tx) error {
		var err error
		card, err = a.plans.GetCard(uuid.UUID(id))
		return err
	})
	growthReply(c, cardResponse(card), err)
}

func (a appAPI) ListCards(c *gin.Context, p app.ListCardsParams) {
	if a.plans == nil {
		growthReply(c, nil, growth.ErrUnavailable)
		return
	}
	limit, err := growthCardsLimit(p)
	if err != nil {
		growthReply(c, nil, err)
		return
	}
	scene, cursor := "", ""
	if p.Scene != nil {
		scene = string(*p.Scene)
	}
	if p.Cursor != nil {
		cursor = *p.Cursor
	}
	var page growth.CardPage
	err = a.withGrowthSession(c, false, func(pgx.Tx) error {
		var err error
		page, err = a.plans.ListCards(scene, cursor, limit)
		return err
	})
	growthReply(c, cardPageResponse(page), err)
}

func (a appAPI) GetGrowth(c *gin.Context) {
	if a.plans == nil {
		growthReply(c, nil, growth.ErrUnavailable)
		return
	}
	var summary growth.GrowthSummary
	err := a.withGrowthSession(c, false, func(tx pgx.Tx) error {
		var err error
		summary, err = a.plans.Growth(c.Request.Context(), tx, principal(c).User)
		return err
	})
	growthReply(c, growthResponse(summary), err)
}

func growthCardsLimit(p app.ListCardsParams) (int, error) {
	limit := 20
	if p.Limit != nil {
		limit = *p.Limit
	}
	if limit < 1 || limit > 100 {
		return 0, growth.ErrInvalid
	}
	return limit, nil
}

func todayPlanResponse(plan growth.Plan) (app.GetTodayPlanResult, error) {
	day, err := time.Parse(time.DateOnly, plan.Day)
	if err != nil {
		return app.GetTodayPlanResult{}, growth.ErrInvalid
	}
	out := app.GetTodayPlanResult{
		Day:          openapi_types.Date{Time: day},
		Personalized: plan.Personalized,
		Items:        make([]app.PlanItem, 0, len(plan.Items)),
	}
	for _, item := range plan.Items {
		out.Items = append(out.Items, app.PlanItem{
			Id:        item.ID,
			Kind:      app.PlanItemKind(item.Kind),
			Title:     item.Title,
			ContentId: item.ContentID,
			Completed: item.Completed,
		})
	}
	return out, nil
}

func exerciseResponse(exercise growth.Exercise) app.GetExerciseResult {
	return app.GetExerciseResult{
		Id:       exercise.ID,
		Question: exercise.Question,
		Choices:  append([]string(nil), exercise.Choices...),
	}
}

func cardResponse(card growth.Card) app.GetCardResult {
	return app.GetCardResult{
		Id:    card.ID,
		Scene: app.GetCardResultScene(card.Scene),
		Title: card.Title,
		Body:  card.Body,
	}
}

func cardPageResponse(page growth.CardPage) growthCardPage {
	out := growthCardPage{Items: make([]app.GetCardResult, 0, len(page.Items)), NextCursor: page.NextCursor}
	for _, card := range page.Items {
		out.Items = append(out.Items, cardResponse(card))
	}
	return out
}

func growthResponse(summary growth.GrowthSummary) app.GetGrowthResult {
	return app.GetGrowthResult{
		LatestAssessment:   summary.LatestAssessment,
		WleisPercent:       float32Pointer(summary.WLEISPercent),
		TrainingReference:  float32Pointer(summary.TrainingReference),
		ValidBehaviorCount: summary.ValidBehaviorCount,
		Streak:             summary.Streak,
		Achievements:       achievementList(summary.Achievements),
	}
}

func planProgressResponse(progress growth.PlanProgress) app.CompletePlanItemResult {
	return app.CompletePlanItemResult{
		Streak:       progress.Streak,
		Achievements: achievementList(progress.Achievements),
	}
}

func achievementList(values []int) []int {
	return append([]int{}, values...)
}

func float32Pointer(v *float64) *float32 {
	if v == nil {
		return nil
	}
	out := float32(*v)
	return &out
}

func growthReply(c *gin.Context, v any, err error) {
	if err != nil {
		growthError(c, err)
		return
	}
	c.JSON(200, v)
}

func growthError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, growth.ErrInvalid):
		problem(c, 400, "invalid_argument", "请求参数无效", false)
	case errors.Is(err, growth.ErrNotFound), errors.Is(err, pgx.ErrNoRows):
		problem(c, 404, "not_found", "未找到此内容", false)
	case errors.Is(err, membership.ErrForbidden):
		problem(c, 403, "forbidden", "当前权益不支持此功能", false)
	case errors.Is(err, membership.ErrLimit):
		problem(c, 429, "quota_exceeded", "今日该功能的次数已用完，请在重置后再试", true)
	case errors.Is(err, membership.ErrConflict):
		problem(c, 409, "conflict", "操作状态已改变，请刷新后再试", false)
	case errors.Is(err, growth.ErrUnavailable):
		problem(c, 503, "unavailable", "成长服务暂未就绪，可稍后重试", true)
	default:
		accountError(c, err)
	}
}
