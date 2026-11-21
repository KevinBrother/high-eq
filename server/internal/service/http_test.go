package service

import (
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRouter(t *testing.T) {
	for _, tt := range []struct {
		method, path string
		down         bool
		code         int
		body         string
	}{{"GET", "/v1/health", false, 200, `"ok":true`}, {"GET", "/v1/health", true, 500, "internal_error"}, {"GET", "/v1/me", false, 401, "unauthenticated"}, {"GET", "/admin/v1/audit-logs", false, 401, "unauthenticated"}, {"POST", "/v1/auth/login", false, 501, "not_implemented"}, {"GET", "/unknown", false, 404, "not_found"}} {
		router := newRouter(func(context.Context) error {
			if tt.down {
				return errors.New("private connection detail")
			}
			return nil
		}, nil, nil, nil, nil)
		w := httptest.NewRecorder()
		r := httptest.NewRequest(tt.method, tt.path, nil)
		r.Header.Set("Authorization", "Bearer arbitrary")
		router.ServeHTTP(w, r)
		if w.Code != tt.code || !strings.Contains(w.Body.String(), tt.body) || strings.Contains(w.Body.String(), "private") {
			t.Errorf("%s: %d %s", tt.path, w.Code, w.Body)
		}
	}
}
