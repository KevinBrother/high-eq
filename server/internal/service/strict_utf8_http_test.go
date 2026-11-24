package service

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
)

func TestCreateSessionRejectsInvalidUTF8BeforeService(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.POST("/v1/sessions", appAPI{}.CreateSession)

	body := append([]byte(`{"request_id":"`+uuid.NewString()+`","scene":"work","scenario":"合成`), 0xff)
	body = append(body, []byte(`"}`)...)
	req := httptest.NewRequest(http.MethodPost, "/v1/sessions", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400", w.Code)
	}
	var got struct {
		Code      string `json:"code"`
		Message   string `json:"message"`
		Retryable bool   `json:"retryable"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Code != "invalid_argument" || got.Retryable || strings.Contains(got.Message, "合成") {
		t.Fatalf("unexpected error response: %+v", got)
	}
}
