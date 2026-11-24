package service

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"high-eq/server/internal/privacy"
)

// Exercise both the generated operation registration and the explicit allowlist. No listener or vendor required.
func TestProfileRoutesRequireAccount(t *testing.T) {
	r := new(Runtime).Router()
	id := "11223344-1234-1234-1234-123456789abc"
	for _, path := range []string{"GET /v1/contact-questions", "GET /v1/contacts", "POST /v1/contacts", "PATCH /v1/contacts/:id", "DELETE /v1/contacts/:id", "GET /v1/contacts/:id/summary", "POST /v1/contacts/:id/activate", "POST /v1/contacts/:id/infer", "POST /v1/profiles/feedback", "GET /v1/me/profile", "GET /v1/emotion-summary"} {
		allowFrozen, ok := accountRoutes[path]
		if !ok || allowFrozen {
			t.Fatal(path)
		}
		method, p, _ := strings.Cut(path, " ")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(method, strings.ReplaceAll(p, ":id", id), nil))
		if w.Code != 401 {
			t.Fatal(path, w.Code)
		}
	}
}

func TestContactDeletionUnavailableContract(t *testing.T) {
	gin.SetMode(gin.TestMode)
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	profileReply(c, ack, privacy.ErrHidden)
	if w.Code != 503 || !strings.HasPrefix(w.Header().Get("Content-Type"), "application/json") {
		t.Fatalf("unavailable contact deletion = %d %q", w.Code, w.Header().Get("Content-Type"))
	}
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body) != 3 || body["code"] != "service_unavailable" || body["message"] != "数据暂时不可用，请稍后重试" || body["retryable"] != true {
		t.Fatalf("unavailable contact deletion body = %#v", body)
	}
}
