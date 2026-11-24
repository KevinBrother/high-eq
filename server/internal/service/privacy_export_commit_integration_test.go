//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/privacy"
)

func newExportTestRuntime(t *testing.T) (*Runtime, accounts.Principal) {
	t.Helper()
	ctx := context.Background()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	runtime, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(runtime.Close)

	ticket := uuid.NewString()
	if err := runtime.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(map[string]any{
		"credential":      map[string]any{"provider": "apple", "proof": ticket},
		"age_confirmed":   true,
		"privacy_version": "2026-11",
		"terms_version":   "2026-11",
	})
	if err != nil {
		t.Fatal(err)
	}
	login := httptest.NewRecorder()
	loginRequest := httptest.NewRequest("POST", "/v1/auth/login", bytes.NewReader(body))
	loginRequest.Header.Set("Content-Type", "application/json")
	runtime.Router().ServeHTTP(login, loginRequest)
	if login.Code != 200 {
		t.Fatalf("login: %d %s", login.Code, login.Body.String())
	}
	var tokens app.Tokens
	if err := json.Unmarshal(login.Body.Bytes(), &tokens); err != nil {
		t.Fatal(err)
	}
	principal, err := runtime.Accounts.Parse(tokens.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	return runtime, principal
}

func TestExportCommitFailureDoesNotRevealArchive(t *testing.T) {
	ctx := context.Background()
	runtime, principal := newExportTestRuntime(t)

	mustExec := func(sql string) {
		t.Helper()
		if _, err := runtime.db.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	mustExec(`drop table if exists t35_export_commit_probe cascade`)
	mustExec(`drop function if exists t35_export_commit_probe_fail()`)
	mustExec(`create table t35_export_commit_probe(id integer primary key)`)
	mustExec(`create function t35_export_commit_probe_fail() returns trigger language plpgsql as $$
		begin
			raise exception 'injected export commit failure';
		end
	$$`)
	mustExec(`create constraint trigger t35_export_commit_probe_fail
		after insert on t35_export_commit_probe
		deferrable initially deferred
		for each row execute function t35_export_commit_probe_fail()`)
	t.Cleanup(func() {
		_, _ = runtime.db.Exec(context.Background(), `drop table if exists t35_export_commit_probe cascade`)
		_, _ = runtime.db.Exec(context.Background(), `drop function if exists t35_export_commit_probe_fail()`)
	})

	payload := make([]byte, 8<<20)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	probe := privacy.Module{
		Name:   "probe",
		Delete: func(context.Context, pgx.Tx, privacy.Deletion) error { return nil },
		Export: func(ctx context.Context, tx pgx.Tx, _ privacy.ExportRequest, emit privacy.Emit) error {
			if err := emit(map[string][]byte{"payload": payload}); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `insert into t35_export_commit_probe values(1)`)
			return err
		},
	}
	registry, err := privacy.NewRegistry([]string{"probe"}, probe)
	if err != nil {
		t.Fatal(err)
	}
	data := privacy.NewCoordinator(runtime.db, runtime.ledger, registry)
	business := appAPI{accounts: runtime.Accounts, data: data}

	engine := gin.New()
	engine.Use(requestMiddleware())
	engine.GET("/v1/me/export", func(c *gin.Context) {
		c.Set("principal", principal)
		business.ExportData(c)
	})
	server := httptest.NewServer(engine)
	defer server.Close()

	response, err := http.Get(server.URL + "/v1/me/export")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()

	if response.StatusCode != 200 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 1024))
		t.Fatalf("commit failure after streaming status = %d, want 200: %s", response.StatusCode, body)
	}
	if got := response.TransferEncoding; len(got) != 1 || got[0] != "chunked" {
		t.Fatalf("commit failure transport encoding = %v, want chunked", got)
	}
	body, readErr := io.ReadAll(response.Body)
	if readErr == nil {
		t.Fatalf("commit failure ended as a normal HTTP response (%d bytes)", len(body))
	}
	if !bytes.HasPrefix(body, []byte("PK\x03\x04")) {
		t.Fatalf("commit failure did not preserve a ZIP prefix: %q", body[:min(len(body), 16)])
	}
	if bytes.Contains(body, []byte(`"internal_error"`)) {
		t.Fatal("commit failure appended a JSON error to the ZIP prefix")
	}
	if _, err := zip.NewReader(bytes.NewReader(body), int64(len(body))); err == nil {
		t.Fatal("commit failure exposed a readable complete ZIP")
	}
}

