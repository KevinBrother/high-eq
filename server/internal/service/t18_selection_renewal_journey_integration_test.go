//go:build integration && t18selection

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
)

const (
	t18FixtureAdvance = "/__t18_fixture/advance"
	t18FlutterTest    = "tool/t18/selection_renewal_journey_test.dart"
)

// t18Snapshot is the Go-side product readback taken while the fixture advances
// the synthetic membership interval. The Flutter journey compares its own
// post-refresh list against this same readback.
type t18Snapshot struct {
	Phase             string   `json:"phase"`
	Tier              string   `json:"tier"`
	MaxActiveContacts *int     `json:"max_active_contacts"`
	Editable          []string `json:"editable"`
}

type t18Fixture struct {
	h      *practiceWire
	token  string
	user   uuid.UUID
	secret string

	mu        sync.Mutex
	snapshots map[string]t18Snapshot
	calls     map[string]int
	activates map[string]int
}

func newT18Fixture(h *practiceWire, token string, user uuid.UUID, secret string) *t18Fixture {
	return &t18Fixture{
		h:         h,
		token:     token,
		user:      user,
		secret:    secret,
		snapshots: map[string]t18Snapshot{},
		calls:     map[string]int{},
		activates: map[string]int{},
	}
}

func (f *t18Fixture) countActivate(r *http.Request) {
	if r.Method != http.MethodPost {
		return
	}
	id, action, ok := strings.Cut(strings.TrimPrefix(r.URL.Path, "/v1/contacts/"), "/")
	if !ok || action != "activate" {
		return
	}
	if _, err := uuid.Parse(id); err != nil {
		return
	}
	f.mu.Lock()
	f.activates[id]++
	f.mu.Unlock()
}

// advance is only a synthetic membership fixture: it never calls payment,
// merchant or purchase routes. The readback that follows uses the real
// entitlements and contacts HTTP routes.
func (f *t18Fixture) advance(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost || r.Header.Get("X-T18-Fixture") != f.secret {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	var in struct {
		Phase string `json:"phase"`
	}
	if json.NewDecoder(r.Body).Decode(&in) != nil || (in.Phase != "expire" && in.Phase != "renew") {
		http.Error(w, "invalid phase", http.StatusBadRequest)
		return
	}
	f.mu.Lock()
	already := f.calls[in.Phase] > 0
	f.calls[in.Phase]++
	f.mu.Unlock()
	if already {
		http.Error(w, "duplicate phase", http.StatusConflict)
		return
	}

	ctx := r.Context()
	var err error
	switch in.Phase {
	case "expire":
		_, err = f.h.s.db.Exec(ctx, `update entitlements set ends_at=now()-interval '1 second' where user_id=$1`, f.user)
	case "renew":
		_, err = f.h.s.db.Exec(ctx, `with o as (
			insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
			values($1,'apple',$2,'fixture',1,'paid') returning id,user_id
		) insert into entitlements select id,user_id,now()-interval '1 minute',now()+interval '1 day' from o`,
			f.user, []byte(uuid.NewString()))
	}
	if err != nil {
		http.Error(w, "fixture update failed", http.StatusInternalServerError)
		return
	}
	snapshot, err := f.readback(ctx, in.Phase)
	if err != nil {
		http.Error(w, "fixture readback failed", http.StatusInternalServerError)
		return
	}
	f.mu.Lock()
	f.snapshots[in.Phase] = snapshot
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(snapshot)
}

func (f *t18Fixture) readback(ctx context.Context, phase string) (t18Snapshot, error) {
	out := t18Snapshot{Phase: phase, Editable: []string{}}
	var entitlements app.Entitlements
	if err := f.get(ctx, "/v1/entitlements", &entitlements); err != nil {
		return out, err
	}
	var contacts app.ListContactsResult
	if err := f.get(ctx, "/v1/contacts?limit=100", &contacts); err != nil {
		return out, err
	}
	out.Tier = string(entitlements.Tier)
	out.MaxActiveContacts = entitlements.MaxActiveContacts
	for _, contact := range contacts.Items {
		if contact.Editable {
			out.Editable = append(out.Editable, contact.Id.String())
		}
	}
	sort.Strings(out.Editable)
	return out, nil
}

func (f *t18Fixture) get(ctx context.Context, path string, out any) error {
	req := httptest.NewRequestWithContext(ctx, http.MethodGet, path, nil)
	req.Header.Set("Authorization", "Bearer "+f.token)
	rec := httptest.NewRecorder()
	f.h.s.Router().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		return fmt.Errorf("GET %s status %d", path, rec.Code)
	}
	return json.Unmarshal(rec.Body.Bytes(), out)
}

