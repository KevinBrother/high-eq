//go:build integration

package service

import (
	"bytes"
	"encoding/json"
	"io"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/training"
)

func TestPracticeErasureRemovesOnlyItsPlanContribution(t *testing.T) {
	h := newPracticeWire(t)
	for _, tc := range []struct {
		name      string
		drill     bool
		sameLevel bool
		manual    bool
	}{
		{name: "sole source"},
		{name: "same level repeat", sameLevel: true},
		{name: "single skill and manual completion", drill: true, manual: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			owner := h.assessmentUser()
			token := owner.AccessToken
			zone := "UTC"
			if hour := time.Now().UTC().Hour(); hour < 2 || hour >= 22 {
				zone = "Asia/Shanghai"
			}
			erasureJSON(t, h, token, "PATCH", "me", app.UpdateMeInput{Timezone: zone}, 200, nil)
			var instrument app.GetInstrumentResult
			erasureJSON(t, h, token, "GET", "assessments/instrument", nil, 200, &instrument)
			var assessment app.Assessment
			erasureJSON(t, h, token, "POST", "assessments", app.SubmitAssessmentInput{
				Version: instrument.Version,
				Answers: []int{4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4},
			}, 200, &assessment)

			readPlan := func(t *testing.T) app.GetTodayPlanResult {
				t.Helper()
				var plan app.GetTodayPlanResult
				erasureJSON(t, h, token, "GET", "plans/today", nil, 200, &plan)
				return plan
			}
			initial := readPlan(t)
			mode := app.LevelModeFullSession
			if tc.drill {
				mode = app.LevelModeSingleSkill
			}
			targetItem, manualItem, otherFull := erasurePlanItems(t, h, token, initial, mode)
			create := func(in training.Input, finish bool) training.Session {
				var created training.SessionSummary
				erasureJSON(t, h, token, "POST", "sessions", in, 200, &created)
				if created.ID != in.ID {
					t.Fatalf("created session = %s, want %s", created.ID, in.ID)
				}
				path := "sessions/" + created.ID.String()
				if finish {
					h.send(owner, path)
					erasureJSON(t, h, token, "POST", path+"/finish", nil, 200, nil)
				}
				return h.history(owner, path)
			}
			original := training.Input{ID: uuid.New(), Level: &targetItem.ContentId}
			target := create(original, true)
			if target.Result == nil || target.CompletedAt == nil || target.Settlement.Net != 1 ||
				(tc.drill && target.Result.Progress == nil) ||
				(!tc.drill && (target.Result.Score == nil || target.Result.Score.TargetTurn == nil || *target.Result.Score.TargetTurn != 1)) {
				t.Fatalf("incomplete practice fixture: %+v", target)
			}
			var source uuid.UUID
			h.must(h.s.db.QueryRow(h.ctx, "select source_id from activities where id=$1", target.ID).Scan(&source))

			repeat := training.Input{ID: uuid.New(), Level: original.Level, Previous: &target.ID}
			survivor := create(repeat, tc.sameLevel)
			if survivor.Setup == nil || survivor.Setup.Previous == nil || *survivor.Setup.Previous != target.ID {
				t.Fatalf("repeat did not retain the live previous session: %+v", survivor.Setup)
			}
			if !tc.sameLevel {
				control := create(training.Input{ID: uuid.New(), Level: &otherFull}, true)
				if control.Result == nil || control.Result.Score == nil || control.Settlement.Net != 1 {
					t.Fatalf("incomplete unrelated practice: %+v", control)
				}
			}
			if tc.manual {
				erasureJSON(t, h, token, "POST", "plans/items/"+manualItem.Id.String()+"/complete", nil, 200, nil)
			}
			readGrowth := func(t *testing.T) app.GetGrowthResult {
				t.Helper()
				var result app.GetGrowthResult
				erasureJSON(t, h, token, "GET", "growth", nil, 200, &result)
				return result
			}
			beforeGrowth := readGrowth(t)
			before := t35Download(t, h.s.Router(), token)
			beforePlan := erasureExportPlan(t, t35Part(t, before, "growth"), initial)
			if beforeGrowth.Streak != 1 || beforePlan.CompletedAt == nil || !beforePlan.CompletedAt.Equal(*target.CompletedAt) ||
				!erasurePlanCompletion(beforePlan, targetItem.Id) ||
				!bytes.Contains(t35Part(t, before, "training"), []byte(`"previous_id":"`+target.ID.String()+`"`)) {
				t.Fatalf("missing deletion preconditions: growth=%+v plan=%+v", beforeGrowth, beforePlan)
			}

			erasureJSON(t, h, token, "DELETE", "me/data/sessions/"+target.ID.String(), nil, 200, nil)
			erasureJSON(t, h, token, "GET", "sessions/"+target.ID.String(), nil, 404, nil)
			expiresIn, err := h.s.registryRedis.PTTL(h.ctx, "deleted:"+source.String()).Result()
			h.must(err)
			if expiresIn <= 0 {
				t.Fatalf("deleted source has no live ledger entry: %v", expiresIn)
			}
			if raw, err := h.s.registryRedis.Get(h.ctx, "deleted:"+source.String()).Result(); err != nil || raw != "" {
				t.Fatalf("deleted source ledger is not an empty tombstone: %q, %v", raw, err)
			}
			if count, err := h.s.cache.Exists(h.ctx, "deleted:"+source.String()).Result(); err != nil || count != 0 {
				t.Fatalf("deletion ledger key present in the ordinary cache: %d, %v", count, err)
			}

			t.Run("growth plan and check-in", func(t *testing.T) {
				actual := readPlan(t)
				want := initial
				want.Items = append([]app.PlanItem(nil), initial.Items...)
				for i := range want.Items {
					item := &want.Items[i]
					item.Completed = item.Id == targetItem.Id && tc.sameLevel || item.Id == manualItem.Id && tc.manual
				}
				if !reflect.DeepEqual(actual, want) {
					t.Fatalf("today plan after deletion = %+v, want %+v", actual, want)
				}
				afterGrowth := readGrowth(t)
				wantStreak := 0
				if tc.sameLevel || tc.manual {
					wantStreak = 1
				}
				if afterGrowth.Streak != wantStreak || afterGrowth.ValidBehaviorCount != 1 ||
					afterGrowth.LatestAssessment == nil || *afterGrowth.LatestAssessment != assessment.Id {
					t.Fatalf("growth after erasure = %+v, want streak %d, one valid score and the original assessment", afterGrowth, wantStreak)
				}
				completeStatus := 400
				if tc.sameLevel {
					completeStatus = 200
				}
				erasureJSON(t, h, token, "POST", "plans/items/"+targetItem.Id.String()+"/complete", nil, completeStatus, nil)
			})
			t.Run("repeat detail and protected records", func(t *testing.T) {
				// Retrying the surviving creation still compares the immutable setup.
				erasureJSON(t, h, token, "POST", "sessions", repeat, 200, nil)
				var detail training.Session
				erasureJSON(t, h, token, "GET", "sessions/"+survivor.ID.String(), nil, 200, &detail)
				if detail.Setup == nil || detail.Setup.Previous != nil || !reflect.DeepEqual(detail.SessionSummary, survivor.SessionSummary) {
					t.Fatalf("surviving repeat after erasure = %+v", detail)
				}
				var page wireRecordLocatorPage
				erasureJSON(t, h, token, "GET", "me/data/sessions", nil, 200, &page)
				if recordPageContains(page, target.ID) || !recordPageContains(page, survivor.ID) {
					t.Fatalf("unexpected public record keys: %+v", page)
				}
			})
			t.Run("public export", func(t *testing.T) {
				after := t35Download(t, h.s.Router(), token)
				for _, part := range []string{"training", "growth", "ai_calls"} {
					t35Exclude(t, t35Part(t, after, part), target.ID.String(), source.String())
				}
				if !bytes.Contains(t35Part(t, after, "training"), []byte(survivor.ID.String())) ||
					!bytes.Contains(t35Part(t, after, "assessments"), []byte(assessment.Id.String())) {
					t.Fatal("repeat or assessment is missing from export")
				}
				if !bytes.Equal(t35Part(t, before, "assessments"), t35Part(t, after, "assessments")) {
					t.Fatal("practice erasure changed the assessment export")
				}
				plan := erasureExportPlan(t, t35Part(t, after, "growth"), initial)
				if plan.AssessmentID == nil || *plan.AssessmentID != assessment.Id ||
					erasurePlanCompletion(plan, targetItem.Id) != tc.sameLevel ||
					erasurePlanCompletion(plan, manualItem.Id) != tc.manual {
					t.Fatalf("exported plan retained or dropped a contribution: %+v", plan)
				}
				switch {
				case tc.sameLevel:
					if survivor.CompletedAt == nil || plan.CompletedAt == nil || !plan.CompletedAt.Equal(*survivor.CompletedAt) {
						t.Fatalf("exported check-in = %v, want surviving completion %v", plan.CompletedAt, survivor.CompletedAt)
					}
				case tc.manual:
					if plan.CompletedAt == nil || !plan.CompletedAt.After(*target.CompletedAt) {
						t.Fatalf("exported check-in = %v, want the later manual completion", plan.CompletedAt)
					}
				default:
					if plan.CompletedAt != nil {
						t.Fatalf("exported check-in retained deleted completion: %v", plan.CompletedAt)
					}
				}
			})
			t.Run("original create retry", func(t *testing.T) {
				plan, growth := readPlan(t), readGrowth(t)
				var conflict app.Error
				erasureJSON(t, h, token, "POST", "sessions", original, 409, &conflict)
				if conflict.Code != "conflict" || conflict.Retryable {
					t.Fatalf("erased creation replay was not terminal: %+v", conflict)
				}
				erasureJSON(t, h, token, "GET", "sessions/"+target.ID.String(), nil, 404, nil)
				erasureJSON(t, h, token, "POST", "sessions/"+target.ID.String()+"/finish", nil, 404, nil)
				if !reflect.DeepEqual(plan, readPlan(t)) || !reflect.DeepEqual(growth, readGrowth(t)) {
					t.Fatal("replay changed the plan or growth")
				}
				if got := h.number(`select count(*) from activities where id=$1 or source_id=$2`, target.ID, source); got != 0 {
					t.Fatalf("erased practice exists after retries: %d", got)
				}
				if got := h.number(`select coalesce(sum(used),0) from daily_quota_usage where user_id=$1 and feature='practice'`, owner.UserId); got != 2 {
					t.Fatalf("retained daily practice debits = %d, want 2", got)
				}
			})
		})
	}
}

