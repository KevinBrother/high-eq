//go:build integration

package service

import (
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/training"
)

const (
	officialRolePlayPrompt = "请围绕 {{scene}} 展开练习。"
	rolePlaySeedVersionID  = "19000000-1000-4000-8000-000000000001"
)

var frozenFullSessionScenes = map[app.LevelScene]string{
	"work":    "work：你是急于交付的经理，今天需要有人顶班，也可以协商优先级。",
	"partner": "partner：你是在雨中等了半小时的伴侣，希望被认真对待。",
	"family":  "family：你是担心孩子转行的家长，想听到具体打算。",
	"friends": "friends：你是面试落选的朋友，现在更想被听见，而非立刻得到建议。",
	"social":  "social：你是练琴的邻居，下班较晚但愿意听对方解释影响。",
}

type routeModels struct {
	primary, fallback, moderator uuid.UUID
}

type aiCallBreakdown struct {
	total, primary, fallback, moderator, otherModel                       int
	generatedVersioned, generatedUnversioned                              int
	moderatedVersioned, moderatedUnversioned, unexpectedVersion           int
	ok, operationMismatch, withoutOperation, distinctOperations, attempts int
}

func (h *practiceWire) route(task string) routeModels {
	h.t.Helper()
	var models routeModels
	h.must(h.s.db.QueryRow(h.ctx, `select primary_model,fallback_model,moderation_model from model_routes where task=$1::ai_task`, task).Scan(&models.primary, &models.fallback, &models.moderator))
	return models
}

func (h *practiceWire) aiCalls(activityID uuid.UUID, task string, models routeModels, version, operation uuid.UUID) aiCallBreakdown {
	h.t.Helper()
	var got aiCallBreakdown
	h.must(h.s.db.QueryRow(h.ctx, `select count(*),
 count(*) filter(where model_id=$3),
 count(*) filter(where model_id=$4),
 count(*) filter(where model_id=$5),
 count(*) filter(where model_id not in ($3,$4,$5)),
 count(*) filter(where model_id in ($3,$4) and prompt_version_id=$6),
 count(*) filter(where model_id in ($3,$4) and prompt_version_id is null),
 count(*) filter(where model_id=$5 and prompt_version_id is not null),
 count(*) filter(where model_id=$5 and prompt_version_id is null),
 count(*) filter(where prompt_version_id is not null and prompt_version_id<>$6),
 count(*) filter(where outcome='ok'),
 count(*) filter(where operation_id is distinct from $7),
 count(*) filter(where operation_id is null),
 count(distinct operation_id),count(distinct id)
 from ai_calls where activity_id=$1 and task=$2::ai_task`, activityID, task, models.primary, models.fallback, models.moderator, version, operation).Scan(
		&got.total, &got.primary, &got.fallback, &got.moderator, &got.otherModel,
		&got.generatedVersioned, &got.generatedUnversioned,
		&got.moderatedVersioned, &got.moderatedUnversioned, &got.unexpectedVersion,
		&got.ok, &got.operationMismatch, &got.withoutOperation,
		&got.distinctOperations, &got.attempts,
	))
	return got
}

func (h *practiceWire) requireAICalls(label string, activityID uuid.UUID, task string, models routeModels, version, operation uuid.UUID, want aiCallBreakdown) aiCallBreakdown {
	h.t.Helper()
	got := h.aiCalls(activityID, task, models, version, operation)
	if got != want {
		h.t.Fatalf("%s ai_calls=%+v want %+v", label, got, want)
	}
	return got
}

func (h *practiceWire) aiCallSnapshot(activityID uuid.UUID) string {
	h.t.Helper()
	var snapshot string
	h.must(h.s.db.QueryRow(h.ctx, `select count(*)::text || '|' || coalesce(string_agg(
 coalesce(id::text,'') || ':' || coalesce(operation_id::text,'') || ':' || coalesce(model_id::text,'') || ':' ||
 coalesce(prompt_version_id::text,'') || ':' || task::text || ':' || outcome || ':' || coalesce(score_id::text,''),
 ';' order by id),'') from ai_calls where activity_id=$1`, activityID).Scan(&snapshot))
	return snapshot
}

