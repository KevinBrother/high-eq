//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

type deletionHTTPFixture struct {
	*Runtime
	ctx                       context.Context
	minimumTombstoneRetention time.Duration
}

func newDeletionHTTPFixture(t *testing.T) deletionHTTPFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	t.Cleanup(cancel)
	cfg, err := LoadConfig()
	requireDeletionFixture(t, err)
	s, err := Start(ctx, cfg)
	requireDeletionFixture(t, err)
	t.Cleanup(s.Close)
	return deletionHTTPFixture{s, ctx, time.Duration(max(cfg.BackupDays, 30)) * 24 * time.Hour}
}

func requireDeletionFixture(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func (f deletionHTTPFixture) request(t *testing.T, method, path, token string, body any, want int) []byte {
	t.Helper()
	raw, err := json.Marshal(body)
	requireDeletionFixture(t, err)
	r := httptest.NewRequestWithContext(f.ctx, method, path, bytes.NewReader(raw))
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	f.Router().ServeHTTP(w, r)
	if w.Code != want {
		t.Fatalf("%s %s = %d, want %d: %s", method, path, w.Code, want, w.Body.String())
	}
	return w.Body.Bytes()
}

func (f deletionHTTPFixture) proof(t *testing.T, subject string) map[string]any {
	t.Helper()
	ticket := uuid.NewString()
	requireDeletionFixture(t, f.cache.Set(f.ctx, "dev:ticket:apple:"+ticket, subject, time.Minute).Err())
	return map[string]any{"provider": "apple", "proof": ticket}
}

func (f deletionHTTPFixture) register(t *testing.T, subject string) app.Tokens {
	t.Helper()
	var tokens app.Tokens
	requireDeletionFixture(t, json.Unmarshal(f.request(t, "POST", "/v1/auth/login", "", map[string]any{
		"credential": f.proof(t, subject), "age_confirmed": true,
		"privacy_version": "2026-11", "terms_version": "2026-11",
	}, 200), &tokens))
	return tokens
}

func (f deletionHTTPFixture) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	_, err := f.db.Exec(f.ctx, sql, args...)
	requireDeletionFixture(t, err)
}
