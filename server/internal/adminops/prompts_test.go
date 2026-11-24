package adminops

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"high-eq/server/internal/prompts"
)

func TestPromptBodyRejectsInvalidUTF8BeforeJSONReplacement(t *testing.T) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/admin/v1/prompt-versions", bytes.NewReader([]byte("{\"task\":\"role_play\",\"template\":\"bad\xff\"}")))

	var body struct {
		Task     string `json:"task"`
		Template string `json:"template"`
	}
	if promptBody(c, &body, "task", "template") {
		t.Fatalf("accepted invalid UTF-8 template as %q", body.Template)
	}
}

func TestCreatePromptVersionRejectsInvalidUTF8WithFixed400(t *testing.T) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/admin/v1/prompt-versions", bytes.NewReader([]byte("{\"task\":\"role_play\",\"template\":\"PRIVATE\xff\"}")))

	api{}.CreatePromptVersion(c)

	if w.Code != 400 {
		t.Fatalf("status=%d want 400", w.Code)
	}
	if strings.Contains(w.Body.String(), "PRIVATE") {
		t.Fatalf("response leaked request content: %q", w.Body.String())
	}
	var body struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if body.Code != "invalid_argument" || body.Message != "请检查输入或筛选条件" {
		t.Fatalf("body=%+v want fixed invalid_argument response", body)
	}
}

func TestPromptErrorExplainsFixedValidationFailure(t *testing.T) {
	gin.SetMode(gin.TestMode)
	for _, tc := range []struct {
		name string
		err  error
		want string
	}{
		{"variable", fmt.Errorf("PRIVATE TEMPLATE: %w", prompts.ErrVariable), "变量不受支持"},
		{"template", fmt.Errorf("PRIVATE TEMPLATE: %w", prompts.ErrTemplate), "模板语法无效或超过 64 KiB"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(w)
			promptError(c, tc.err)
			if w.Code != 400 {
				t.Fatalf("status=%d want 400", w.Code)
			}
			var body struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			}
			if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
				t.Fatal(err)
			}
			if body.Code != "invalid_argument" || !strings.Contains(body.Message, tc.want) {
				t.Fatalf("body=%+v want invalid_argument containing %q", body, tc.want)
			}
			if strings.Contains(body.Message, "PRIVATE") {
				t.Fatalf("error leaked template context: %q", body.Message)
			}
		})
	}
}
