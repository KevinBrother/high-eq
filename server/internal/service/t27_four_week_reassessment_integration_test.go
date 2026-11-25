//go:build integration && t27reassess

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9/logging"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/privacy"
)

// Two synthetic answer sheets from the in-repo T26 bank. The first is weakest
// on SEA (observation), the second on ROE (request); every dimension differs so
// the radar comparison cannot pass by accident, and the first sheet keeps OEA
// and UOE apart (17 vs 83) so swapping those axes cannot pass either.
var (
	t27FirstAnswers  = []int{1, 1, 1, 1, 2, 2, 2, 2, 6, 6, 6, 6, 7, 7, 7, 7}
	t27SecondAnswers = []int{7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 1, 1, 1, 1}

	t27ObservationLevel = uuid.MustParse("19000000-0000-4000-8000-000000000001")
	t27RequestLevels    = map[uuid.UUID]bool{
		uuid.MustParse("19000000-0000-4000-8000-000000000004"): true,
		uuid.MustParse("19000000-0000-4000-8000-000000000010"): true,
	}
)

// TestT27FourWeekReassessmentJourney drives one synthetic free account through
// the real growth page retest entry. The first assessment is submitted through
// the formal HTTP API and then backdated 28 days as an isolated history
// fixture; its same-local-day plan stays untouched. The second assessment is
// answered in the real Flutter assessment page. A formal PATCH /me timezone
// change moves the account to the next legal local day, which is the product's
// own unit for a daily plan, so the regenerated plan can be compared without
// touching the system clock.
func TestT27FourWeekReassessmentJourney(t *testing.T) {
	if os.Getenv("T27_DISPOSABLE") != "yes" || os.Getenv("T19_DISPOSABLE") != "yes" {
		t.Skip("requires T27_DISPOSABLE=yes and T19_DISPOSABLE=yes with disposable loopback PG17 and two Redis instances")
	}
	logging.Disable()
	slog.SetDefault(slog.New(slog.DiscardHandler))
	if os.Getenv("APP_ENV") != "development" {
		t.Fatal("requires APP_ENV=development")
	}
	// Resolve the app from the repository checkout, not from a card or SDK
	// directory. Go test runs with the package directory as the working
	// directory, so this is <repo>/server/internal/service.
	appDir := filepath.Join("..", "..", "..", "app")
	const journey = "tool/t27/four_week_reassessment_journey_test.dart"
	for _, path := range []string{journey, ".dart_tool/package_config.json"} {
		if info, err := os.Stat(filepath.Join(appDir, path)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("Flutter prerequisite missing: app/%s", path)
		}
	}
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}

	h := newPracticeWireWithFailureReporter(t, t27FixtureFailure)

	now := time.Now()
	zone1, zone2, fixtureDay, margin := t27ZonePair(t, now)
	t.Logf("fixture zones: %s -> %s (local day %s, %.1f h before midnight)", zone1, zone2, fixtureDay, margin.Hours())

	subject := uuid.NewString()
	var tokens app.Tokens
	fixtureProof := uuid.NewString()
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+fixtureProof, subject, 10*time.Minute).Err())
	h.json("", "POST", "auth/login", map[string]any{
		"credential":      map[string]string{"provider": "apple", "proof": fixtureProof},
		"age_confirmed":   true,
		"terms_version":   accounts.PolicyVersion,
		"privacy_version": accounts.PolicyVersion,
	}, 200, &tokens)
	user := uuid.UUID(tokens.UserId)
	token := tokens.AccessToken
	h.json(token, "PATCH", "me", map[string]any{"timezone": zone1}, 200, nil)
	for _, purpose := range []string{"assessment", "practice"} {
		h.json(token, "PUT", "me/consents/"+purpose, map[string]any{
			"version": accounts.PolicyVersion, "granted": true,
		}, 200, nil)
	}
	var bank app.GetInstrumentResult
	h.json(token, "GET", "assessments/instrument", nil, 200, &bank)
	if bank.Version != "t26-synthetic-1" {
		t.Fatalf("fixture bank version %q is not the in-repo synthetic bank", bank.Version)
	}
	var first struct {
		ID uuid.UUID `json:"id"`
	}
	h.json(token, "POST", "assessments", map[string]any{
		"version": bank.Version, "answers": t27FirstAnswers,
	}, 200, &first)
	if first.ID == uuid.Nil {
		t.Fatal("first assessment did not return an id")
	}
	// Isolated history fixture: the answers and scores were produced by the
	// formal assessment API; only their completion time is moved four weeks
	// back so the real 28-day retest check is exercised.
	h.exec(`update assessments set completed_at=clock_timestamp()-interval '28 days' where id=$1 and user_id=$2`, first.ID, user)
	var backdated bool
	h.must(h.s.db.QueryRow(h.ctx, `select completed_at <= clock_timestamp()-interval '28 days' from assessments where id=$1 and user_id=$2`, first.ID, user).Scan(&backdated))
	if !backdated {
		t.Fatal("first assessment is not a full four-week-old history fixture")
	}

	fixturePlans := t27ReadPlans(t, h, user)
	if len(fixturePlans) != 1 {
		t.Fatalf("fixture expected exactly one plan before reassessment, got %d", len(fixturePlans))
	}
	if fixturePlans[0].Day != fixtureDay {
		t.Fatalf("fixture plan day %s does not match the selected local day %s", fixturePlans[0].Day, fixtureDay)
	}
	if got := t27SingleLevel(t, fixturePlans[0]); got != t27ObservationLevel {
		t.Fatalf("fixture plan single level %s is not the observation level", got)
	}

	scratch := t.TempDir()
	childProof := uuid.NewString()
	childTimeout := 4 * time.Minute
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+childProof, subject, childTimeout+time.Minute).Err())
	ctx, cancel := context.WithTimeout(t.Context(), childTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, flutter, "test", "--no-pub", "--reporter", "expanded", journey)
	cmd.Dir = appDir
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 5 * time.Second
	env := []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + scratch,
		"TMPDIR=" + scratch,
		"CI=true",
		"FLUTTER_SUPPRESS_ANALYTICS=true",
		"DART_SUPPRESS_ANALYTICS=true",
		"T27_ORIGIN=" + h.api.URL,
		"T27_LOGIN_PROOF=" + childProof,
		"T27_ZONE2=" + zone2,
	}
	for _, key := range []string{"PUB_CACHE", "FLUTTER_ROOT", "LANG", "LC_ALL"} {
		if value, present := os.LookupEnv(key); present {
			env = append(env, key+"="+value)
		}
	}
	cmd.Env = env
	var output bytes.Buffer
	sink := io.MultiWriter(os.Stdout, &output)
	cmd.Stdout, cmd.Stderr = sink, sink
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			t.Fatalf("Flutter T27 journey terminated: %v", ctx.Err())
		}
		t.Fatalf("Flutter T27 journey failed: %v", err)
	}
	if !strings.Contains(output.String(), "PASS(page.journey)") {
		t.Fatal("Flutter T27 journey exited without its final receipt")
	}
	t.Log("PASS(page.journey)")

	second := t27CheckAssessments(t, h, user, bank.Version, first.ID)
	t.Log("PASS(readback.assessments)")

	plans := t27ReadPlans(t, h, user)
	if len(plans) != 2 {
		t.Fatalf("expected the kept same-day plan and one next-day plan, got %d plans", len(plans))
	}
	kept, adjusted := plans[0], plans[1]
	if kept.Day != fixtureDay {
		t.Fatalf("kept plan day %s changed from fixture day %s", kept.Day, fixtureDay)
	}
	nextDay, err := time.Parse(time.DateOnly, kept.Day)
	if err != nil {
		t.Fatal(err)
	}
	if adjusted.Day != nextDay.AddDate(0, 0, 1).Format(time.DateOnly) {
		t.Fatalf("adjusted plan day %s is not the next legal local day after %s", adjusted.Day, kept.Day)
	}
	if kept.AssessmentID == nil || *kept.AssessmentID != first.ID {
		t.Fatal("the already-built same-day plan was not kept for the first assessment")
	}
	if got := t27SingleLevel(t, kept); got != t27ObservationLevel {
		t.Fatalf("kept plan single level %s no longer follows the old weakest dimension", got)
	}
	if adjusted.AssessmentID == nil || *adjusted.AssessmentID != second {
		t.Fatal("the next-day plan was not regenerated from the reassessment")
	}
	if got := t27SingleLevel(t, adjusted); !t27RequestLevels[got] || got == t27ObservationLevel {
		t.Fatalf("regenerated plan single level %s does not follow the new weakest dimension", got)
	}
	t.Log("PASS(readback.plan-kept)")
	t.Log("PASS(readback.plan-adjusted)")

	t27CheckHTTP(t, h, user, token, first.ID, second, kept, adjusted)
	t.Log("PASS(journey)")
}