func (f *t18Fixture) snapshot(phase string) (t18Snapshot, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	snapshot, ok := f.snapshots[phase]
	return snapshot, ok
}

func (f *t18Fixture) activationCount() (total int, single map[string]int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	single = make(map[string]int, len(f.activates))
	for id, n := range f.activates {
		single[id] = n
		total += n
	}
	return total, single
}

func TestT18SelectionRenewalJourney(t *testing.T) {
	if os.Getenv("T18_DISPOSABLE") != "yes" {
		t.Fatal("T18_DISPOSABLE=yes is required; run app/tool/t18/verify_selection.sh")
	}
	for _, name := range []string{"DATABASE_URL", "REDIS_URL", "LEDGER_URL"} {
		raw := os.Getenv(name)
		u, err := url.Parse(raw)
		if err != nil || u.Hostname() == "" {
			t.Fatalf("%s must be a loopback URL", name)
		}
		host := u.Hostname()
		if host != "127.0.0.1" && host != "::1" && host != "localhost" {
			t.Fatalf("%s must point at a loopback fixture", name)
		}
	}

	// Locate the normal checkout from this test's own source and require the
	// Flutter SDK on PATH; the runner never forwards a card directory or any
	// pre-existing database/Redis connection string.
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the T18 test source")
	}
	appDir := filepath.Join(filepath.Dir(source), "..", "..", "..", "app")
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatalf("flutter must be on PATH: %v", err)
	}
	for _, path := range []string{
		filepath.Join(appDir, t18FlutterTest),
		filepath.Join(appDir, ".dart_tool", "package_config.json"),
		flutter,
	} {
		if info, err := os.Stat(path); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("Flutter prerequisite missing: %s", path)
		}
	}

	h := newPracticeWireWithContext(t, t.Context())
	h.must(h.s.Health(t.Context()))

	subject := uuid.NewString()
	loginTicket := uuid.NewString()
	h.must(h.s.cache.Set(t.Context(), "dev:ticket:apple:"+loginTicket, subject, time.Minute).Err())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.s.cache.Del(ctx, "dev:ticket:apple:"+loginTicket).Err()
	})
	var account app.Tokens
	h.json("", http.MethodPost, "auth/login", map[string]any{
		"credential":      map[string]string{"provider": "apple", "proof": loginTicket},
		"age_confirmed":   true,
		"terms_version":   "2026-11",
		"privacy_version": "2026-11",
	}, http.StatusOK, &account)
	h.json(account.AccessToken, http.MethodPut, "me/consents/contacts", map[string]any{
		"version": "2026-11", "granted": true,
	}, http.StatusOK, nil)
	h.json(account.AccessToken, http.MethodPut, "me/consents/practice", map[string]any{
		"version": "v1", "granted": true,
	}, http.StatusOK, nil)

	// FIXTURE: a synthetic member interval grants both contacts write access.
	// No payment, merchant or purchase endpoint is called.
	h.exec(`with o as (
		insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
		values($1,'apple',$2,'fixture',1,'paid') returning id,user_id
	) insert into entitlements select id,user_id,now()-interval '2 days',now()+interval '1 day' from o`,
		account.UserId, []byte(uuid.NewString()))

	var first, second app.Contact
	h.json(account.AccessToken, http.MethodPost, "contacts", map[string]string{
		"nickname": "合成甲", "scene": "work",
	}, http.StatusOK, &first)
	h.json(account.AccessToken, http.MethodPost, "contacts", map[string]string{
		"nickname": "合成乙", "scene": "work",
	}, http.StatusOK, &second)
	if !first.Editable || !second.Editable {
		t.Fatal("the synthetic member interval must leave both contacts writable")
	}
	// The explicit activate endpoint is intentionally not used. Instead one
	// normal practice request that names 合成乙 must be the product path that
	// records the recent use. The scripted provider is this card's local
	// fixture; no external model is contacted and no formal opening UI runs.
	if beforeFirst, beforeSecond := t18LastUsed(t, h, account.UserId, first.Id), t18LastUsed(t, h, account.UserId, second.Id); beforeFirst != nil || beforeSecond != nil {
		t.Fatal("both contacts must start without a recent-use timestamp")
	}
	sessionID := uuid.New()
	h.json(account.AccessToken, http.MethodPost, "sessions", map[string]any{
		"request_id": sessionID,
		"contact_id": second.Id,
		"scene":      "work",
		"scenario":   "合成对练场景",
	}, http.StatusOK, nil)
	// Starting the session is not product "use": only the actual practice turn
	// below may record the selected contact.
	if firstUsed, secondUsed := t18LastUsed(t, h, account.UserId, first.Id), t18LastUsed(t, h, account.UserId, second.Id); firstUsed != nil || secondUsed != nil {
		t.Fatal("creating a practice session alone must not record recent use")
	}
	h.frames(account, "sessions/"+sessionID.String(), uuid.NewString(), "fragment", "fragment", "reply_saved")
	if firstUsed, secondUsed := t18LastUsed(t, h, account.UserId, first.Id), t18LastUsed(t, h, account.UserId, second.Id); firstUsed != nil || secondUsed == nil {
		t.Fatal("the successful practice request must record 合成乙 as recently used and leave 合成甲 untouched")
	}
	t.Logf("PASS(service.recent-use)")

	fixtureSecret := uuid.NewString()
	fixture := newT18Fixture(h, account.AccessToken, account.UserId, fixtureSecret)
	wrapped := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == t18FixtureAdvance {
			fixture.advance(w, r)
			return
		}
		fixture.countActivate(r)
		h.s.Router().ServeHTTP(w, r)
	}))
	t.Cleanup(wrapped.Close)

	flutterTicket := uuid.NewString()
	h.must(h.s.cache.Set(t.Context(), "dev:ticket:apple:"+flutterTicket, subject, 8*time.Minute).Err())
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = h.s.cache.Del(ctx, "dev:ticket:apple:"+flutterTicket).Err()
	})

	ctx, cancel := context.WithTimeout(t.Context(), 6*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, flutter, "--no-version-check", "test", "--no-pub", "--reporter", "expanded", t18FlutterTest)
	cmd.Dir = appDir
	cmd.WaitDelay = 5 * time.Second
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.Env = t18FlutterEnv(wrapped.URL, flutterTicket, fixtureSecret)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	runErr := cmd.Run()
	if runErr != nil {
		stage := t18LastStage(output.String())
		if ctx.Err() != nil {
			t.Fatalf("Flutter selection journey terminated (%s, 阶段 %s)", ctx.Err(), stage)
		}
		var exitErr *exec.ExitError
		if errors.As(runErr, &exitErr) {
			t.Fatalf("Flutter selection journey failed (exit=%d, 阶段 %s, 改选请求=%d)",
				exitErr.ExitCode(), stage, t18ActivationTotal(fixture))
		}
		t.Fatalf("could not run the Flutter selection journey (%s, 阶段 %s)", runErr, stage)
	}
	if !strings.Contains(output.String(), "T18_STAGE complete") {
		t.Fatalf("Flutter selection journey exited without its completion receipt (阶段 %s)", t18LastStage(output.String()))
	}
	t.Logf("PASS(page.journey)")

	expired, ok := fixture.snapshot("expire")
	if !ok {
		t.Fatal("the expiry fixture did not record a Go list readback")
	}
	if expired.Tier != "free" || expired.MaxActiveContacts == nil || *expired.MaxActiveContacts != 1 {
		t.Fatalf("expiry readback tier=%q limit=%v; want free with one contact", expired.Tier, expired.MaxActiveContacts)
	}
	if got := strings.Join(expired.Editable, ","); got != second.Id.String() {
		t.Fatal("expiry readback must leave only the most recently used contact writable")
	}

	renewed, ok := fixture.snapshot("renew")
	if !ok {
		t.Fatal("the renewal fixture did not record a Go list readback")
	}
	if renewed.Tier != "member" {
		t.Fatalf("renewal readback tier=%q; want member", renewed.Tier)
	}
	wantBoth := []string{first.Id.String(), second.Id.String()}
	sort.Strings(wantBoth)
	if strings.Join(renewed.Editable, ",") != strings.Join(wantBoth, ",") {
		t.Fatal("renewal readback must restore both contacts as writable")
	}

	total, perContact := fixture.activationCount()
	if total != 1 || perContact[first.Id.String()] != 1 || perContact[second.Id.String()] != 0 {
		t.Fatalf("exactly one actual selection request must reach the product route; total=%d", total)
	}

	firstUsed, secondUsed := t18LastUsed(t, h, account.UserId, first.Id), t18LastUsed(t, h, account.UserId, second.Id)
	if firstUsed == nil || secondUsed == nil || !firstUsed.After(*secondUsed) {
		t.Fatal("the confirmed change of contact must make 合成甲 the most recently used contact")
	}

	var entitlements app.Entitlements
	h.json(account.AccessToken, http.MethodGet, "entitlements", nil, http.StatusOK, &entitlements)
	var contacts app.ListContactsResult
	h.json(account.AccessToken, http.MethodGet, "contacts?limit=100", nil, http.StatusOK, &contacts)
	if entitlements.Tier != app.EntitlementsTierMember || len(contacts.Items) != 2 {
		t.Fatalf("final readback tier=%q contacts=%d; want member with two contacts", entitlements.Tier, len(contacts.Items))
	}
	for _, contact := range contacts.Items {
		if !contact.Editable {
			t.Fatal("final Go list readback must mark both renewed contacts writable")
		}
	}
	t.Logf("PASS(go.journey)")
	t.Logf("stage=complete fixture_expire_editable=%d fixture_renew_editable=%d selection_requests=%d",
		len(expired.Editable), len(renewed.Editable), total)
}

