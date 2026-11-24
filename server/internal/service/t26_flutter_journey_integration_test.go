//go:build integration && t26flutter

package service

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/netip"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/redis/go-redis/v9/logging"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/training"
)

const t26AssessmentFixturePath = "testdata/t26_assessment.yaml"
const t26FixtureChildTest = "T26_FIXTURE_CHILD_TEST"

func TestT26FlutterAssessmentFixture(t *testing.T) {
	bank, err := assessment.Load(t26AssessmentFixturePath)
	if err != nil {
		t.Fatal("could not load the synthetic assessment fixture")
	}
	if bank.Version != "t26-synthetic-1" || bank.Options[4] != "有点同意" {
		t.Fatal("assessment fixture does not match the expected test version and answer option")
	}
}

func TestT26NewUserPlanFlutter(t *testing.T) {
	if os.Getenv("T19_DISPOSABLE") != "yes" {
		t.Skip("requires T19_DISPOSABLE=yes with disposable loopback PG17 and two Redis instances")
	}
	t26RunFixture(t, t26NewUserPlanFlutter)
}

func t26RunFixture(t *testing.T, run func(*testing.T)) {
	t.Helper()
	name := t.Name()
	if os.Getenv(t26FixtureChildTest) == name {
		// go-redis has a process-wide logger. Set it before any client runs
		// and keep the policy in this single-test process through cleanup.
		logging.Disable()
		slog.SetDefault(slog.New(slog.DiscardHandler))
		run(t)
		return
	}

	bin, err := os.Executable()
	if err != nil {
		t.Fatal("could not locate the Go test binary")
	}
	ctx := t.Context()
	if deadline, ok := t.Deadline(); ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, deadline)
		defer cancel()
	}
	cmd := exec.CommandContext(ctx, bin, "-test.run=^"+regexp.QuoteMeta(name)+"$", "-test.v")
	cmd.Env = append(cmd.Environ(), t26FixtureChildTest+"="+name)
	out, err := cmd.CombinedOutput()

	// Keep the receipt's original source location and let the outer Go test
	// emit its own run and result events for this exact test name.
	passed := false
	for line := range strings.SplitSeq(string(out), "\n") {
		switch {
		case line == "", line == "=== RUN   "+name, line == "PASS", line == "FAIL":
		case strings.HasPrefix(line, "--- PASS: "+name+" ("):
			passed = true
		case strings.HasPrefix(line, "--- FAIL: "+name+" ("), strings.HasPrefix(line, "--- SKIP: "+name+" ("):
		default:
			fmt.Fprintln(t.Output(), strings.TrimPrefix(line, "    "))
		}
	}
	if err != nil || !passed {
		t.Fatal("T26 fixture process did not pass")
	}
}

