//go:build integration && t26flutter

package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"hash"
	"io"
	"log"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9/logging"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
)

type t35ExportOwner struct {
	account, mark, deleteMark uuid.UUID
	marks                     []app.Mark
	ticket, scene             string
	assessment                t35ExportAssessment
	seedPlanDay               string
}

func TestT35FormalAccountExportJourney(t *testing.T) {
	if os.Getenv("T35_EXPORT_DISPOSABLE") != "yes" {
		t.Skip("use app/tool/t35-privacy/export_journey.py to start disposable services")
	}
	t.Log("BEGIN(service.runtime)")
	if os.Getenv("APP_ENV") != "development" || os.Getenv("PAYMENT_MODE") != "disabled" {
		t.Fatal("journey requires development providers and disabled payments")
	}
	pgURL := os.Getenv("DATABASE_URL")
	pg, db := t26LoopbackEndpoint(t, "DATABASE_URL", pgURL, "postgres", "postgresql")
	_, cache := t26LoopbackEndpoint(t, "REDIS_URL", os.Getenv("REDIS_URL"), "redis")
	_, ledger := t26LoopbackEndpoint(t, "LEDGER_URL", os.Getenv("LEDGER_URL"), "redis")
	if db == cache || db == ledger || cache == ledger || pg.User.Username() == "" ||
		pg.Path != "/postgres" || pg.RawQuery != "sslmode=disable&connect_timeout=5" {
		t.Fatal("expected three independent disposable endpoints")
	}
	scratch := t.TempDir()
	t.Setenv("PGPASSFILE", filepath.Join(scratch, "no-pgpass"))
	t.Setenv("PGSERVICEFILE", filepath.Join(scratch, "no-pgservice"))
	t.Setenv("PGSERVICE", "")
	t.Setenv("PGPASSWORD", "")
	t.Setenv("WLEIS_CONFIG_PATH", t26AssessmentFixturePath)
	// The runner selects only this test in its own process and drops raw logs.
	logging.Disable()
	slog.SetDefault(slog.New(slog.DiscardHandler))
	t26RequirePG17(t, pgURL)
	ctx, cancel := context.WithTimeout(t.Context(), 6*time.Minute)
	defer cancel()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal("could not load disposable runtime config")
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal("could not start production runtime with disposable stores")
	}
	t.Cleanup(s.Close)
	if s.Health(ctx) != nil {
		t.Fatal("production runtime health check failed")
	}
	router := s.Router()
	t.Log("PASS(service.runtime)")

	t.Log("BEGIN(service.seed)")
	a := t35SeedExportOwner(t, ctx, s, router, "work", []string{"work", "work"}, []int{1, 1, 1, 1, 7, 7, 7, 7, 5, 6, 5, 6, 1, 1, 1, 2})
	b := t35SeedExportOwner(t, ctx, s, router, "partner", []string{"partner"}, []int{6, 6, 6, 6, 2, 2, 2, 2, 3, 3, 3, 3, 7, 7, 7, 7})
	if a.account == b.account || a.mark == b.mark || a.mark == a.deleteMark || a.deleteMark == b.mark {
		t.Fatal("expected independent accounts and three distinct marks")
	}
	if len(a.marks) != 2 || len(b.marks) != 1 {
		t.Fatal("expected account A to own two marks and account B to own one")
	}
	if a.assessment.ID == b.assessment.ID || slices.Equal(a.assessment.Answers, b.assessment.Answers) || a.assessment.Total == b.assessment.Total {
		t.Fatal("expected independent assessments with different answers and scores")
	}
	t.Log("PASS(service.seed)")

	observer := &t35ExportObserver{router: router, accounts: s.Accounts}
	api := httptest.NewUnstartedServer(observer)
	api.Config.ErrorLog = log.New(io.Discard, "", 0)
	api.Start()
	t.Cleanup(api.Close)
	t.Log("BEGIN(page.startup)")
	t35RunExportFlutter(t, ctx, api.URL, scratch, a, b)

	t.Log("BEGIN(receive.wire-and-inventory)")
	observed := observer.snapshot()
	if len(observed) != 4 {
		t.Fatal("expected exactly four real export responses")
	}
	aBefore := t35ReadDeliveredZIP(t, scratch, "a-before", a.account, observed[0])
	aAfter := t35ReadDeliveredZIP(t, scratch, "a-after", a.account, observed[1])
	bBefore := t35ReadDeliveredZIP(t, scratch, "b-before", b.account, observed[2])
	bAfter := t35ReadDeliveredZIP(t, scratch, "b-after", b.account, observed[3])
	t.Log("PASS(receive.wire-and-inventory)")

	t.Log("BEGIN(receive.selected-mark-diff)")
	t35CheckExportOwnerBeforeDelete(t, aBefore, a, b)
	t35CheckExportOwner(t, aAfter, a, b)
	t35CheckSelectedMarkDeletion(t, aBefore, aAfter, a)
	t.Log("PASS(receive.selected-mark-diff)")

	t.Log("BEGIN(receive.account-isolation)")
	t35CheckExportOwner(t, bBefore, b, a)
	t35CheckExportOwner(t, bAfter, b, a)
	t35CheckPartitionsIdentical(t, bBefore, bAfter)
	t.Log("PASS(receive.account-isolation)")
}

