//go:build integration && t27knowledge

package service

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9/logging"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/growth"
)

// One synthetic answer sheet from the in-repo T26 bank. It only has to create
// a valid assessment and today's real plan; the catalog journey never reads
// the WLEIS result.
var t27KnowledgeAnswers = []int{1, 1, 1, 1, 2, 2, 2, 2, 6, 6, 6, 6, 7, 7, 7, 7}

// t27KnowledgeLastSeed reads the last card's id, title and full body from the
// checked-out formal seed (server/content/t26.yaml) through the same Go YAML
// loader the scheduler uses. It is an independent expectation: the catalog and
// single-card endpoints must both match these exact strings, so shared summary
// truncation cannot pass by comparing two responses to each other, and editing
// the seed changes the expectation without touching this test.
func t27KnowledgeLastSeed(t *testing.T) growth.Card {
	t.Helper()
	content, err := growth.LoadContent()
	if err != nil {
		t.Fatalf("formal content seed is invalid: %v", err)
	}
	var last growth.Card
	for _, card := range content.Cards {
		if last.ID == uuid.Nil || card.ID.String() > last.ID.String() {
			last = card
		}
	}
	if last.ID == uuid.Nil || last.Title == "" || last.Body == "" {
		t.Fatal("formal content seed has no complete last card")
	}
	return last
}

// TestT27KnowledgeCatalogJourney proves that a normal free account can read
// the real twenty-card catalog from the practice home, including the last
// planned-external card, without completing it, and can then explicitly
// complete today's actual planned card exactly once.
func TestT27KnowledgeCatalogJourney(t *testing.T) {
	if os.Getenv("T27_DISPOSABLE") != "yes" || os.Getenv("T19_DISPOSABLE") != "yes" {
		t.Skip("requires T27_DISPOSABLE=yes and T19_DISPOSABLE=yes with disposable loopback PG17 and two Redis instances")
	}
	logging.Disable()
	slog.SetDefault(slog.New(slog.DiscardHandler))
	if os.Getenv("APP_ENV") != "development" {
		t.Fatal("requires APP_ENV=development")
	}
	// Resolve the app from the repository checkout, never from a card path.
	appDir := filepath.Join("..", "..", "..", "app")
	const journey = "tool/t27/knowledge_catalog_journey_test.dart"
	for _, path := range []string{journey, ".dart_tool/package_config.json"} {
		if info, err := os.Stat(filepath.Join(appDir, path)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("Flutter prerequisite missing: app/%s", path)
		}
	}
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}

	h := newPracticeWireWithFailureReporter(t, t27KnowledgeFailure)
	zone, today := t27KnowledgeSafeZone(t, time.Now())
	t.Logf("account zone %s, local day %s", zone, today)

	subject := uuid.NewString()
	var tokens app.Tokens
	loginProof := uuid.NewString()
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+loginProof, subject, 10*time.Minute).Err())
	h.json("", "POST", "auth/login", map[string]any{
		"credential":    map[string]string{"provider": "apple", "proof": loginProof},
		"age_confirmed": true,
		"terms_version": accounts.PolicyVersion,
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
	var assessment struct {
		ID uuid.UUID `json:"id"`
	}
	h.json(token, "POST", "assessments", map[string]any{
		"version": bank.Version, "answers": t27KnowledgeAnswers,
	}, 200, &assessment)
	if assessment.ID == uuid.Nil {
		t.Fatal("assessment did not return an id")
	}

	var plan t27KnowledgePlan
	h.json(token, "GET", "plans/today", nil, 200, &plan)
	if plan.Day != today {
		t.Fatalf("today plan day %s does not match the selected local day %s", plan.Day, today)
	}
	if len(plan.Items) != 4 {
		t.Fatalf("today plan has %d items, want 4", len(plan.Items))
	}
	planned := map[uuid.UUID]bool{}
	cards := 0
	var planCard t27KnowledgePlanItem
	for _, item := range plan.Items {
		planned[item.ContentID] = true
		if item.Completed {
			t.Fatalf("today plan item %s is completed before the journey", item.Title)
		}
		if item.Kind == growth.KindCard {
			cards++
			planCard = item
		}
	}
	if cards != 1 {
		t.Fatalf("today plan has %d card items, want exactly 1", cards)
	}
	if planCard.ContentID == uuid.Nil || planCard.ID == uuid.Nil {
		t.Fatal("today plan card item is missing its identifiers")
	}

	seed := t27KnowledgeLastSeed(t)
	var catalog t27KnowledgeCardPage
	h.json(token, "GET", "cards?limit=20", nil, 200, &catalog)
	if len(catalog.Items) != 20 {
		t.Fatalf("catalog returned %d cards, want the real twenty", len(catalog.Items))
	}
	if catalog.NextCursor != nil {
		t.Fatal("first catalog page has a cursor; the real seed should fit in one page")
	}
	seen := make(map[uuid.UUID]bool, len(catalog.Items))
	previous := ""
	for _, card := range catalog.Items {
		if seen[card.ID] {
			t.Fatalf("catalog repeats card %s", card.ID)
		}
		seen[card.ID] = true
		if previous != "" && previous >= card.ID.String() {
			t.Fatalf("catalog card %s is not in strict ascending ID order", card.ID)
		}
		previous = card.ID.String()
		if card.Title == "" || card.Body == "" {
			t.Fatalf("catalog card %s is missing its title or full body", card.ID)
		}
	}
	last := catalog.Items[len(catalog.Items)-1]
	if last.ID != seed.ID {
		t.Fatalf("catalog last card is %s, want the formal seed's %s", last.ID, seed.ID)
	}
	if last.Title != seed.Title || last.Body != seed.Body {
		t.Fatal("catalog last entry does not match the formal seed's title and full body")
	}
	if planned[last.ID] {
		t.Fatal("the last catalog card is in today's plan; the journey needs a planned-external card")
	}
	if planCard.ContentID == last.ID {
		t.Fatal("the planned card is the last catalog card")
	}
	var detail app.GetCardResult
	h.json(token, "GET", "cards/"+last.ID.String(), nil, 200, &detail)
	if uuid.UUID(detail.Id) != seed.ID || detail.Title != seed.Title || detail.Body != seed.Body {
		t.Fatal("single-card response does not match the formal seed's last title and full body")
	}
	t.Log("PASS(service.catalog)")

	var before t27KnowledgeGrowth
	h.json(token, "GET", "growth", nil, 200, &before)
	if before.Streak != 0 || len(before.Achievements) != 0 {
		t.Fatalf("new account starts with streak %d and achievements %v", before.Streak, before.Achievements)
	}

	proof := uuid.NewString()
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+proof, subject, 10*time.Minute).Err())
	t27KnowledgeRunFlutter(t, flutter, appDir, journey, h.api.URL, proof, seed)

	var after t27KnowledgeGrowth
	h.json(token, "GET", "growth", nil, 200, &after)
	if after.Streak != 1 {
		t.Fatalf("explicit planned-card completion left streak %d, want 1", after.Streak)
	}
	if len(after.Achievements) != 0 {
		t.Fatalf("one-day completion invented achievements %v", after.Achievements)
	}
	h.json(token, "GET", "plans/today", nil, 200, &plan)
	completed := 0
	for _, item := range plan.Items {
		if !item.Completed {
			continue
		}
		completed++
		if item.Kind != growth.KindCard || item.ID != planCard.ID || item.ContentID != planCard.ContentID {
			t.Fatalf("completed item %s is %s, not today's planned card", item.Title, item.Kind)
		}
	}
	if completed != 1 {
		t.Fatalf("today plan has %d completed items, want exactly the planned card", completed)
	}
	if n := h.number(`select count(*) from daily_plans where user_id=$1 and plan_day=$2 and completed_at is not null`, user, today); n != 1 {
		t.Fatalf("today has %d durably completed plan rows, want exactly one", n)
	}
	if n := h.number(`select count(*) from daily_plans where user_id=$1`, user); n != 1 {
		t.Fatalf("account has %d plan rows, want exactly one", n)
	}
	t.Log("PASS(service.after)")
	t.Log("PASS(journey)")
}