func t26NewUserPlanFlutter(t *testing.T) {
	if os.Getenv("APP_ENV") != "development" {
		t.Fatal("requires APP_ENV=development")
	}
	pgURL := os.Getenv("DATABASE_URL")
	postgres, _ := t26LoopbackEndpoint(t, "DATABASE_URL", pgURL, "postgres", "postgresql")
	query, err := url.ParseQuery(postgres.RawQuery)
	if err != nil || len(query) > 1 || (len(query) == 1 && query.Get("sslmode") != "disable") {
		t.Fatal("DATABASE_URL accepts only the optional sslmode=disable query parameter")
	}
	if strings.Trim(postgres.Path, "/") == "" || postgres.User.Username() == "" {
		t.Fatal("DATABASE_URL must name the disposable database and its user")
	}
	_, cache := t26LoopbackEndpoint(t, "REDIS_URL", os.Getenv("REDIS_URL"), "redis")
	_, ledger := t26LoopbackEndpoint(t, "LEDGER_URL", os.Getenv("LEDGER_URL"), "redis")
	if cache == ledger {
		t.Fatal("REDIS_URL and LEDGER_URL must identify separate instances")
	}

	appDir := filepath.Join("..", "..", "..", "app")
	const journey = "tool/t26/plan_journey_test.dart"
	for _, path := range []string{journey, ".dart_tool/package_config.json"} {
		if info, err := os.Stat(filepath.Join(appDir, path)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("Flutter prerequisite missing: app/%s", path)
		}
	}
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}

	scratch := t.TempDir()
	// The URL pins the host, port, database and user. Keep pgx away from
	// per-user service/pass files and use plain TCP to the disposable server.
	t.Setenv("PGSERVICE", "")
	t.Setenv("PGPASSWORD", "")
	t.Setenv("PGPASSFILE", filepath.Join(scratch, "pgpass"))
	t.Setenv("PGSSLMODE", "disable")
	t.Setenv("PAYMENT_MODE", "disabled")
	t.Setenv("WLEIS_CONFIG_PATH", t26AssessmentFixturePath)
	t26RequirePG17(t, pgURL)

	h := newPracticeWireWithFailureReporter(t, t26ReportFixtureFailure)
	var users int
	h.mustAt("check_empty_users", h.s.db.QueryRow(h.ctx, `select count(*) from users`).Scan(&users))
	if users != 0 {
		t.Fatal("the disposable database must start without users")
	}
	subject := uuid.NewString()
	proof := uuid.NewString()
	ticketKey := "dev:ticket:apple:" + proof
	h.mustAt("issue_apple_proof", h.s.cache.Set(t.Context(), ticketKey, subject, time.Minute).Err())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.s.cache.Del(ctx, ticketKey).Err()
	})
	// Let the one-use proof survive a cold Flutter test compile, bounded by
	// the child deadline and cleanup above.
	const childTimeout = 3 * time.Minute
	valid, err := h.s.cache.Expire(t.Context(), ticketKey, childTimeout+5*time.Second).Result()
	if err != nil || !valid {
		t.Fatal("could not set the synthetic Apple proof lifetime")
	}
	ctx, cancel := context.WithTimeout(t.Context(), childTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, flutter, "test", "--no-pub", "--reporter", "expanded", journey)
	cmd.Dir = appDir
	// Give Flutter a chance to stop its test runner before the forced kill.
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 5 * time.Second
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + scratch,
		"TMPDIR=" + scratch,
		"CI=true",
		"FLUTTER_SUPPRESS_ANALYTICS=true",
		"DART_SUPPRESS_ANALYTICS=true",
		"T26_ORIGIN=" + h.api.URL,
		"T26_LOGIN_PROOF=" + proof,
	}
	// Keep diagnostics in the child. The receipt accepts only fixed markers
	// from stdout and stderr remains disconnected.
	var receipt t26FlutterStageReceipt
	cmd.Stdout = &receipt
	if err := cmd.Run(); err != nil {
		if receipt.stage() == "chat" || receipt.stage() == "score" {
			t26LogFailureCounts(t, h.s, subject)
		}
		if ctx.Err() != nil {
			t.Fatalf("Flutter T26 journey terminated: %v (%s)", ctx.Err(), receipt.failureLocation())
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			t.Fatalf("Flutter T26 journey failed (exit=%d, %s)", exitErr.ExitCode(), receipt.failureLocation())
		}
		t.Fatalf("Could not run Flutter T26 journey (%s)", receipt.failureLocation())
	}
	if !receipt.completed() {
		t26LogFailureCounts(t, h.s, subject)
		t.Fatalf("Flutter T26 journey exited without a complete receipt (%s)", receipt.failureLocation())
	}
	t.Logf("Flutter T26 journey exited successfully (%s)", receipt.failureLocation())
	t26CheckReadback(t, h, subject)
}