func erasurePlanItems(t *testing.T, h *practiceWire, token string, plan app.GetTodayPlanResult, mode app.LevelMode) (target, manual app.PlanItem, other uuid.UUID) {
	t.Helper()
	var levels app.ListLevelsResult
	erasureJSON(t, h, token, "GET", "levels?limit=100", nil, 200, &levels)
	for _, item := range plan.Items {
		if item.Kind == app.PlanItemKindExercise {
			manual = item
		}
		for _, level := range levels.Items {
			if item.Kind == app.PlanItemKindLevel && item.ContentId == level.Id && level.Mode == mode {
				target = item
			}
		}
	}
	for _, level := range levels.Items {
		if level.Mode != app.LevelModeFullSession {
			continue
		}
		inPlan := false
		for _, item := range plan.Items {
			inPlan = inPlan || item.ContentId == level.Id
		}
		if !inPlan {
			other = level.Id
			break
		}
	}
	if target.Id == uuid.Nil || manual.Id == uuid.Nil || other == uuid.Nil {
		t.Fatalf("missing plan fixture: %+v", plan)
	}
	return
}

func erasureExportPlan(t *testing.T, raw []byte, initial app.GetTodayPlanResult) growth.PlanExportRecord {
	t.Helper()
	var records []growth.PlanExportRecord
	t35Decode(t, raw, &records)
	for _, record := range records {
		if record.RecordType != "plan" || record.Day != initial.Day.Time.Format(time.DateOnly) {
			continue
		}
		if record.Personalized != initial.Personalized || len(record.Items) != len(initial.Items) {
			t.Fatalf("exported plan shape changed: %+v", record)
		}
		for i, item := range record.Items {
			want := initial.Items[i]
			if item.ID != want.Id || item.Kind != string(want.Kind) || item.Title != want.Title || item.ContentID != want.ContentId {
				t.Fatalf("exported plan item = %+v, want %+v", item, want)
			}
		}
		return record
	}
	t.Fatal("original plan is missing from growth export")
	return growth.PlanExportRecord{}
}

func erasurePlanCompletion(plan growth.PlanExportRecord, id uuid.UUID) bool {
	for _, item := range plan.Items {
		if item.ID == id {
			return item.Completed
		}
	}
	return false
}

func erasureJSON(t *testing.T, h *practiceWire, token, method, path string, input any, status int, output any) {
	t.Helper()
	response, err := h.request(token, method, path, input)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != status {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("%s %s = %d, want %d: %s", method, path, response.StatusCode, status, body)
	}
	if output != nil {
		if err := json.NewDecoder(response.Body).Decode(output); err != nil {
			t.Fatal(err)
		}
	}
}
