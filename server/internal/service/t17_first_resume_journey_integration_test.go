//go:build integration && t17resume

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/privacy"
)

const t17AssessmentFixturePath = "testdata/t26_assessment.yaml"

const t17SubmitPath = "/v1/assessments"

// t17SubmitProbe records only method/path/count and response status for the
// formal submission route. A request is assigned to a stage when it enters the
// handler, so a response that finishes after a stage boundary cannot move to
// the other stage. Request bodies, headers and credentials are never inspected.
type t17SubmitProbe struct {
	mu       sync.Mutex
	stage    string
	entered  map[string]int
	statuses map[string][]int
}

func newT17SubmitProbe() *t17SubmitProbe {
	return &t17SubmitProbe{
		entered:  make(map[string]int),
		statuses: make(map[string][]int),
	}
}

func (p *t17SubmitProbe) setStage(stage string) {
	p.mu.Lock()
	p.stage = stage
	p.mu.Unlock()
}

func (p *t17SubmitProbe) enteredCount(stage string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.entered[stage]
}

func (p *t17SubmitProbe) stageStatuses(stage string) []int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]int(nil), p.statuses[stage]...)
}

func (p *t17SubmitProbe) wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != t17SubmitPath {
			next.ServeHTTP(w, r)
			return
		}
		p.mu.Lock()
		stage := p.stage
		p.entered[stage]++
		p.mu.Unlock()
		recorder := &t17StatusWriter{ResponseWriter: w}
		next.ServeHTTP(recorder, r)
		if recorder.status == 0 {
			recorder.status = http.StatusOK
		}
		// Attribute the response to the stage captured at entry.
		p.mu.Lock()
		p.statuses[stage] = append(p.statuses[stage], recorder.status)
		p.mu.Unlock()
	})
}

type t17StatusWriter struct {
	http.ResponseWriter
	status int
}

func (w *t17StatusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *t17StatusWriter) Write(body []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(body)
}

// T17 exercises the production assessment page twice in separate Flutter
// widget processes against the real local HTTP service. The first process
// stops after seven UI selections. The second restores the product's encrypted
// draft from the same account and finishes/submits from the page.
func TestT17FirstAssessmentResumeJourney(t *testing.T) {
	if os.Getenv("T17_DISPOSABLE") != "yes" {
		t.Skip("requires T17_DISPOSABLE=yes with disposable loopback PG17 and two Redis instances")
	}
	t.Setenv("WLEIS_CONFIG_PATH", t17AssessmentFixturePath)

	h := newPracticeWire(t)
	if err := h.s.Health(t.Context()); err != nil {
		t.Fatalf("disposable service is not healthy: %v", err)
	}

	appDir := filepath.Join("..", "..", "..", "app")
	for _, path := range []string{
		"tool/t17/resume_journey_test.dart",
		"tool/t26/transport.dart",
		".dart_tool/package_config.json",
	} {
		if info, err := os.Stat(filepath.Join(appDir, path)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("Flutter prerequisite missing: app/%s", path)
		}
	}
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}

	// A dedicated real HTTP entry for the two Flutter children. It counts only
	// the formal submission route; seeding and the Go readback use other paths
	// or other handlers, so neither can be mistaken for a Flutter submission.
	probe := newT17SubmitProbe()
	flutterAPI := h.startServer("listen_t17_flutter", probe.wrap(h.s.Router()), false)
	t.Cleanup(flutterAPI.Close)
	origin := flutterAPI.URL
	subject := uuid.New()
	directory := t.TempDir()
	secret := filepath.Join(directory, "synthetic-keystore.json")

	proof := uuid.NewString()
	ticketKey := "dev:ticket:apple:" + proof
	if err := h.s.cache.Set(t.Context(), ticketKey, subject.String(), 6*time.Minute).Err(); err != nil {
		t.Fatalf("could not issue the synthetic Apple proof: %v", err)
	}

	probe.setStage("first")
	t17Flutter(t, flutter, appDir, directory, secret, origin, map[string]string{
		"T17_RESUME_STAGE": "first",
		"T17_RESUME_APPLE": proof,
	}, "T17_STAGE first_stopped")
	if count := probe.enteredCount("first"); count != 0 {
		t.Fatalf("first Flutter process submitted the assessment before interruption: POST %s entered count=%d", t17SubmitPath, count)
	}
	if statuses := probe.stageStatuses("first"); len(statuses) != 0 {
		t.Fatalf("first Flutter process left submission responses: POST %s statuses=%v", t17SubmitPath, statuses)
	}
	t.Logf("T17 probe: first Flutter process POST %s entered count=0", t17SubmitPath)

	// The proof is one-use and the first process is gone; the second process
	// must restore the persisted account and draft without logging in again.
	probe.setStage("second")
	receipt := t17Flutter(t, flutter, appDir, directory, secret, origin, map[string]string{
		"T17_RESUME_STAGE": "second",
	}, "T17_STAGE second_complete")
	entered := probe.enteredCount("second")
	statuses := t17WaitStatuses(probe, "second", entered, 5*time.Second)
	if entered != 1 || len(statuses) != 1 || statuses[0] != http.StatusOK {
		t.Fatalf("second Flutter process must make exactly one successful submit: POST %s entered count=%d statuses=%v", t17SubmitPath, entered, statuses)
	}
	t.Logf("T17 probe: second Flutter process POST %s entered count=1 status=%d", t17SubmitPath, statuses[0])

	page, err := t17ParsePageScores(receipt)
	if err != nil {
		t.Fatalf("could not read the displayed assessment scores: %v", err)
	}
	t.Logf("T17 page: total=%d axes SEA=%d OEA=%d UOE=%d ROE=%d",
		page.Total, page.SEA, page.OEA, page.UOE, page.ROE)
	t17CheckSubmission(t, h, subject, page)
}