func t26LoopbackEndpoint(t *testing.T, name, raw string, schemes ...string) (*url.URL, netip.AddrPort) {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil || u.Fragment != "" {
		t.Fatalf("%s must be a disposable loopback URL", name)
	}
	addr, addrErr := netip.ParseAddr(u.Hostname())
	port, portErr := strconv.ParseUint(u.Port(), 10, 16)
	if !slices.Contains(schemes, u.Scheme) || addrErr != nil || !addr.Unmap().IsLoopback() || addr.Zone() != "" || portErr != nil || port == 0 {
		t.Fatalf("%s must use a literal loopback IP and explicit port", name)
	}
	return u, netip.AddrPortFrom(addr.Unmap(), uint16(port))
}

func t26RequirePG17(t *testing.T, pgURL string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, pgURL)
	if err != nil {
		t.Fatal("could not connect to the disposable PostgreSQL instance")
	}
	defer conn.Close(ctx)
	var major int
	if err := conn.QueryRow(ctx, `select current_setting('server_version_num')::int / 10000`).Scan(&major); err != nil || major != 17 {
		t.Fatal("T26 requires PostgreSQL 17 before fixture setup")
	}
	var migrated, empty bool
	if err := conn.QueryRow(ctx, `select to_regclass('users') is not null`).Scan(&migrated); err != nil {
		t.Fatal("could not inspect the disposable PostgreSQL schema")
	}
	if migrated {
		if err := conn.QueryRow(ctx, `select not exists (select 1 from users)`).Scan(&empty); err != nil || !empty {
			t.Fatal("the disposable database must start without users")
		}
	}
}

func t26CheckReadback(t *testing.T, h *practiceWire, subject string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	stage := "begin"
	err := pgx.BeginTxFunc(ctx, h.s.db, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		stage = "owner"
		owner, err := t26SyntheticOwner(ctx, tx, h.s, subject)
		if err != nil {
			return err
		}
		stage = "assessment"
		assessmentID, err := t26CheckAssessment(ctx, tx, h.s, owner)
		if err != nil {
			return err
		}
		stage = "practice"
		practice, err := t26CheckPractice(ctx, tx, h, owner)
		if err != nil {
			return err
		}
		stage = "plan"
		if err := t26CheckPlan(ctx, tx, h.s, owner, assessmentID, practice); err != nil {
			return err
		}
		stage = "commit"
		return nil
	})
	if err != nil {
		t26LogFailureCounts(t, h.s, subject)
		t26ReportReadbackFailure(t, stage, err)
	}
}

func t26ReportFixtureFailure(t *testing.T, stage string, err error) {
	t.Helper()
	t.Fatalf("T26 fixture: stage=%s error=%s", stage, t26FailureType(err))
}

// Readback assertions are assembled only from fixture literals and counts.
// Other errors may include arbitrary service or driver diagnostics.
type t26ReadbackAssertion string

func (e t26ReadbackAssertion) Error() string { return string(e) }

func t26ReportReadbackFailure(t *testing.T, stage string, err error) {
	t.Helper()
	var assertion t26ReadbackAssertion
	if errors.As(err, &assertion) {
		t.Fatalf("T26 readback: stage=%s error=assertion (%s)", stage, assertion)
	}
	t.Fatalf("T26 readback: stage=%s error=%s", stage, t26FailureType(err))
}

func t26FailureType(err error) string {
	var connectErr *pgconn.ConnectError
	var pgErr *pgconn.PgError
	var netErr *net.OpError
	switch {
	case errors.Is(err, context.Canceled):
		return "canceled"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	case errors.As(err, &connectErr), errors.As(err, &netErr):
		return "connection"
	case errors.As(err, &pgErr):
		return "database"
	default:
		return "operation"
	}
}

