//go:build integration

package service

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"high-eq/server/internal/adminops"
)

// A valid bearer in one production router namespace must not authorize the other.
func TestAdminIsolation(t *testing.T) {
	ctx := context.Background()
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	r := s.Router()
	call := func(method, path, token, body string, want int) string {
		t.Helper()
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("%s: %d; want %d", path, w.Code, want)
		}
		var out struct {
			Token string `json:"access_token"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out.Token
	}
	name := uuid.NewString()
	const pass = "only-for-fixtures"
	if _, e := adminops.Provision(ctx, s.db, name, pass, "super_admin"); e != nil {
		t.Fatal(e)
	}
	adminToken := call("POST", "/admin/v1/auth/login", "", `{"login":"`+name+`","password":"`+pass+`"}`, 200)
	ticket := uuid.NewString()
	if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); e != nil {
		t.Fatal(e)
	}
	appToken := call("POST", "/v1/auth/login", "", `{"credential":{"provider":"apple","proof":"`+ticket+`"},"age_confirmed":true,"privacy_version":"2026-11","terms_version":"2026-11"}`, 200)
	call("GET", "/v1/me", appToken, "", 200)
	call("GET", "/admin/v1/audit-logs", adminToken, "", 200)
	call("GET", "/admin/v1/audit-logs", appToken, "", 401)
	call("GET", "/v1/me", adminToken, "", 401)
}