func t27FixtureFailure(t *testing.T, stage string, err error) {
	t.Helper()
	t.Fatalf("T27 fixture: stage=%s error=%s", stage, t27FailureKind(err))
}

func t27FailureKind(err error) string {
	switch {
	case err == nil:
		return "none"
	case context.Canceled == err:
		return "canceled"
	case context.DeadlineExceeded == err:
		return "timeout"
	default:
		return "operation"
	}
}

func t27Decode(record, dst any) error {
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, dst)
}

type t27AssessmentExport struct {
	assessment.Result
	Version string `json:"version"`
	Answers []int  `json:"answers"`
}

func t27ReadAssessments(t *testing.T, h *practiceWire, user uuid.UUID) []t27AssessmentExport {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	var out []t27AssessmentExport
	err := pgx.BeginTxFunc(ctx, h.s.db, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		return assessment.Hooks(h.s.Fields).Export(ctx, tx, privacy.ExportRequest{UserID: user}, func(record any) error {
			var entry t27AssessmentExport
			if err := t27Decode(record, &entry); err != nil {
				return err
			}
			out = append(out, entry)
			return nil
		})
	})
	if err != nil {
		t.Fatalf("assessment history readback failed: %s", t27FailureKind(err))
	}
	return out
}

func t27ReadPlans(t *testing.T, h *practiceWire, user uuid.UUID) []growth.PlanExportRecord {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	var out []growth.PlanExportRecord
	err := pgx.BeginTxFunc(ctx, h.s.db, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		return growth.Hooks(h.s.Fields, h.s.Practice).Export(ctx, tx, privacy.ExportRequest{UserID: user}, func(record any) error {
			var entry growth.PlanExportRecord
			if err := t27Decode(record, &entry); err != nil {
				return err
			}
			if entry.RecordType == "plan" {
				out = append(out, entry)
			}
			return nil
		})
	})
	if err != nil {
		t.Fatalf("plan history readback failed: %s", t27FailureKind(err))
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].Day < out[j-1].Day; j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	return out
}

