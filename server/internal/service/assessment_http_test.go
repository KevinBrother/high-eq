package service

import (
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
)

func TestAssessmentHTTPBoundaries(t *testing.T) {
	router := (&Runtime{}).Router()
	for _, route := range [][2]string{{"GET", "/v1/assessments/instrument"}, {"POST", "/v1/assessments"}, {"GET", "/v1/assessments"}} {
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest(route[0], route[1], nil))
		if w.Code != 401 {
			t.Errorf("%v: got %d", route, w.Code)
		}
	}
	at := time.Date(2026, 12, 19, 1, 0, 0, 0, time.UTC)
	for _, tt := range []struct {
		e      error
		status int
		code   string
	}{{assessment.ErrConsent, 403, "forbidden"}, {assessment.ErrInvalid, 400, "invalid_argument"}, {&assessment.TooSoon{RetryAt: at}, 409, "conflict"}} {
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		assessmentReply(c, nil, tt.e)
		var out app.Error
		if e := json.Unmarshal(w.Body.Bytes(), &out); e != nil || w.Code != tt.status || out.Code != tt.code || out.Retryable {
			t.Errorf("%v => %d %s", tt.e, w.Code, w.Body.String())
		}
		if tt.status == 409 && (out.RetryAt == nil || !out.RetryAt.Equal(at)) {
			t.Fatal("missing retry_at")
		}
	}
}
