package service

import (
	"net/http/httptest"
	"strings"
	"testing"
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