func t17Flutter(
	t *testing.T,
	flutter, appDir, directory, secret, origin string,
	extra map[string]string,
	marker string,
) string {
	t.Helper()
	env := make([]string, 0, len(extra)+16)
	for _, key := range []string{
		"PATH", "LANG", "LC_ALL", "HOME", "TMPDIR", "PUB_CACHE", "FLUTTER_ROOT",
		"CI", "FLUTTER_SUPPRESS_ANALYTICS", "DART_SUPPRESS_ANALYTICS",
		"FLUTTER_ALREADY_LOCKED", "XDG_CACHE_HOME", "XDG_CONFIG_HOME",
	} {
		if value, present := os.LookupEnv(key); present {
			env = append(env, key+"="+value)
		}
	}
	env = append(env,
		"T17_RESUME_DIR="+directory,
		"T17_RESUME_SECRET="+secret,
		"T17_RESUME_ORIGIN="+origin,
	)
	for key, value := range extra {
		env = append(env, key+"="+value)
	}

	ctx, cancel := context.WithTimeout(t.Context(), 4*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, flutter,
		"test", "--no-pub", "--reporter", "expanded", "tool/t17/resume_journey_test.dart")
	cmd.Dir = appDir
	cmd.Env = env
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 5 * time.Second

	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	err := cmd.Run()
	receipt := output.String()
	if err != nil {
		if ctx.Err() != nil {
			t.Fatalf("Flutter T17 journey terminated: %v", ctx.Err())
		}
		t.Fatalf("Flutter T17 journey failed at stage %s: %s", extra["T17_RESUME_STAGE"], t17Tail(receipt))
	}
	if !strings.Contains(receipt, marker) {
		t.Fatalf("Flutter T17 journey omitted its observation receipt: %s", t17Tail(receipt))
	}
	return receipt
}