func t27SingleLevel(t *testing.T, plan growth.PlanExportRecord) uuid.UUID {
	t.Helper()
	var found uuid.UUID
	for _, item := range plan.Items {
		if item.Kind == growth.KindLevel && item.Title == "单项练习" {
			if found != uuid.Nil {
				t.Fatalf("plan %s has more than one single-skill level", plan.Day)
			}
			found = item.ContentID
		}
	}
	if found == uuid.Nil {
		t.Fatalf("plan %s has no single-skill level", plan.Day)
	}
	return found
}

func t27CheckAssessments(t *testing.T, h *practiceWire, user uuid.UUID, version string, firstID uuid.UUID) uuid.UUID {
	t.Helper()
	rows := t27ReadAssessments(t, h, user)
	if len(rows) != 2 {
		t.Fatalf("expected two persisted assessments for the same account, got %d", len(rows))
	}
	older, latest := rows[0], rows[1]
	if older.ID != firstID || latest.ID == firstID {
		t.Fatal("persisted assessment order does not match the fixture and reassessment")
	}
	if latest.CompletedAt.Sub(older.CompletedAt) < 672*time.Hour {
		t.Fatal("the reassessment was not accepted by the real four-week check")
	}
	for _, want := range []struct {
		name    string
		row     t27AssessmentExport
		answers []int
		focus   string
	}{
		{"fixture", older, t27FirstAnswers, "observation"},
		{"reassessment", latest, t27SecondAnswers, "request"},
	} {
		if want.row.Version != version || !reflect.DeepEqual(want.row.Answers, want.answers) {
			t.Fatalf("%s assessment answers do not match the synthetic sheet", want.name)
		}
		scored, err := h.s.Assessments.Bank.Score(want.row.Version, want.row.Answers)
		if err != nil || !reflect.DeepEqual(want.row.Scores, scored) {
			t.Fatalf("%s assessment scores do not match its answers", want.name)
		}
		if got := growth.Weakest(t27WLEIS(want.row.Scores)); got != want.focus {
			t.Fatalf("%s assessment weakest dimension is %s, want %s", want.name, got, want.focus)
		}
	}
	if n := h.number(`select count(*) from assessments where user_id=$1 and id in ($2,$3)`, user, older.ID, latest.ID); n != 2 {
		t.Fatal("both assessments are not owned by the same account")
	}
	return latest.ID
}

