//go:build integration && t27streak

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9/logging"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/privacy"
)

// One synthetic answer sheet from the in-repo T26 bank. It only has to be a
// valid sheet: the streak journey never reads the WLEIS result. A single
// formal HTTP submission creates the account's real assessment and today's
// plan; the 3/7/30 history is a separate, explicitly bracketed fixture.
var t27StreakAnswers = []int{1, 1, 1, 1, 2, 2, 2, 2, 6, 6, 6, 6, 7, 7, 7, 7}

// TestT27RetainedMilestonesJourney proves that breaking a long streak keeps
// the 3/7/30 milestones while the current streak returns to zero, and that a
// real free completion today counts one day without re-awarding old stages.
//
// The only fixture is the completed daily_plans history: 30 consecutive days
// ending two local days before today. Each row is sealed with the production
// field cipher in the production stored-plan shape (real plan items, one
// completed exercise, completed_at at local noon), and the production plan
// export opens every row before the journey starts. The last historical day is
// today-2, so today-1 is a whole un-checked-in day and no API response or UI
// cache carries any fabricated milestone.
func TestT27RetainedMilestonesJourney(t *testing.T) {
	if os.Getenv("T27_DISPOSABLE") != "yes" || os.Getenv("T19_DISPOSABLE") != "yes" {
		t.Skip("requires T27_DISPOSABLE=yes and T19_DISPOSABLE=yes with disposable loopback PG17 and two Redis instances")
	}
	logging.Disable()
	slog.SetDefault(slog.New(slog.DiscardHandler))
	if os.Getenv("APP_ENV") != "development" {
		t.Fatal("requires APP_ENV=development")
	}
	appDir := filepath.Join("..", "..", "..", "app")
	const journey = "tool/t27/retained_milestones_journey_test.dart"
	for _, path := range []string{journey, ".dart_tool/package_config.json"} {
		if info, err := os.Stat(filepath.Join(appDir, path)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("Flutter prerequisite missing: app/%s", path)
		}
	}
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}

	h := newPracticeWireWithFailureReporter(t, t27StreakFailure)
	zone, today := t27StreakSafeZone(t, time.Now())
	t.Logf("account zone %s, local day %s", zone, today)

	subject := uuid.NewString()
	var tokens app.Tokens
	loginProof := uuid.NewString()
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+loginProof, subject, 10*time.Minute).Err())
	h.json("", "POST", "auth/login", map[string]any{
		"credential":      map[string]string{"provider": "apple", "proof": loginProof},
		"age_confirmed":   true,
		"terms_version":   accounts.PolicyVersion,
		"privacy_version": accounts.PolicyVersion,
	}, 200, &tokens)
	user := uuid.UUID(tokens.UserId)
	token := tokens.AccessToken
	h.json(token, "PATCH", "me", map[string]any{"timezone": zone}, 200, nil)
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
	var assessment struct {
		ID uuid.UUID `json:"id"`
	}
	h.json(token, "POST", "assessments", map[string]any{
		"version": bank.Version, "answers": t27StreakAnswers,
	}, 200, &assessment)
	if assessment.ID == uuid.Nil {
		t.Fatal("assessment did not return an id")
	}

	var plan t27StreakPlan
	h.json(token, "GET", "plans/today", nil, 200, &plan)
	if plan.Day != today {
		t.Fatalf("today plan day %s does not match the selected local day %s", plan.Day, today)
	}
	if len(plan.Items) != 4 {
		t.Fatalf("today plan has %d items, want 4", len(plan.Items))
	}
	for _, item := range plan.Items {
		if item.Completed {
			t.Fatalf("today plan item %s is completed before the journey", item.Title)
		}
	}
	if !t27StreakHasExercise(plan) {
		t.Fatal("today plan has no exercise item to complete")
	}

	history := t27StreakSeedHistory(t, h, user, assessment.ID, zone, today, plan)
	t27StreakCheckPlans(t, h, user, history, today, false)
	t.Log("PASS(service.seeded-history)")

	var retained t27StreakGrowth
	h.json(token, "GET", "growth", nil, 200, &retained)
	if retained.Streak != 0 || !reflect.DeepEqual(retained.Achievements, []int{3, 7, 30}) {
		t.Fatalf("history fixture does not read back as streak 0 with retained milestones: %+v", retained)
	}
	h.json(token, "GET", "plans/today", nil, 200, &plan)
	for _, item := range plan.Items {
		if item.Completed {
			t.Fatalf("today plan item %s is completed before the page journey", item.Title)
		}
	}
	t.Log("PASS(service.retained-before)")

	firstProof, secondProof := uuid.NewString(), uuid.NewString()
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+firstProof, subject, 10*time.Minute).Err())
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+secondProof, subject, 10*time.Minute).Err())
	t27StreakRunFlutter(t, flutter, appDir, journey, h.api.URL, firstProof, secondProof)

	t27StreakCheckPlans(t, h, user, history, today, true)
	var after t27StreakGrowth
	h.json(token, "GET", "growth", nil, 200, &after)
	if after.Streak != 1 || !reflect.DeepEqual(after.Achievements, []int{3, 7, 30}) {
		t.Fatalf("completion did not keep the milestones with a one-day streak: %+v", after)
	}
	h.json(token, "GET", "plans/today", nil, 200, &plan)
	completed := 0
	for _, item := range plan.Items {
		if !item.Completed {
			continue
		}
		completed++
		if item.Kind != string(growth.KindExercise) {
			t.Fatalf("the only completed item is %s (%s), not the free exercise", item.Title, item.Kind)
		}
	}
	if completed != 1 {
		t.Fatalf("today plan has %d completed items, want exactly 1", completed)
	}
	t.Log("PASS(service.today-once)")
	t.Log("PASS(service.retained-after)")
	t.Log("PASS(journey)")
}