type t27KnowledgeGrowth struct {
	Streak       int   `json:"streak"`
	Achievements []int `json:"achievements"`
}

type t27KnowledgePlan struct {
	Day   string                   `json:"day"`
	Items []t27KnowledgePlanItem   `json:"items"`
}

type t27KnowledgePlanItem struct {
	ID        uuid.UUID `json:"id"`
	Kind      string    `json:"kind"`
	Title     string    `json:"title"`
	ContentID uuid.UUID `json:"content_id"`
	Completed bool      `json:"completed"`
}

type t27KnowledgeCard struct {
	ID    uuid.UUID `json:"id"`
	Scene string    `json:"scene"`
	Title string    `json:"title"`
	Body  string    `json:"body"`
}

type t27KnowledgeCardPage struct {
	Items      []t27KnowledgeCard `json:"items"`
	NextCursor *string            `json:"next_cursor"`
}

func t27KnowledgeFailure(t *testing.T, stage string, err error) {
	t.Helper()
	t.Fatalf("T27 catalog fixture: stage=%s error=%s", stage, t27KnowledgeFailureKind(err))
}

func t27KnowledgeFailureKind(err error) string {
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

// t27KnowledgeRunFlutter passes the seed-derived expectation through the
// process environment, not through any response or screen, so the Flutter
// journey checks the full seed text independently. Nothing here logs it.
func t27KnowledgeRunFlutter(t *testing.T, flutter, appDir, journey, origin, proof string, seed growth.Card) {
	t.Helper()
	scratch := t.TempDir()
	timeout := 7 * time.Minute
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
		"T27_LOGIN_PROOF=" + proof,
		"T27_EXPECT_LAST_CARD=" + seed.ID.String(),
		"T27_EXPECT_LAST_TITLE=" + seed.Title,
		"T27_EXPECT_LAST_BODY=" + seed.Body,
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
			t.Fatalf("Flutter T27 catalog journey terminated: %v", ctx.Err())
		}
		t.Fatalf("Flutter T27 catalog journey failed: %v", err)
	}
	for _, receipt := range []string{
		"PASS(page.browse-last-card)",
		"PASS(page.read-no-complete)",
		"PASS(page.plan-card-complete)",
		"PASS(page.growth-tab)",
		"PASS(page.growth-home)",
	} {
		if !strings.Contains(output.String(), receipt) {
			t.Fatalf("Flutter T27 catalog journey exited without %s", receipt)
		}
		t.Log(receipt)
	}
}

func t27KnowledgeZoneName(offset int) string {
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

// t27KnowledgeSafeZone picks the legal account timezone whose local day has
// the largest remaining time before midnight, so the plan cannot roll over
// during the journey.
func t27KnowledgeSafeZone(t *testing.T, now time.Time) (string, string) {
	t.Helper()
	bestMargin := time.Duration(-1)
	bestOffset := 0
	for offset := -12; offset <= 14; offset++ {
		loc, err := time.LoadLocation(t27KnowledgeZoneName(offset))
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
	loc, err := time.LoadLocation(t27KnowledgeZoneName(bestOffset))
	if err != nil {
		t.Fatal(err)
	}
	return t27KnowledgeZoneName(bestOffset), now.In(loc).Format(time.DateOnly)
}