// t18LastUsed only reads the product-maintained value. The test never writes
// last_used_at with SQL.
func t18LastUsed(t *testing.T, h *practiceWire, user, contact uuid.UUID) *time.Time {
	t.Helper()
	var value *time.Time
	h.must(h.s.db.QueryRow(t.Context(), `select last_used_at from contacts where user_id=$1 and id=$2`, user, contact).Scan(&value))
	return value
}

func t18ActivationTotal(fixture *t18Fixture) int {
	total, _ := fixture.activationCount()
	return total
}

func t18LastStage(output string) string {
	last := "unreported"
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, "T18_STAGE ") {
			last = strings.TrimSpace(strings.TrimPrefix(line, "T18_STAGE "))
		}
	}
	return last
}

func t18FlutterEnv(origin, ticket, fixture string) []string {
	var env []string
	for _, key := range []string{
		"PATH", "HOME", "TMPDIR", "TMP", "TEMP", "PUB_CACHE", "FLUTTER_ROOT",
		"FLUTTER_ALREADY_LOCKED", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
		"GIT_OPTIONAL_LOCKS", "XDG_CACHE_HOME", "XDG_CONFIG_HOME",
		"CI", "FLUTTER_SUPPRESS_ANALYTICS", "DART_SUPPRESS_ANALYTICS",
		"LANG", "LC_ALL",
	} {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}
	return append(env,
		"T18_ORIGIN="+origin,
		"T18_TICKET="+ticket,
		"T18_FIXTURE="+fixture,
	)
}
