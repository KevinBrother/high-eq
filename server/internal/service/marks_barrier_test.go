package service

import (
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"

	"high-eq/server/internal/privacy"
)

func TestT32AHiddenBarrierIsRetryable(t *testing.T) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	accountError(c, privacy.ErrHidden)
	if w.Code != 503 {
		t.Fatalf("pending barrier status = %d, want 503", w.Code)
	}
	var body struct {
		Code      string `json:"code"`
		Retryable bool   `json:"retryable"`
	}
	if e := json.Unmarshal(w.Body.Bytes(), &body); e != nil {
		t.Fatal(e)
	}
	if body.Code != "service_unavailable" || !body.Retryable {
		t.Fatalf("pending barrier body = %#v", body)
	}
}