func t26SyntheticOwner(ctx context.Context, tx pgx.Tx, s *Runtime, subject string) (privacy.ExportRequest, error) {
	rows, err := tx.Query(ctx, `select id from users`)
	if err != nil {
		return privacy.ExportRequest{}, err
	}
	user, err := pgx.CollectExactlyOneRow(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) || errors.Is(err, pgx.ErrTooManyRows) {
			return privacy.ExportRequest{}, t26ReadbackAssertion("expected exactly one new user")
		}
		return privacy.ExportRequest{}, err
	}
	owner := privacy.ExportRequest{UserID: user}
	identityFound := false
	err = accounts.Hooks(s.Fields).Export(ctx, tx, owner, func(record any) error {
		if data, ok := record.(map[string]any); ok && data["kind"] == "identity" && data["provider"] == "apple" && data["subject"] == subject {
			identityFound = true
		}
		return nil
	})
	if err != nil {
		return privacy.ExportRequest{}, err
	}
	if !identityFound {
		return privacy.ExportRequest{}, t26ReadbackAssertion("the created user does not own the synthetic Apple identity")
	}
	return owner, nil
}

func t26LogFailureCounts(t *testing.T, s *Runtime, subject string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	var sessions, savedTurns, scores int
	err := pgx.BeginTxFunc(ctx, s.db, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		owner, err := t26SyntheticOwner(ctx, tx, s, subject)
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `with sessions as (
			select id from activities where user_id=$1 and kind='practice'
		) select
			(select count(*) from sessions),
			(select count(*) from sessions s
			 join practice_messages u on u.activity_id=s.id and u.role='user'
			 join practice_messages a on a.activity_id=s.id and a.role='assistant'
			  and a.client_message_id=u.client_message_id and a.seq=u.seq+1),
			(select count(*) from scores sc join sessions s on s.id=sc.activity_id)`, owner.UserID).
			Scan(&sessions, &savedTurns, &scores)
	})
	if err == nil {
		t.Logf("T26 synthetic readback: sessions=%d saved_turns=%d scores=%d", sessions, savedTurns, scores)
	}
}

func t26CheckAssessment(ctx context.Context, tx pgx.Tx, s *Runtime, owner privacy.ExportRequest) (uuid.UUID, error) {
	var id uuid.UUID
	err := assessment.Hooks(s.Fields).Export(ctx, tx, owner, func(record any) error {
		entry, ok := record.(struct {
			assessment.Result
			Version string `json:"version"`
			Answers []int  `json:"answers"`
		})
		if !ok || entry.ID == uuid.Nil || id != uuid.Nil || len(entry.Answers) != 16 {
			return t26ReadbackAssertion("expected one persisted 16-answer assessment")
		}
		want, err := s.Assessments.Bank.Score(entry.Version, entry.Answers)
		if err != nil || !reflect.DeepEqual(entry.Scores, want) || entry.CompletedAt.IsZero() {
			return t26ReadbackAssertion("persisted assessment result does not match its 16 answers")
		}
		id = entry.ID
		return nil
	})
	if err != nil {
		return uuid.Nil, err
	}
	if id == uuid.Nil {
		return uuid.Nil, t26ReadbackAssertion("assessment missing after Flutter journey")
	}
	return id, nil
}

type t26PracticeRecord = struct {
	training.Session
	Input  training.Input `json:"setup"`
	Source uuid.UUID      `json:"source_id"`
}