func (h *practiceWire) quotaSnapshot(activityID uuid.UUID) string {
	h.t.Helper()
	var snapshot string
	h.must(h.s.db.QueryRow(h.ctx, `select count(*)::text || '|' || coalesce(string_agg(
 charged_day::text || ':' || charged_at::text || ':' || coalesce(refunded_at::text,'null'),
 ';' order by charged_day),'') from quota_ledger where activity_id=$1`, activityID).Scan(&snapshot))
	return snapshot
}

func (h *practiceWire) messageSnapshot(activityID uuid.UUID) string {
	h.t.Helper()
	var snapshot string
	h.must(h.s.db.QueryRow(h.ctx, `select count(*)::text || '|' || coalesce(string_agg(
 id::text || ':' || client_message_id::text || ':' || seq::text || ':' || role || ':' || encode(content_enc,'hex'),
 ';' order by seq),'') from practice_messages where activity_id=$1`, activityID).Scan(&snapshot))
	return snapshot
}

func (h *practiceWire) planSnapshot(userID uuid.UUID) string {
	h.t.Helper()
	var snapshot string
	h.must(h.s.db.QueryRow(h.ctx, `select count(*)::text || '|' || coalesce(string_agg(
 plan_day::text || ':' || coalesce(completed_at::text,'null') || ':' || encode(plan_enc,'hex'),
 ';' order by plan_day),'') from daily_plans where user_id=$1`, userID).Scan(&snapshot))
	return snapshot
}