func t27WLEIS(s assessment.Scores) growth.WLEIS {
	return growth.WLEIS{
		SEA: s.Dimensions["SEA"].Percent,
		OEA: s.Dimensions["OEA"].Percent,
		UOE: s.Dimensions["UOE"].Percent,
		ROE: s.Dimensions["ROE"].Percent,
	}
}

func t27CheckHTTP(t *testing.T, h *practiceWire, user uuid.UUID, token string, firstID, secondID uuid.UUID, kept, adjusted growth.PlanExportRecord) {
	t.Helper()
	exported := t27ReadAssessments(t, h, user)
	if len(exported) != 2 {
		t.Fatalf("expected two exported assessments for the same account, got %d", len(exported))
	}
	byID := make(map[uuid.UUID]t27AssessmentExport, len(exported))
	for _, row := range exported {
		byID[row.ID] = row
	}
	type dimension struct {
		Percent float64 `json:"percent"`
		Display int     `json:"display"`
		Level   string  `json:"level"`
	}
	var history struct {
		Items []struct {
			ID             uuid.UUID            `json:"id"`
			CompletedAt    time.Time            `json:"completed_at"`
			NextEligibleAt time.Time            `json:"next_eligible_at"`
			Dimensions     map[string]dimension `json:"dimensions"`
			Total          dimension            `json:"total"`
		} `json:"items"`
	}
	h.json(token, "GET", "assessments?limit=2", nil, 200, &history)
	if len(history.Items) != 2 || history.Items[0].ID != secondID || history.Items[1].ID != firstID {
		t.Fatal("assessment history does not return both assessments in descending order")
	}
	// Map the HTTP rows back to the persisted export rows: latest is the
	// reassessment, previous is the four-week-old fixture. Every persisted
	// field is compared, including all four dimensions.
	for i, wantID := range []uuid.UUID{secondID, firstID} {
		row := history.Items[i]
		exp, ok := byID[wantID]
		if !ok {
			t.Fatalf("assessment history item %s has no persisted export row", wantID)
		}
		if !row.CompletedAt.Equal(exp.CompletedAt) {
			t.Fatalf("assessment %s completed_at differs from the persisted row", wantID)
		}
		if !row.NextEligibleAt.Equal(exp.NextEligibleAt) || !row.NextEligibleAt.Equal(exp.CompletedAt.Add(672*time.Hour)) {
			t.Fatalf("assessment %s next_eligible_at is not four weeks after completion", wantID)
		}
		if row.Total.Percent != exp.Total.Percent || row.Total.Display != exp.Total.Display || row.Total.Level != exp.Total.Level {
			t.Fatalf("assessment %s total differs from the persisted row", wantID)
		}
		if len(row.Dimensions) != 4 || len(exp.Dimensions) != 4 {
			t.Fatalf("assessment %s does not carry exactly four WLEIS dimensions", wantID)
		}
		for _, key := range []string{"SEA", "OEA", "UOE", "ROE"} {
			got, want := row.Dimensions[key], exp.Dimensions[key]
			if got.Percent != want.Percent || got.Display != want.Display || got.Level != want.Level {
				t.Fatalf("assessment %s dimension %s differs from the persisted row", wantID, key)
			}
		}
	}
	older, latest := history.Items[1], history.Items[0]
	if latest.Total.Percent-older.Total.Percent != 25 {
		t.Fatalf("radar total delta is %.1f, want 25", latest.Total.Percent-older.Total.Percent)
	}
	for _, key := range []string{"SEA", "OEA", "UOE", "ROE"} {
		if latest.Dimensions[key].Percent == older.Dimensions[key].Percent {
			t.Fatalf("dimension %s did not change between the two assessments", key)
		}
	}

	var today struct {
		Day   string `json:"day"`
		Items []struct {
			Kind      string    `json:"kind"`
			Title     string    `json:"title"`
			ContentID uuid.UUID `json:"content_id"`
		} `json:"items"`
	}
	h.json(token, "GET", "plans/today", nil, 200, &today)
	if today.Day != adjusted.Day {
		t.Fatalf("today plan day %s is not the persisted next day %s", today.Day, adjusted.Day)
	}
	var singles []uuid.UUID
	for _, item := range today.Items {
		if item.Kind == string(growth.KindLevel) && item.Title == "单项练习" {
			singles = append(singles, item.ContentID)
		}
	}
	if len(singles) != 1 {
		t.Fatalf("today plan has %d single-skill levels, want exactly one", len(singles))
	}
	// The formal HTTP result and the persisted plan row must name the same
	// level ID. Accepting either request level here would not prove that.
	if want := t27SingleLevel(t, adjusted); singles[0] != want {
		t.Fatalf("today plan single level %s differs from the persisted row %s", singles[0], want)
	}
	if kept.Day == adjusted.Day {
		t.Fatal("same-day and next-day plans were not separated")
	}
}