type t27StreakGrowth struct {
	Streak       int   `json:"streak"`
	Achievements []int `json:"achievements"`
}

type t27StreakPlan struct {
	Day          string            `json:"day"`
	Personalized bool              `json:"personalized"`
	Items        []t27StreakPlanItem `json:"items"`
	AssessmentID *uuid.UUID        `json:"assessment_id,omitempty"`
}

type t27StreakPlanItem struct {
	ID        uuid.UUID `json:"id"`
	Kind      string    `json:"kind"`
	Title     string    `json:"title"`
	ContentID uuid.UUID `json:"content_id"`
	Completed bool      `json:"completed"`
}

// t27StreakStoredPlan mirrors growth.storedPlan: the public plan fields plus
// the encrypted-only completion attribution. The fixture must stay readable by
// the production growth plan export.
type t27StreakStoredPlan struct {
	t27StreakPlan
	Completion map[string]any `json:"completion,omitempty"`
}

func (p t27StreakPlan) Stored(completion map[string]any) t27StreakStoredPlan {
	return t27StreakStoredPlan{t27StreakPlan: p, Completion: completion}
}

func t27StreakHasExercise(plan t27StreakPlan) bool {
	for _, item := range plan.Items {
		if item.Kind == growth.KindExercise {
			return true
		}
	}
	return false
}

func t27StreakFailure(t *testing.T, stage string, err error) {
	t.Helper()
	t.Fatalf("T27 streak fixture: stage=%s error=%s", stage, t27StreakFailureKind(err))
}

func t27StreakFailureKind(err error) string {
	switch {
	case err == nil:
		return "none"
	case err == context.Canceled:
		return "canceled"
	case err == context.DeadlineExceeded:
		return "timeout"
	default:
		return "operation"
	}
}