func restartPracticeWire(t *testing.T, h *practiceWire) {
	t.Helper()
	h.api.Close()
	h.s.Close()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	h.s, err = Start(h.ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	h.api = httptest.NewServer(h.s.Router())
	t.Cleanup(h.s.Close)
	t.Cleanup(h.api.Close)
}

func publishRolePlay(t *testing.T, h *practiceWire, token string, version uuid.UUID, models ...uuid.UUID) {
	t.Helper()
	for _, model := range models {
		h.admin(token, "PUT", "prompt-releases", admin.PromptRelease{
			Task:              admin.TaskRolePlay,
			ModelId:           model,
			PrimaryVersionId:  version,
			ExperimentPercent: 0,
		}, 200, nil)
	}
}

func TestPublishedPromptPlanRolePlayIntegration(t *testing.T) {
	h := newPracticeWire(t)
	operator := h.adminLogin()

	var official admin.PromptVersion
	h.admin(operator, "POST", "prompt-versions", admin.CreatePromptVersionJSONBody{
		Task:     admin.TaskRolePlay,
		Template: officialRolePlayPrompt,
	}, 200, &official)
	models := []uuid.UUID{h.primaryModel, h.fallbackModel}
	publishRolePlay(t, h, operator, official.Id, models...)
	if got := h.number(`select count(*) from prompt_releases where task='role_play' and model_id in ($1,$2) and primary_version_id=$3 and experiment_version_id is null and experiment_percent=0`, h.primaryModel, h.fallbackModel, official.Id); got != 2 {
		t.Fatalf("official prompt releases=%d want 2", got)
	}

	user := h.assessmentUser()
	var instrument app.GetInstrumentResult
	h.json(user.AccessToken, "GET", "assessments/instrument", nil, 200, &instrument)
	if len(instrument.Items) != 16 {
		t.Fatalf("assessment items=%d want 16", len(instrument.Items))
	}
	answers := []int{1, 1, 1, 1, 7, 7, 7, 7, 5, 6, 5, 6, 1, 1, 1, 2}
	h.json(user.AccessToken, "POST", "assessments", app.SubmitAssessmentInput{
		Version: instrument.Version,
		Answers: answers,
	}, 200, nil)
	if got := h.number(`select count(*) from daily_plans where user_id=$1`, user.UserId); got != 1 {
		t.Fatalf("assessment-created plans=%d want 1", got)
	}

	var plan app.GetTodayPlanResult
	h.json(user.AccessToken, "GET", "plans/today", nil, 200, &plan)
	var levels app.ListLevelsResult
	h.json(user.AccessToken, "GET", "levels?limit=100", nil, 200, &levels)
	var full app.Level
	found := false
	for _, level := range levels.Items {
		if level.Mode != app.LevelModeFullSession {
			continue
		}
		for _, item := range plan.Items {
			if item.Kind == app.PlanItemKindLevel && item.ContentId == level.Id {
				full = level
				found = true
				break
			}
		}
		if found {
			break
		}
	}
	if !found {
		t.Fatal("today plan has no real full-session catalog level")
	}
	expectedScene, ok := frozenFullSessionScenes[full.Scene]
	if !ok {
		t.Fatalf("unexpected full-session scene %q", full.Scene)
	}

	path := h.createLevel(user, full.Id)
	sessionID := uuid.MustParse(strings.TrimPrefix(path, "sessions/"))
	var sourceID uuid.UUID
	h.must(h.s.db.QueryRow(h.ctx, `select source_id from activities where id=$1 and user_id=$2`, sessionID, user.UserId).Scan(&sourceID))
	roleModels := h.route("role_play")
	key := uuid.NewString()
	generations := h.generations.Load()
	h.frames(user, path, key, "fragment", "fragment", "reply_saved")
	if got := h.generations.Load(); got != generations+1 {
		t.Fatalf("first turn generations=%d want %d", got, generations+1)
	}
	roleCalls := aiCallBreakdown{
		total: 5, primary: 1, moderator: 4,
		generatedVersioned: 1, moderatedUnversioned: 4,
		ok: 5, distinctOperations: 1, attempts: 5,
	}
	h.requireAICalls("first turn", sessionID, "role_play", roleModels, official.Id, uuid.MustParse(key), roleCalls)
	if got := h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is null`, sessionID); got != 1 {
		t.Fatalf("first-turn unrefunded ledger rows=%d want 1", got)
	}

	h.captureMu.Lock()
	system, firstUser := h.lastSystem, h.lastUser
	h.captureMu.Unlock()
	wantSystem := strings.ReplaceAll(officialRolePlayPrompt, "{{scene}}", expectedScene)
	if system != wantSystem {
		t.Fatalf("published scene system=%q want %q", system, wantSystem)
	}
	if !strings.Contains(firstUser, expectedScene) {
		t.Fatalf("first user message omitted frozen scene %q: %s", expectedScene, firstUser)
	}

	firstCalls := h.aiCallSnapshot(sessionID)
	firstQuota := h.quotaSnapshot(sessionID)
	firstMessages := h.messageSnapshot(sessionID)
	firstGrades := h.grades.Load()
	generations = h.generations.Load()
	h.frames(user, path, key, "reply_saved")
	if got := h.generations.Load(); got != generations {
		t.Fatalf("idempotent replay regenerated: %d -> %d", generations, got)
	}
	if got := h.aiCallSnapshot(sessionID); got != firstCalls {
		t.Fatalf("idempotent replay changed ai_calls: %q -> %q", firstCalls, got)
	}
	if got := h.quotaSnapshot(sessionID); got != firstQuota {
		t.Fatalf("idempotent replay changed quota ledger: %q -> %q", firstQuota, got)
	}
	if got := h.messageSnapshot(sessionID); got != firstMessages {
		t.Fatalf("idempotent replay changed practice messages: %q -> %q", firstMessages, got)
	}
	if got := h.grades.Load(); got != firstGrades {
		t.Fatalf("idempotent replay changed scoring generations: %d -> %d", firstGrades, got)
	}
	h.requireAICalls("first-turn replay", sessionID, "role_play", roleModels, official.Id, uuid.MustParse(key), roleCalls)
	if got := h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is null`, sessionID); got != 1 {
		t.Fatalf("replayed first-turn unrefunded ledger rows=%d want 1", got)
	}

	scoringModels := h.route("scoring")
	var scoringVersion uuid.UUID
	h.must(h.s.db.QueryRow(h.ctx, `select primary_version_id from prompt_releases where task='scoring' and model_id=$1`, scoringModels.primary).Scan(&scoringVersion))
	grades := h.grades.Load()
	var first, replay training.Result
	h.json(user.AccessToken, "POST", path+"/finish", nil, 200, &first)
	if first.Score == nil || first.Score.ID != sourceID {
		t.Fatalf("finish score=%+v want source %s", first.Score, sourceID)
	}
	if got := h.grades.Load(); got != grades+1 {
		t.Fatalf("finish scoring rounds=%d want %d", got, grades+1)
	}
	scoringCalls := aiCallBreakdown{
		total: 3, primary: 1, moderator: 2,
		generatedVersioned: 1, moderatedUnversioned: 2,
		ok: 3, distinctOperations: 1, attempts: 3,
	}
	h.requireAICalls("first scoring", sessionID, "scoring", scoringModels, scoringVersion, sourceID, scoringCalls)
	if got := h.number(`select count(*) from ai_calls where activity_id=$1`, sessionID); got != 8 {
		t.Fatalf("activity ai_calls=%d want 5 role_play + 3 scoring", got)
	}
	if got := h.number(`select count(*) from scores where activity_id=$1`, sessionID); got != 1 {
		t.Fatalf("scores=%d want 1", got)
	}
	if got := h.number(`select count(*) from scores where activity_id=$1 and id=$2`, sessionID, sourceID); got != 1 {
		t.Fatalf("score id is not activities.source_id")
	}
	var linked, unlinked, wrongLink int
	h.must(h.s.db.QueryRow(h.ctx, `select count(*) filter(where score_id=$2),
 count(*) filter(where score_id is null),
 count(*) filter(where score_id is not null and not (score_id=$2 and model_id=$3))
 from ai_calls where activity_id=$1 and task='scoring'`, sessionID, sourceID, scoringModels.primary).Scan(&linked, &unlinked, &wrongLink))
	if linked != 1 || unlinked != 2 || wrongLink != 0 {
		t.Fatalf("scoring score links linked/unlinked/wrong=%d/%d/%d want 1/2/0", linked, unlinked, wrongLink)
	}
	if got := h.quotaSnapshot(sessionID); got != firstQuota {
		t.Fatalf("scoring changed quota ledger: %q -> %q", firstQuota, got)
	}
	h.ledger(user, path, "complete", 1)
	if got := h.number(`select count(*) from daily_plans where user_id=$1 and completed_at is not null`, user.UserId); got != 1 {
		t.Fatalf("completed daily plans=%d want 1", got)
	}

	h.json(user.AccessToken, "GET", "plans/today", nil, 200, &plan)
	completed := false
	for _, item := range plan.Items {
		if item.Kind == app.PlanItemKindLevel && item.ContentId == full.Id && item.Completed {
			completed = true
			break
		}
	}
	if !completed {
		t.Fatal("completed full-session level was not projected back into today's plan")
	}
	finishCalls := h.aiCallSnapshot(sessionID)
	finishQuota := h.quotaSnapshot(sessionID)
	finishMessages := h.messageSnapshot(sessionID)
	finishPlan := h.planSnapshot(user.UserId)
	finishGrades := h.grades.Load()
	finishGenerations := h.generations.Load()
	h.json(user.AccessToken, "POST", path+"/finish", nil, 200, &replay)
	if !reflect.DeepEqual(first, replay) {
		t.Fatalf("finish replay differs: first=%+v replay=%+v", first, replay)
	}
	if got := h.aiCallSnapshot(sessionID); got != finishCalls {
		t.Fatalf("finish replay changed ai_calls: %q -> %q", finishCalls, got)
	}
	if got := h.quotaSnapshot(sessionID); got != finishQuota {
		t.Fatalf("finish replay changed quota ledger: %q -> %q", finishQuota, got)
	}
	if got := h.messageSnapshot(sessionID); got != finishMessages {
		t.Fatalf("finish replay changed practice messages: %q -> %q", finishMessages, got)
	}
	if got := h.planSnapshot(user.UserId); got != finishPlan {
		t.Fatalf("finish replay rewrote plan: %q -> %q", finishPlan, got)
	}
	if got := h.grades.Load(); got != finishGrades {
		t.Fatalf("finish replay scored again: %d -> %d", finishGrades, got)
	}
	if got := h.generations.Load(); got != finishGenerations {
		t.Fatalf("finish replay generated again: %d -> %d", finishGenerations, got)
	}
	if got := h.number(`select count(*) from scores where activity_id=$1`, sessionID); got != 1 {
		t.Fatalf("finish replay scores=%d want 1", got)
	}
	h.requireAICalls("finish replay", sessionID, "scoring", scoringModels, scoringVersion, sourceID, scoringCalls)
	var growth app.GetGrowthResult
	h.json(user.AccessToken, "GET", "growth", nil, 200, &growth)
	if growth.WleisPercent == nil || growth.ValidBehaviorCount != 1 || growth.TrainingReference == nil {
		t.Fatalf("growth readback: WLEIS=%v valid=%d reference=%v", growth.WleisPercent, growth.ValidBehaviorCount, growth.TrainingReference)
	}

	roleVersions := h.number(`select count(*) from prompt_versions where task='role_play'`)
	h.admin(operator, "POST", "prompt-versions", admin.CreatePromptVersionJSONBody{
		Task:     admin.TaskRolePlay,
		Template: "{{profile}}",
	}, 400, nil)
	if got := h.number(`select count(*) from prompt_versions where task='role_play'`); got != roleVersions {
		t.Fatalf("rejected variable changed role_play versions: %d -> %d", roleVersions, got)
	}

	var invalidVersion uuid.UUID
	h.must(h.s.db.QueryRow(h.ctx, `insert into prompt_versions(task,version,template)
		select 'role_play',coalesce(max(version),0)+1,'{{profile}}' from prompt_versions where task='role_play'
		returning id`).Scan(&invalidVersion))
	h.admin(operator, "PUT", "prompt-releases", admin.PromptRelease{
		Task:              admin.TaskRolePlay,
		ModelId:           h.primaryModel,
		PrimaryVersionId:  invalidVersion,
		ExperimentPercent: 0,
	}, 400, nil)
	if got := h.number(`select count(*) from prompt_releases where task='role_play' and model_id in ($1,$2) and primary_version_id=$3 and experiment_version_id is null and experiment_percent=0`, h.primaryModel, h.fallbackModel, official.Id); got != 2 {
		t.Fatalf("invalid release moved live pointers: official releases=%d want 2", got)
	}

	seed := uuid.MustParse(rolePlaySeedVersionID)
	publishRolePlay(t, h, operator, seed, models...)
	if got := h.number(`select count(*) from prompt_releases where task='role_play' and model_id in ($1,$2) and primary_version_id=$3`, h.primaryModel, h.fallbackModel, seed); got != 2 {
		t.Fatalf("rollback releases=%d want 2", got)
	}

	rollbackPlan := h.planSnapshot(user.UserId)
	restartPracticeWire(t, h)
	if got := h.number(`select count(*) from prompt_releases where task='role_play' and model_id in ($1,$2) and primary_version_id=$3`, h.primaryModel, h.fallbackModel, seed); got != 2 {
		t.Fatalf("restarted rollback releases=%d want 2", got)
	}
	if got := h.planSnapshot(user.UserId); got != rollbackPlan {
		t.Fatalf("restart rewrote completed plan: %q -> %q", rollbackPlan, got)
	}

	secondRoleModels := h.route("role_play")
	second := h.user()
	secondPath := h.createLevel(second, full.Id)
	secondID := uuid.MustParse(strings.TrimPrefix(secondPath, "sessions/"))
	secondKey := uuid.NewString()
	generations = h.generations.Load()
	h.frames(second, secondPath, secondKey, "fragment", "fragment", "reply_saved")
	if got := h.generations.Load(); got != generations+1 {
		t.Fatalf("post-rollback generations=%d want %d", got, generations+1)
	}
	h.captureMu.Lock()
	system, firstUser = h.lastSystem, h.lastUser
	h.captureMu.Unlock()
	if system != training.Seed() {
		t.Fatal("post-rollback turn did not resolve the frozen seed prompt")
	}
	if !strings.Contains(firstUser, expectedScene) {
		t.Fatalf("post-rollback first user message omitted frozen scene %q: %s", expectedScene, firstUser)
	}
	seedCalls := aiCallBreakdown{
		total: 5, primary: 1, moderator: 4,
		generatedVersioned: 1, moderatedUnversioned: 4,
		ok: 5, distinctOperations: 1, attempts: 5,
	}
	h.requireAICalls("post-rollback turn", secondID, "role_play", secondRoleModels, seed, uuid.MustParse(secondKey), seedCalls)
	if got := h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is null`, secondID); got != 1 {
		t.Fatalf("post-rollback unrefunded ledger rows=%d want 1", got)
	}
	h.ledger(second, secondPath, "active", 1)
	secondCalls := h.aiCallSnapshot(secondID)
	secondQuota := h.quotaSnapshot(secondID)
	secondMessages := h.messageSnapshot(secondID)
	secondGrades := h.grades.Load()

	// Replay after another cold composition-root start proves the idempotency
	// record, audit trail and charge survive process restart unchanged.
	restartPracticeWire(t, h)
	if got := h.aiCallSnapshot(secondID); got != secondCalls {
		t.Fatalf("restart changed post-rollback ai_calls: %q -> %q", secondCalls, got)
	}
	if got := h.quotaSnapshot(secondID); got != secondQuota {
		t.Fatalf("restart changed post-rollback quota ledger: %q -> %q", secondQuota, got)
	}
	if got := h.planSnapshot(user.UserId); got != rollbackPlan {
		t.Fatalf("second restart rewrote completed plan: %q -> %q", rollbackPlan, got)
	}
	generations = h.generations.Load()
	h.frames(second, secondPath, secondKey, "reply_saved")
	if got := h.generations.Load(); got != generations {
		t.Fatalf("post-rollback replay regenerated: %d -> %d", generations, got)
	}
	if got := h.aiCallSnapshot(secondID); got != secondCalls {
		t.Fatalf("post-rollback replay changed ai_calls: %q -> %q", secondCalls, got)
	}
	if got := h.quotaSnapshot(secondID); got != secondQuota {
		t.Fatalf("post-rollback replay changed quota ledger: %q -> %q", secondQuota, got)
	}
	if got := h.messageSnapshot(secondID); got != secondMessages {
		t.Fatalf("post-rollback replay changed practice messages: %q -> %q", secondMessages, got)
	}
	if got := h.grades.Load(); got != secondGrades {
		t.Fatalf("post-rollback replay changed scoring generations: %d -> %d", secondGrades, got)
	}
	h.requireAICalls("post-rollback replay", secondID, "role_play", secondRoleModels, seed, uuid.MustParse(secondKey), seedCalls)
	if got := h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is null`, secondID); got != 1 {
		t.Fatalf("post-rollback replay unrefunded ledger rows=%d want 1", got)
	}
}