func t35SeedExportOwner(t *testing.T, ctx context.Context, s *Runtime, router http.Handler, scene string, markScenes []string, answers []int) t35ExportOwner {
	t.Helper()
	request := func(method, path, token string, input, output any) {
		t.Helper()
		body, err := json.Marshal(input)
		if err != nil {
			t.Fatal("could not encode synthetic seed")
		}
		req := httptest.NewRequestWithContext(ctx, method, "/v1/"+path, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		res := httptest.NewRecorder()
		router.ServeHTTP(res, req)
		if res.Code != http.StatusOK {
			t.Fatalf("seed route %s %s returned HTTP %d", method, path, res.Code)
		}
		if output != nil && json.Unmarshal(res.Body.Bytes(), output) != nil {
			t.Fatalf("seed route %s %s returned invalid JSON", method, path)
		}
	}
	subject := uuid.NewString()
	issueTicket := func() string {
		t.Helper()
		const ttl = 6 * time.Minute
		ticket := uuid.NewString()
		if s.cache.Set(ctx, "dev:ticket:apple:"+ticket, subject, ttl).Err() != nil {
			t.Fatal("could not issue synthetic sign-in ticket")
		}
		return ticket
	}
	var session app.Tokens
	request(http.MethodPost, "auth/login", "", map[string]any{
		"credential":    map[string]string{"provider": "apple", "proof": issueTicket()},
		"age_confirmed": true, "privacy_version": accounts.PolicyVersion, "terms_version": accounts.PolicyVersion,
	}, &session)
	for _, purpose := range []string{"assessment", "manual_mark"} {
		request(http.MethodPut, "me/consents/"+purpose, session.AccessToken,
			map[string]any{"version": accounts.PolicyVersion, "granted": true}, nil)
	}
	// A completed assessment lets the formal startup resolve to the home tabs.
	var bank app.GetInstrumentResult
	request(http.MethodGet, "assessments/instrument", session.AccessToken, nil, &bank)
	var submitted assessment.Result
	request(http.MethodPost, "assessments", session.AccessToken, app.SubmitAssessmentInput{
		Version: bank.Version, Answers: answers,
	}, &submitted)
	var history assessment.Page
	request(http.MethodGet, "assessments", session.AccessToken, nil, &history)
	if bank.Version == "" || submitted.ID == uuid.Nil || submitted.CompletedAt.IsZero() || submitted.NextEligibleAt.IsZero() ||
		len(submitted.Dimensions) != 4 || len(history.Items) != 1 || history.Next != nil || !reflect.DeepEqual(submitted, history.Items[0]) {
		t.Fatal("owner's public assessment history must contain exactly the submitted result")
	}
	// Read the assessment event's existing projection without generating a plan on demand.
	var seedPlanDay string
	if s.db.QueryRow(ctx, `select plan_day::text from daily_plans where user_id=$1 and assessment_id=$2`, session.UserId, submitted.ID).Scan(&seedPlanDay) != nil || seedPlanDay == "" {
		t.Fatal("expected a persisted plan derived from the owner's assessment")
	}
	marks := make([]app.Mark, 0, len(markScenes))
	seen := make(map[uuid.UUID]bool, len(markScenes))
	for _, markScene := range markScenes {
		var mark app.Mark
		request(http.MethodPost, "marks", session.AccessToken, map[string]any{
			"request_id": uuid.New(), "scene": markScene,
		}, &mark)
		var persisted bool
		if mark.Id == uuid.Nil || seen[mark.Id] || mark.Scene == nil || *mark.Scene != markScene ||
			s.db.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, session.UserId, mark.Id).Scan(&persisted) != nil || !persisted {
			t.Fatal("public marks API did not persist the owner's synthetic mark")
		}
		seen[mark.Id] = true
		marks = append(marks, mark)
		// The public API coalesces marks created within one minute. Keep both
		// creations real while placing the prior mark outside that dedupe window.
		if len(marks) < len(markScenes) {
			if _, err := s.db.Exec(ctx, `update manual_marks set accepted_at=clock_timestamp()-interval '2 minutes' where user_id=$1`, session.UserId); err != nil {
				t.Fatal("could not age the prior synthetic mark outside the public dedupe window")
			}
		}
	}
	if session.UserId == uuid.Nil || len(marks) == 0 {
		t.Fatal("synthetic owner does not have a persisted account and mark")
	}
	owner := t35ExportOwner{
		account: session.UserId, mark: marks[0].Id, marks: marks, scene: scene, ticket: issueTicket(), seedPlanDay: seedPlanDay,
		assessment: t35ExportAssessment{Result: history.Items[0], Version: bank.Version, Answers: answers},
	}
	if len(marks) > 1 {
		owner.deleteMark = marks[1].Id
	}
	return owner
}