// t27StreakSeedHistory inserts 30 consecutive completed days ending today-2.
// Every row reuses today's production plan items with deterministic per-day
// item IDs and is sealed under the same AAD the growth package uses.
func t27StreakSeedHistory(t *testing.T, h *practiceWire, user, assessmentID uuid.UUID, zone, today string, todayPlan t27StreakPlan) []t27StreakHistoryDay {
	t.Helper()
	loc, err := time.LoadLocation(zone)
	if err != nil {
		t.Fatalf("fixture zone %s: %v", zone, err)
	}
	end, err := time.Parse(time.DateOnly, today)
	if err != nil {
		t.Fatal(err)
	}
	end = end.AddDate(0, 0, -2)
	days := make([]t27StreakHistoryDay, 0, 30)
	for i := 29; i >= 0; i-- {
		day := end.AddDate(0, 0, -i).Format(time.DateOnly)
		date := end.AddDate(0, 0, -i)
		at := time.Date(date.Year(), date.Month(), date.Day(), 12, 0, 0, 0, loc).UTC()
		items := make([]t27StreakPlanItem, len(todayPlan.Items))
		for j, item := range todayPlan.Items {
			items[j] = item
			items[j].ID = growth.PlanItemID(user, day, item.Kind, item.ContentID)
			items[j].Completed = item.Kind == growth.KindExercise
		}
		stored := todayPlan.Stored(map[string]any{"manual_at": at})
		stored.Day = day
		stored.Items = items
		stored.AssessmentID = &assessmentID
		plain, err := json.Marshal(stored)
		if err != nil {
			t.Fatalf("fixture plan %s: %v", day, err)
		}
		// growth.planAAD is package-private; a production-format fixture must
		// seal under exactly this account/day AAD to be readable by the service.
		sealed, err := h.s.Fields.Seal(plain, []byte("daily_plans:plan_enc:"+user.String()+":"+day))
		if err != nil {
			t.Fatalf("seal fixture plan %s: %v", day, err)
		}
		h.exec(`insert into daily_plans(user_id,plan_day,plan_enc,completed_at,assessment_id)
values($1,$2,$3,$4,$5)`, user, day, sealed, at, assessmentID)
		days = append(days, t27StreakHistoryDay{Day: day, At: at, Sealed: sealed})
	}
	if n := h.number(`select count(*) from daily_plans where user_id=$1 and plan_day>=$2 and completed_at is not null`, user, days[0].Day); n != 30 {
		t.Fatalf("fixture inserted %d completed history days, want 30", n)
	}
	if n := h.number(`select count(*) from daily_plans where user_id=$1 and plan_day=$2`, user, end.AddDate(0, 0, 1).Format(time.DateOnly)); n != 0 {
		t.Fatal("fixture left no whole un-checked-in day between history and today")
	}
	return days
}

type t27StreakHistoryDay struct {
	Day    string
	At     time.Time
	Sealed []byte
}

// t27StreakCheckPlans reads the durable plans through the production export.
// Before the page journey every historical row must still be a completed plan.
// After it, exactly today's row gains the free exercise completion; the
// historical rows must be byte-for-byte unchanged.
func t27StreakCheckPlans(t *testing.T, h *practiceWire, user uuid.UUID, history []t27StreakHistoryDay, today string, completedNow bool) {
	t.Helper()
	rows := t27StreakReadPlans(t, h, user)
	if len(rows) != len(history)+1 {
		t.Fatalf("production export returned %d plans, want %d history plus today", len(rows), len(history)+1)
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].Day < rows[j].Day })
	byDay := make(map[string]growth.PlanExportRecord, len(rows))
	for _, row := range rows {
		byDay[row.Day] = row
	}
	for i, want := range history {
		row, ok := byDay[want.Day]
		if !ok {
			t.Fatalf("history day %s is missing from the production export", want.Day)
		}
		if row.CompletedAt == nil || !row.CompletedAt.Equal(want.At) {
			t.Fatalf("history day %s completed_at is not the fixture local noon", want.Day)
		}
		completed := 0
		for _, item := range row.Items {
			if item.Completed {
				completed++
				if item.Kind != growth.KindExercise {
					t.Fatalf("history day %s completed item %s is not an exercise", want.Day, item.Kind)
				}
			}
		}
		if completed != 1 || len(row.Items) != 4 {
			t.Fatalf("history day %s has %d items and %d completed, want 4 and 1", want.Day, len(row.Items), completed)
		}
		var sealed []byte
		h.must(h.s.db.QueryRow(h.ctx, `select plan_enc from daily_plans where user_id=$1 and plan_day=$2`, user, want.Day).Scan(&sealed))
		if !bytes.Equal(sealed, want.Sealed) {
			t.Fatalf("history day %d was rewritten after seeding", i)
		}
	}
	todayRow, ok := byDay[today]
	if !ok {
		t.Fatal("today's plan is missing from the production export")
	}
	completed := 0
	for _, item := range todayRow.Items {
		if item.Completed {
			completed++
			if item.Kind != growth.KindExercise {
				t.Fatalf("today's completed item %s is not the free exercise", item.Kind)
			}
		}
	}
	wantCompleted := 0
	if completedNow {
		wantCompleted = 1
	}
	if completed != wantCompleted {
		t.Fatalf("today plan has %d completed items, want %d", completed, wantCompleted)
	}
	if completedNow && (todayRow.CompletedAt == nil) {
		t.Fatal("today's completion has no durable completed_at")
	}
	if n := h.number(`select count(*) from daily_plans where user_id=$1 and plan_day=$2`, user, today); n != 1 {
		t.Fatalf("today has %d plan rows, want exactly one", n)
	}
}