func TestExportStreamsLargeIncompressibleEntryBeforeCommit(t *testing.T) {
	runtime, principal := newExportTestRuntime(t)

	payload := make([]byte, 8<<20)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	released := false
	releaseExport := func() {
		if !released {
			close(release)
			released = true
		}
	}
	defer releaseExport()

	stream := privacy.Module{
		Name:   "stream",
		Delete: func(context.Context, pgx.Tx, privacy.Deletion) error { return nil },
		Export: func(ctx context.Context, _ pgx.Tx, _ privacy.ExportRequest, emit privacy.Emit) error {
			if err := emit(map[string][]byte{"payload": payload}); err != nil {
				return err
			}
			select {
			case <-release:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		},
	}
	registry, err := privacy.NewRegistry([]string{"stream"}, stream)
	if err != nil {
		t.Fatal(err)
	}
	data := privacy.NewCoordinator(runtime.db, runtime.ledger, registry)
	business := appAPI{accounts: runtime.Accounts, data: data}

	engine := gin.New()
	engine.GET("/v1/me/export", func(c *gin.Context) {
		c.Set("principal", principal)
		business.ExportData(c)
	})
	server := httptest.NewServer(engine)
	defer server.Close()

	requestCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, "GET", server.URL+"/v1/me/export", nil)
	if err != nil {
		t.Fatal(err)
	}
	type responseResult struct {
		response *http.Response
		err      error
	}
	responses := make(chan responseResult, 1)
	go func() {
		response, err := http.DefaultClient.Do(request)
		responses <- responseResult{response: response, err: err}
	}()

	var response *http.Response
	select {
	case result := <-responses:
		if result.err != nil {
			t.Fatal(result.err)
		}
		response = result.response
	case <-time.After(8 * time.Second):
		releaseExport()
		t.Fatal("export response headers were withheld until transaction completion")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 1024))
		t.Fatalf("streaming export status = %d: %s", response.StatusCode, body)
	}
	if got := response.Header.Get("Content-Type"); got != "application/zip" {
		t.Fatalf("streaming export content type = %q", got)
	}

	first := make([]byte, 64<<10)
	firstRead := make(chan error, 1)
	go func() {
		_, err := io.ReadFull(response.Body, first)
		firstRead <- err
	}()
	select {
	case err := <-firstRead:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(8 * time.Second):
		releaseExport()
		t.Fatal("large archive prefix was not streamed before transaction completion")
	}
	if !bytes.HasPrefix(first, []byte("PK\x03\x04")) {
		t.Fatalf("stream did not start with a ZIP local header: %x", first[:min(len(first), 16)])
	}

	releaseExport()
	rest, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	archiveBytes := append(first, rest...)
	z, err := zip.NewReader(bytes.NewReader(archiveBytes), int64(len(archiveBytes)))
	if err != nil {
		t.Fatalf("streamed transport is not a readable ZIP: %v", err)
	}
	if len(z.File) != 2 || z.File[0].Name != "manifest.json" || z.File[1].Name != "stream.json" {
		t.Fatalf("unexpected streamed archive entries: %+v", z.File)
	}
	rc, err := z.File[1].Open()
	if err != nil {
		t.Fatal(err)
	}
	defer rc.Close()
	var exported []struct {
		Payload []byte `json:"payload"`
	}
	if err := json.NewDecoder(rc).Decode(&exported); err != nil {
		t.Fatal(err)
	}
	if len(exported) != 1 || !bytes.Equal(exported[0].Payload, payload) {
		t.Fatal("streamed large payload was truncated or changed")
	}
}
