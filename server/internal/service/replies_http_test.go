package service

import (
	"net/http/httptest"
	"testing"
)

func TestReplyRoutesRequireIdentity(t *testing.T) {
	r := (&Runtime{}).Router()
	for _, path := range []string{"/v1/replies", "/v1/replies/00000000-0000-4000-8000-000000000001/feedback"} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest("POST", path, nil))
		if w.Code != 401 {
			t.Fatalf("%s: %d", path, w.Code)
		}
	}
}