func t27StreakReadPlans(t *testing.T, h *practiceWire, user uuid.UUID) []growth.PlanExportRecord {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	var out []growth.PlanExportRecord
	err := pgx.BeginTxFunc(ctx, h.s.db, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		return growth.Hooks(h.s.Fields, h.s.Practice).Export(ctx, tx, privacy.ExportRequest{UserID: user}, func(record any) error {
			data, err := json.Marshal(record)
			if err != nil {
				return err
			}
			var entry growth.PlanExportRecord
			if err := json.Unmarshal(data, &entry); err != nil {
				return err
			}
			if entry.RecordType == "plan" {
				out = append(out, entry)
			}
			return nil
		})
	})
	if err != nil {
		t.Fatalf("plan export readback failed: %s", t27StreakFailureKind(err))
	}
	return out
}

func t27StreakRunFlutter(t *testing.T, flutter, appDir, journey, origin, firstProof, secondProof string) {
	t.Helper()
	scratch := t.TempDir()
	timeout := 5 * time.Minute
	ctx, cancel := context.WithTimeout(t.Context(), timeout)
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
		"T27_ORIGIN=" + origin,
		"T27_LOGIN_PROOF=" + firstProof,
		"T27_LOGIN_PROOF2=" + secondProof,
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
			t.Fatalf("Flutter T27 streak journey terminated: %v", ctx.Err())
		}
		t.Fatalf("Flutter T27 streak journey failed: %v", err)
	}
	for _, receipt := range []string{
		"PASS(page.retained-milestones)",
		"PASS(page.practice-strip)",
		"PASS(page.growth-retained)",
		"PASS(page.today-completion)",
		"PASS(page.cold-reopen)",
		"PASS(page.growth-cold-reopen)",
	} {
		if !strings.Contains(output.String(), receipt) {
			t.Fatalf("Flutter T27 streak journey exited without %s", receipt)
		}
		t.Log(receipt)
	}
}

func t27StreakZoneName(offset int) string {
	switch {
	case offset == 0:
		return "UTC"
	case offset > 0 && offset <= 12:
		return "Etc/GMT-" + strconv.Itoa(offset)
	case offset < 0 && offset >= -12:
		return "Etc/GMT+" + strconv.Itoa(-offset)
	case offset == 13:
		return "Pacific/Tongatapu"
	case offset == 14:
		return "Pacific/Kiritimati"
	}
	return ""
}

// t27StreakSafeZone picks the legal account timezone whose local day has the
// largest remaining time before midnight. Whole-hour offsets one hour apart
// guarantee a wide margin, so the fixture local day cannot roll over mid-run.
func t27StreakSafeZone(t *testing.T, now time.Time) (string, string) {
	t.Helper()
	bestMargin := time.Duration(-1)
	bestOffset := 0
	for offset := -12; offset <= 14; offset++ {
		loc, err := time.LoadLocation(t27StreakZoneName(offset))
		if err != nil {
			continue
		}
		local := now.In(loc)
		next := time.Date(local.Year(), local.Month(), local.Day(), 0, 0, 0, 0, loc).AddDate(0, 0, 1)
		if margin := next.Sub(now); margin > bestMargin {
			bestMargin, bestOffset = margin, offset
		}
	}
	if bestMargin < 30*time.Minute {
		t.Fatalf("no safe local day with enough margin (best %v)", bestMargin)
	}
	loc, err := time.LoadLocation(t27StreakZoneName(bestOffset))
	if err != nil {
		t.Fatal(err)
	}
	return t27StreakZoneName(bestOffset), now.In(loc).Format(time.DateOnly)
}