func t26CheckPractice(ctx context.Context, tx pgx.Tx, h *practiceWire, owner privacy.ExportRequest) (t26PracticeRecord, error) {
	var practice t26PracticeRecord
	err := training.Hooks(h.s.Fields).Export(ctx, tx, owner, func(record any) error {
		entry, ok := record.(t26PracticeRecord)
		if !ok || entry.ID == uuid.Nil || practice.ID != uuid.Nil {
			return t26ReadbackAssertion("expected one persisted practice session")
		}
		practice = entry
		return nil
	})
	if err != nil {
		return practice, err
	}
	if practice.ID == uuid.Nil || practice.Status != "complete" || practice.CompletedAt == nil || practice.Mode != "full_session" ||
		practice.Level == nil || *practice.Level == uuid.Nil || practice.Input.Level == nil || *practice.Input.Level != *practice.Level {
		return practice, t26ReadbackAssertion("expected a completed full-session practice pinned to a catalog level")
	}
	turns := len(practice.Messages) / 2
	if turns == 0 || len(practice.Messages)%2 != 0 || h.generations.Load() != int32(turns) {
		return practice, t26ReadbackAssertion("saved SSE turns do not match the scripted generations")
	}
	for i := 0; i < len(practice.Messages); i += 2 {
		user, assistant := practice.Messages[i], practice.Messages[i+1]
		if user.Role != "user" || assistant.Role != "assistant" ||
			user.Seq != i+1 || assistant.Seq != i+2 ||
			user.ClientMessageId == uuid.Nil || user.ClientMessageId != assistant.ClientMessageId ||
			strings.TrimSpace(user.Text) == "" || assistant.Text != "合成甲。合成乙。" {
			return practice, t26ReadbackAssertion(fmt.Sprintf("invalid persisted SSE turn %d", i/2+1))
		}
	}
	if practice.Result == nil || practice.Result.Progress != nil || practice.Result.Score == nil {
		return practice, t26ReadbackAssertion("expected a persisted full-session score")
	}
	score := practice.Result.Score
	if practice.Source == uuid.Nil || score.ID != practice.Source || score.NVC.Total != 100 ||
		score.TargetTurn == nil || *score.TargetTurn != turns || h.grades.Load() != 1 {
		return practice, t26ReadbackAssertion("persisted practice score does not match one scripted grading round")
	}
	if practice.Settlement.Status != "charged" || practice.Settlement.Net != 1 || practice.Settlement.Day == nil {
		return practice, t26ReadbackAssertion("practice settlement does not show one charge")
	}
	var ledgerRows, dailyUsed, scoreLinks int
	err = tx.QueryRow(ctx, `select
		(select count(*) from quota_ledger where activity_id=$1 and refunded_at is null and charged_day::text=$4),
		(select coalesce(sum(used),0) from daily_quota_usage where user_id=$2 and feature='practice'),
		(select count(*) from ai_calls where activity_id=$1 and task='scoring' and outcome='ok' and score_id=$3)`,
		practice.ID, owner.UserID, score.ID, *practice.Settlement.Day).Scan(&ledgerRows, &dailyUsed, &scoreLinks)
	if err != nil {
		return practice, err
	}
	if ledgerRows != 1 || dailyUsed != 1 || scoreLinks != 1 {
		return practice, t26ReadbackAssertion(fmt.Sprintf("want one charge and one linked score, got ledger=%d daily=%d score links=%d", ledgerRows, dailyUsed, scoreLinks))
	}
	return practice, nil
}

func t26CheckPlan(ctx context.Context, tx pgx.Tx, s *Runtime, owner privacy.ExportRequest, assessmentID uuid.UUID, practice t26PracticeRecord) error {
	var completedLevel, projectedScore int
	err := growth.Hooks(s.Fields).Export(ctx, tx, owner, func(record any) error {
		switch entry := record.(type) {
		case growth.PlanExportRecord:
			if entry.AssessmentID == nil || *entry.AssessmentID != assessmentID || entry.CompletedAt == nil {
				break
			}
			for _, item := range entry.Items {
				if item.Kind == growth.KindLevel && item.ContentID == *practice.Level && item.ID != uuid.Nil && item.Completed {
					completedLevel++
				}
			}
		case growth.ExportRecord:
			if entry.SourceID == practice.Source && entry.Kind == "practice" && entry.NVC.Total == practice.Result.Score.NVC.Total {
				projectedScore++
			}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if completedLevel != 1 || projectedScore != 1 {
		return t26ReadbackAssertion(fmt.Sprintf("want one completed assessment plan level and one projected practice score, got %d and %d", completedLevel, projectedScore))
	}
	return nil
}