func t27Zone(offset int) string {
	switch {
	case offset == 0:
		return "UTC"
	case offset > 0 && offset <= 12:
		return fmt.Sprintf("Etc/GMT-%d", offset)
	case offset < 0 && offset >= -12:
		return fmt.Sprintf("Etc/GMT+%d", -offset)
	case offset == 13:
		return "Pacific/Tongatapu"
	case offset == 14:
		return "Pacific/Kiritimati"
	}
	return ""
}

// t27ZonePair finds two legal account timezones whose local dates are exactly
// one day apart right now, preferring the pair that keeps the fixture local day
// furthest from its midnight. The product's plan key is the account's local
// day, so this is a fixture-only way to reach tomorrow without touching the
// system clock.
func t27ZonePair(t *testing.T, now time.Time) (string, string, string, time.Duration) {
	t.Helper()
	bestRemain := time.Duration(-1)
	bestA, bestB := 0, 0
	for a := -12; a <= 14; a++ {
		la, err := time.LoadLocation(t27Zone(a))
		if err != nil {
			continue
		}
		local := now.In(la)
		day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC)
		remain := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, la).AddDate(0, 0, 1).Sub(now)
		for b := -12; b <= 14; b++ {
			if a == b {
				continue
			}
			lb, err := time.LoadLocation(t27Zone(b))
			if err != nil {
				continue
			}
			other := now.In(lb)
			otherDay := time.Date(other.Year(), other.Month(), other.Day(), 0, 0, 0, 0, time.UTC)
			if otherDay.Sub(day) != 24*time.Hour {
				continue
			}
			if remain > bestRemain {
				bestRemain, bestA, bestB = remain, a, b
			}
		}
	}
	if bestRemain < 30*time.Minute {
		t.Fatalf("no safe next-day timezone pair with enough fixture margin (best %v)", bestRemain)
	}
	local := now.In(time.FixedZone("", bestA*3600))
	day := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, time.UTC).Format(time.DateOnly)
	return t27Zone(bestA), t27Zone(bestB), day, bestRemain
}