func t17WaitStatuses(p *t17SubmitProbe, stage string, entered int, limit time.Duration) []int {
	deadline := time.Now().Add(limit)
	for {
		statuses := p.stageStatuses(stage)
		if len(statuses) >= entered || time.Now().After(deadline) {
			return statuses
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The tail is only used on failure. It carries widget-test diagnostics, never
// request credentials or page answer text.
func t17Tail(output string) string {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	if len(lines) > 80 {
		lines = lines[len(lines)-80:]
	}
	return strings.Join(lines, " | ")
}

type t17AssessmentRecord struct {
	assessment.Result
	Version string `json:"version"`
	Answers []int  `json:"answers"`
}

type t17PageScores struct {
	Total, SEA, OEA, UOE, ROE int
}

var t17PagePattern = regexp.MustCompile(`T17_PAGE total=(\d+) SEA=(\d+) OEA=(\d+) UOE=(\d+) ROE=(\d+)`)

// The Flutter child reads these numbers from the rendered result page: the
// total line and each radar axis row. Question text is never printed.
func t17ParsePageScores(receipt string) (t17PageScores, error) {
	match := t17PagePattern.FindStringSubmatch(receipt)
	if match == nil {
		return t17PageScores{}, fmt.Errorf("page score receipt is missing")
	}
	values := make([]int, 5)
	for i := range values {
		if _, err := fmt.Sscanf(match[i+1], "%d", &values[i]); err != nil {
			return t17PageScores{}, err
		}
	}
	return t17PageScores{
		Total: values[0], SEA: values[1], OEA: values[2], UOE: values[3], ROE: values[4],
	}, nil
}

func t17CheckSubmission(t *testing.T, h *practiceWire, subject uuid.UUID, displayed t17PageScores) {
	t.Helper()

	// A fresh one-use proof for the same synthetic subject returns the same
	// account over real HTTP.
	ticket := uuid.NewString()
	if err := h.s.cache.Set(t.Context(), "dev:ticket:apple:"+ticket, subject.String(), time.Minute).Err(); err != nil {
		t.Fatalf("could not issue the readback Apple proof: %v", err)
	}
	var tokens app.Tokens
	h.json("", "POST", "auth/login", map[string]any{
		"credential":    map[string]string{"provider": "apple", "proof": ticket},
		"age_confirmed": true,
		"terms_version": accounts.PolicyVersion, "privacy_version": accounts.PolicyVersion,
	}, 200, &tokens)

	var page app.ListAssessmentsResult
	h.json(tokens.AccessToken, "GET", "assessments?limit=1", nil, 200, &page)
	if len(page.Items) != 1 {
		t.Fatalf("expected exactly one assessment after the resumed submission, got %d", len(page.Items))
	}
	served := page.Items[0]

	// Selections are made by the product UI in question order.
	expected := []int{1, 2, 3, 4, 5, 6, 7, 1, 2, 3, 4, 5, 6, 7, 1, 2}
	want, err := h.s.Assessments.Bank.Score(h.s.Assessments.Bank.Version, expected)
	if err != nil {
		t.Fatalf("the synthetic answer sequence is invalid: %v", err)
	}
	if displayed.Total != want.Total.Display ||
		displayed.SEA != want.Dimensions["SEA"].Display ||
		displayed.OEA != want.Dimensions["OEA"].Display ||
		displayed.UOE != want.Dimensions["UOE"].Display ||
		displayed.ROE != want.Dimensions["ROE"].Display {
		t.Fatalf("numbers read from the result page do not match the submitted answers: page total=%d axes=%d/%d/%d/%d",
			displayed.Total, displayed.SEA, displayed.OEA, displayed.UOE, displayed.ROE)
	}

	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	var records []t17AssessmentRecord
	err = pgx.BeginTxFunc(ctx, h.s.db, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		return assessment.Hooks(h.s.Fields).Export(ctx, tx, privacy.ExportRequest{UserID: tokens.UserId}, func(record any) error {
			data, err := json.Marshal(record)
			if err != nil {
				return err
			}
			var row t17AssessmentRecord
			if err := json.Unmarshal(data, &row); err != nil {
				return err
			}
			records = append(records, row)
			return nil
		})
	})
	if err != nil {
		t.Fatalf("could not read the persisted assessment: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("expected exactly one persisted assessment, got %d", len(records))
	}
	stored := records[0]
	if stored.ID == uuid.Nil || stored.CompletedAt.IsZero() {
		t.Fatal("persisted assessment lacks an ID or completion time")
	}
	if stored.Version != h.s.Assessments.Bank.Version {
		t.Fatalf("persisted assessment has version %q", stored.Version)
	}
	if fmt.Sprint(stored.Answers) != fmt.Sprint(expected) {
		t.Fatalf("persisted answers do not match the UI selections: got %v", stored.Answers)
	}
	if stored.ID.String() != served.Id.String() {
		t.Fatalf("HTTP assessment ID does not match PostgreSQL")
	}
	if !t17SameDimension(stored.Total, want.Total) ||
		!t17SameDimension(t17ServedTotal(served), want.Total) {
		t.Fatal("served score does not match the score of the submitted answers")
	}
	for _, dim := range []string{"SEA", "OEA", "UOE", "ROE"} {
		if !t17SameDimension(stored.Dimensions[dim], want.Dimensions[dim]) {
			t.Fatalf("persisted %s dimension does not match the submitted answers", dim)
		}
		servedDim := t17ServedDimension(served, dim)
		if !t17SameDimension(servedDim, want.Dimensions[dim]) {
			t.Fatalf("HTTP %s dimension does not match the submitted answers", dim)
		}
	}
	t.Logf("T17 verified: one submitted assessment matches the resumed UI selections")
}

func t17SameDimension(got, want assessment.Dimension) bool {
	return got.Display == want.Display &&
		got.Level == want.Level &&
		math.Abs(got.Percent-want.Percent) < 0.001
}

func t17ServedDimension(a app.Assessment, dim string) assessment.Dimension {
	var d app.Dimension
	switch dim {
	case "SEA":
		d = a.Dimensions.SEA
	case "OEA":
		d = a.Dimensions.OEA
	case "UOE":
		d = a.Dimensions.UOE
	default:
		d = a.Dimensions.ROE
	}
	return t17ConvertDimension(d)
}

func t17ServedTotal(a app.Assessment) assessment.Dimension {
	return t17ConvertDimension(a.Total)
}

func t17ConvertDimension(d app.Dimension) assessment.Dimension {
	return assessment.Dimension{
		Mean:    float64(d.Mean),
		Percent: float64(d.Percent),
		Display: d.Display,
		Level:   string(d.Level),
	}
}
