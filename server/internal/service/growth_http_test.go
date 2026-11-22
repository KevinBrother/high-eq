package service

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/membership"
)

func TestGrowthHTTPRequiresAuthenticatedSession(t *testing.T) {
	router := (&Runtime{}).Router()
	for _, route := range [][2]string{
		{"GET", "/v1/plans/today"},
		{"POST", "/v1/plans/items/" + uuid.NewString() + "/complete"},
		{"GET", "/v1/exercises/" + uuid.NewString()},
		{"POST", "/v1/exercises/" + uuid.NewString() + "/answers"},
		{"GET", "/v1/cards"},
		{"GET", "/v1/cards/" + uuid.NewString()},
		{"GET", "/v1/growth"},
	} {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest(route[0], route[1], nil))
		if w.Code != 401 {
			t.Errorf("%s %s: got %d, want 401", route[0], route[1], w.Code)
		}
	}
}

func TestGrowthErrorMapping(t *testing.T) {
	for _, tt := range []struct {
		name string
		err  error
		code int
		body string
	}{
		{"invalid", growth.ErrInvalid, 400, "invalid_argument"},
		{"not found", growth.ErrNotFound, 404, "not_found"},
		{"no rows", pgx.ErrNoRows, 404, "not_found"},
		{"forbidden", membership.ErrForbidden, 403, "forbidden"},
		{"limit", membership.ErrLimit, 429, "quota_exceeded"},
		{"conflict", membership.ErrConflict, 409, "conflict"},
		{"unavailable", growth.ErrUnavailable, 503, "unavailable"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(w)
			growthError(c, tt.err)
			var out app.Error
			if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
			if w.Code != tt.code || out.Code != tt.body {
				t.Fatalf("got %d %#v", w.Code, out)
			}
		})
	}
}

func TestGrowthCardLimitBoundaries(t *testing.T) {
	value := func(v int) *int { return &v }
	if got, err := growthCardsLimit(app.ListCardsParams{}); err != nil || got != 20 {
		t.Fatalf("default: %d %v", got, err)
	}
	for _, limit := range []int{1, 100} {
		if got, err := growthCardsLimit(app.ListCardsParams{Limit: value(limit)}); err != nil || got != limit {
			t.Fatalf("limit %d: %d %v", limit, got, err)
		}
	}
	for _, limit := range []int{-1, 0, 101} {
		if _, err := growthCardsLimit(app.ListCardsParams{Limit: value(limit)}); !errors.Is(err, growth.ErrInvalid) {
			t.Fatalf("limit %d accepted: %v", limit, err)
		}
	}
}

func TestGrowthRouteFreezePolicy(t *testing.T) {
	for route, frozen := range map[string]bool{
		"GET /v1/plans/today":               false,
		"POST /v1/plans/items/:id/complete": false,
		"GET /v1/exercises/:id":             false,
		"POST /v1/exercises/:id/answers":    false,
		"GET /v1/cards":                     false,
		"GET /v1/cards/:id":                 false,
		"GET /v1/growth":                    false,
	} {
		if got, ok := accountRoutes[route]; !ok || got != frozen {
			t.Errorf("%s: got %v, want present=%v", route, got, frozen)
		}
	}
}

func TestGrowthResponsesDoNotExposeInternalFields(t *testing.T) {
	reviewActivityID := uuid.New()
	plan, err := todayPlanResponse(growth.Plan{
		Day: "2026-11-22",
		Items: []growth.PlanItem{{
			ID: uuid.New(), Kind: growth.KindLevel, Title: "review", ContentID: uuid.New(), Review: true, ReviewActivityID: &reviewActivityID,
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(plan)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("review_activity_id")) || bytes.Contains(raw, []byte(reviewActivityID.String())) {
		t.Fatalf("plan leaked internal scheduling state: %s", raw)
	}

	exercise := growth.Exercise{
		ID: uuid.New(), Question: "question", Choices: []string{"a", "b"}, AnswerIndex: 1, Explanation: "because",
	}
	raw, err = json.Marshal(exerciseResponse(exercise))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, []byte("answer_index")) || bytes.Contains(raw, []byte("explanation")) {
		t.Fatalf("exercise leaked answer material: %s", raw)
	}
}

func TestGrowthResponsesEncodeEmptyAchievementsAsArray(t *testing.T) {
	for name, value := range map[string]any{
		"complete": planProgressResponse(growth.PlanProgress{}),
		"growth":   growthResponse(growth.GrowthSummary{}),
	} {
		raw, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Contains(raw, []byte(`"achievements":[]`)) || bytes.Contains(raw, []byte(`"achievements":null`)) {
			t.Fatalf("%s achievements: %s", name, raw)
		}
	}
}

func TestAnswerExerciseRequiresChoiceIndex(t *testing.T) {
	for name, body := range map[string]string{
		"missing": `{}`,
		"null":    `{"choice_index":null}`,
	} {
		t.Run(name, func(t *testing.T) {
			w := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(w)
			c.Request = httptest.NewRequest("POST", "/v1/exercises/"+uuid.NewString()+"/answers", strings.NewReader(body))
			if choice, ok := decodeAnswerExercise(c); ok || choice != 0 || w.Code != 400 {
				t.Fatalf("choice=%d ok=%v status=%d body=%s", choice, ok, w.Code, w.Body.String())
			}
		})
	}

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/v1/exercises/"+uuid.NewString()+"/answers", strings.NewReader(`{"choice_index":0}`))
	if choice, ok := decodeAnswerExercise(c); !ok || choice != 0 {
		t.Fatalf("zero choice rejected: choice=%d ok=%v status=%d body=%s", choice, ok, w.Code, w.Body.String())
	}
}