type t35ExportObservation struct {
	account uuid.UUID
	valid   bool
	digest  [sha256.Size]byte
	size    int
}

// Observe the real response without buffering it or modifying request headers,
// status, or body. The SHA-256 is compared with bytes read by the receiver.
type t35ExportObserver struct {
	router   http.Handler
	accounts *accounts.Service
	mu       sync.Mutex
	observed []t35ExportObservation
}

func (o *t35ExportObserver) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/me/export" {
		o.router.ServeHTTP(w, r)
		return
	}
	writer := &t35ExportWriter{ResponseWriter: w, digest: sha256.New(), status: http.StatusOK}
	completed := false
	defer func() {
		token, bearer := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		p, err := o.accounts.Parse(token)
		valid := completed && bearer && err == nil && r.Method == http.MethodGet && r.URL.RawQuery == "" &&
			r.Header.Get("Accept") == "application/zip" && writer.status == http.StatusOK &&
			w.Header().Get("Content-Type") == "application/zip" &&
			w.Header().Get("Content-Disposition") == `attachment; filename="high-eq-export.zip"`
		o.mu.Lock()
		o.observed = append(o.observed, t35ExportObservation{p.User, valid, [sha256.Size]byte(writer.digest.Sum(nil)), writer.size})
		o.mu.Unlock()
	}()
	o.router.ServeHTTP(writer, r)
	completed = true
}

func (o *t35ExportObserver) snapshot() []t35ExportObservation {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]t35ExportObservation(nil), o.observed...)
}

type t35ExportWriter struct {
	http.ResponseWriter
	digest hash.Hash
	status int
	size   int
}

func (w *t35ExportWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *t35ExportWriter) Flush() { _ = http.NewResponseController(w.ResponseWriter).Flush() }

func (w *t35ExportWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *t35ExportWriter) Write(body []byte) (int, error) {
	n, err := w.ResponseWriter.Write(body)
	_, _ = w.digest.Write(body[:n])
	w.size += n
	return n, err
}
