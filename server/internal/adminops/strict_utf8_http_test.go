package adminops

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestCreatePromptVersionRejectsInvalidUTF8BeforeDatabase(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.POST("/admin/v1/prompt-versions", api{}.CreatePromptVersion)

	body := append([]byte(`{"task":"reply_suggestion","template":"合成`), 0xff)
	body = append(body, []byte(`"}`)...)
	req := httptest.NewRequest(http.MethodPost, "/admin/v1/prompt-versions", bytes.NewReader(body))
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

func TestCreatePromptVersionConsumesBodyWithoutReplay(t *testing.T) {
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/admin/v1/prompt-versions",
		strings.NewReader(`{"task":"reply_suggestion","template":"合成","unexpected":true}`))
	originalBody := c.Request.Body

	api{}.CreatePromptVersion(c)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400 for unexpected field", w.Code)
	}
	if c.Request.Body != originalBody {
		t.Fatal("handler replaced the body with a replay before validating the fields")
	}
}
