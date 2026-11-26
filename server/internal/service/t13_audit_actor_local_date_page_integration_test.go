//go:build integration && t13audit

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
)

// T13 acceptance, real page: a synthetic super administrator signs in through
// the shipped admin login handler. The shipped /audit Workspace page is then
// driven over real loopback HTTP: it types one operator UUID, picks one local
// natural day in its date range picker, and presses "查询". The Go parent takes
// the exact request the page sent, reads the synthetic audit rows PG returns
// for that request, and compares them with the text the page rendered.
//
// Two controls make relaxing either filter observable: the same operator on the
// wrong day (and exactly at the next local midnight, proving [from,until) is
// half-open), and another operator on the selected day. The page's from/until
// must equal the selected local midnights converted to server instants.
//
// The integration && t13audit tag keeps this out of ordinary runs. A missing
// prerequisite fails; it never turns into a skipped "green".
func TestT13AuditActorAndLocalDatePage(t *testing.T) {
	if os.Getenv("T13_DISPOSABLE") != "yes" {
		t.Fatal("T13_DISPOSABLE=yes is required for disposable loopback stores")
	}
	ctx := t.Context()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatalf("start service: %v", err)
	}
	defer s.Close()

	// Record every real /audit request in order. The page's own client marks the
	// click boundary, so the assertions can identify the request the "查询" click
	// produced instead of assuming the last request of the whole run.
	var queryMu sync.Mutex
	var auditQueries []string
	router := s.Router()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/admin/v1/audit-logs" {
			queryMu.Lock()
			auditQueries = append(auditQueries, r.URL.RawQuery)
			queryMu.Unlock()
		}
		router.ServeHTTP(w, r)
	}))
	defer server.Close()

	client := server.Client()
	call := func(method, path, token string, in, out any, want int) {
		t.Helper()
		body := bytes.NewReader(nil)
		if in != nil {
			data, err := json.Marshal(in)
			if err != nil {
				t.Fatal("encode request")
			}
			body = bytes.NewReader(data)
		}
		req, err := http.NewRequestWithContext(ctx, method, server.URL+path, body)
		if err != nil {
			t.Fatalf("%s %s: build request: %v", method, path, err)
		}
		if in != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("%s %s: request failed: %v", method, path, err)
		}
		defer resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("%s %s: status %d, want %d", method, path, resp.StatusCode, want)
		}
		if out != nil {
			if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
				t.Fatalf("%s %s: decode response: %v", method, path, err)
			}
		}
	}

	const password = "t13-fixture-password"
	suffix := strings.ReplaceAll(uuid.NewString(), "-", "")[:12]
	actorA, err := adminops.Provision(ctx, s.db, "t13audit-a-"+suffix, password, "operator")
	if err != nil {
		t.Fatalf("provision synthetic operator A: %v", err)
	}
	actorB, err := adminops.Provision(ctx, s.db, "t13audit-b-"+suffix, password, "operator")
	if err != nil {
		t.Fatalf("provision synthetic operator B: %v", err)
	}
	rootLogin := "t13audit-root-" + suffix
	if _, err := adminops.Provision(ctx, s.db, rootLogin, password, "super_admin"); err != nil {
		t.Fatalf("provision synthetic super administrator: %v", err)
	}

	// The selected operator must also have an audit row from its own normal
	// sign-in; but login rows belong to the logged-in root, so the queried day
	// is yesterday and never races with today's provisioning traffic.
	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	day := today.AddDate(0, 0, -1)
	next := day.AddDate(0, 0, 1)

	insert := func(actor uuid.UUID, at time.Time, action, target, result string) uuid.UUID {
		t.Helper()
		var id uuid.UUID
		if err := s.db.QueryRow(ctx, `insert into admin_audit_logs(actor_id,occurred_at,action,target,result)
			values($1,$2,$3,$4,$5) returning id`, actor, at, action, target, result).Scan(&id); err != nil {
			t.Fatalf("seed synthetic audit row: %v", err)
		}
		return id
	}
	const actionRelease, actionVersion, targetName = "setPromptRelease", "createPromptVersion", "prompts"
	targetID := insert(actorA, day, actionRelease, targetName, "ok")
	insert(actorA, day.Add(-time.Microsecond), actionVersion, targetName, "failed") // same actor, wrong day
	insert(actorA, next, actionVersion, targetName, "ok")                          // at the exclusive until bound
	insert(actorB, time.Date(day.Year(), day.Month(), day.Day(), 12, 0, 0, 0, day.Location()), actionVersion, targetName, "ok")

	var session admin.AdminSession
	call(http.MethodPost, "/admin/v1/auth/login", "", admin.AdminLoginJSONBody{
		Login: rootLogin, Password: password,
	}, &session, http.StatusOK)
	if session.AccessToken == "" || session.Role != admin.AdminSessionRoleSuperAdmin {
		t.Fatalf("synthetic super administrator session not issued: role=%q", session.Role)
	}

	// Derive the checkout from this source file instead of taking a machine
	// path or a caller-supplied card root.
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the T13 test source")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(source), "..", "..", ".."))
	adminDir := filepath.Join(repoRoot, "admin")
	pageTest := filepath.Join("tool", "t13", "audit_live_test.dart")
	for _, name := range []string{pageTest, ".dart_tool/package_config.json"} {
		if info, err := os.Stat(filepath.Join(adminDir, name)); err != nil || !info.Mode().IsRegular() {
			t.Fatalf("T13 Flutter /audit page prerequisite missing: admin/%s", filepath.ToSlash(name))
		}
	}
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	runCtx, cancel := context.WithTimeout(ctx, 6*time.Minute)
	defer cancel()
	receipt := filepath.Join(t.TempDir(), "audit-receipt.json")
	cmd := exec.CommandContext(runCtx, flutter, "test", "--no-pub", "-r", "expanded", pageTest)
	cmd.Dir = adminDir
	cmd.Env = append(os.Environ(),
		"T13_ADMIN_ORIGIN="+server.URL,
		"T13_ADMIN_TOKEN="+session.AccessToken,
		"T13_ACTOR_ID="+actorA.String(),
		"T13_DAY="+day.Format("2006-01-02"),
		"T13_RECEIPT="+receipt,
	)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Run(); err != nil {
		t.Fatalf("T13 Flutter /audit page stopped the flow (exit=%v): %s",
			err, t13AuditRedact(output.String(), session.AccessToken, server.URL))
	}

	// The receipt carries each visible result Card's three fields and the
	// page-client GET boundary around "查询". The click-triggered query string
	// must equal the real request the service recorded at that boundary.
	type receiptRow struct {
		Title     string `json:"title"`
		Time      string `json:"time"`
		Selection string `json:"selection"`
	}
	var shown struct {
		Rows   []receiptRow `json:"rows"`
		Before []string     `json:"audit_gets_before_click"`
		During []string     `json:"audit_gets_during_click_release"`
		After  []string     `json:"audit_gets_after_click"`
	}
	raw, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatal("T13 Flutter /audit page finished without a receipt")
	}
	if err := json.Unmarshal(raw, &shown); err != nil {
		t.Fatal("T13 Flutter /audit receipt is not readable")
	}
	queryMu.Lock()
	recorded := append([]string(nil), auditQueries...)
	queryMu.Unlock()
	// Before the click: exactly the page's initialization read, with no actor
	// or date filters of its own.
	if len(shown.Before) != 1 {
		t.Fatalf("the /audit page made %d audit GETs before the 查询 click, want only the initialization GET: %v",
			len(shown.Before), shown.Before)
	}
	initial, err := url.ParseQuery(shown.Before[0])
	if err != nil {
		t.Fatalf("the initialization audit query is unreadable: %v", err)
	}
	for _, key := range []string{"actor_id", "from", "until"} {
		if initial.Has(key) {
			t.Fatalf("the initialization audit GET already carried %s: %q", key, shown.Before[0])
		}
	}
	// The pointer-release segment, with the test clock frozen and no pump in
	// between, produced exactly one request. A delayed date-confirm task cannot
	// account for it.
	if len(shown.During) != 1 {
		t.Fatalf("the 查询 gesture release produced %d audit GETs, want exactly 1: %v",
			len(shown.During), shown.During)
	}
	if len(shown.After) != 1 {
		t.Fatalf("the post-click window produced %d audit GETs, want exactly 1: %v",
			len(shown.After), shown.After)
	}
	if shown.During[0] != shown.After[0] {
		t.Fatalf("the release request %q differs from the settled request %q",
			shown.During[0], shown.After[0])
	}
	if len(recorded) != len(shown.Before)+len(shown.After) {
		t.Fatalf("audit GET count mismatch: page recorded %d initialization + %d click, service saw %d: %v",
			len(shown.Before), len(shown.After), len(recorded), recorded)
	}
	for i, want := range shown.Before {
		if recorded[i] != want {
			t.Fatalf("audit GET %d before the click is %q, page recorded %q", i, recorded[i], want)
		}
	}
	clickQuery := shown.After[0]
	if recorded[len(shown.Before)] != clickQuery {
		t.Fatalf("audit GET at the click boundary is %q, page recorded %q",
			recorded[len(shown.Before)], clickQuery)
	}
	t.Logf("T13 /audit GET boundary: initialization=%d click-release=%d after-click=%d total=%d",
		len(shown.Before), len(shown.During), len(shown.After), len(recorded))
	t.Logf("T13 /audit initialization GET query=%q", shown.Before[0])
	t.Logf("T13 /audit click-release GET query=%q", clickQuery)

	filters, err := url.ParseQuery(clickQuery)
	if err != nil {
		t.Fatal("the /audit page sent an unreadable audit query")
	}
	if got := filters.Get("actor_id"); got != actorA.String() {
		t.Fatalf("/audit page selected actor_id=%q, want %q", got, actorA)
	}
	from, err := time.Parse(time.RFC3339Nano, filters.Get("from"))
	if err != nil {
		t.Fatalf("/audit page sent an unreadable from bound: %v", err)
	}
	until, err := time.Parse(time.RFC3339Nano, filters.Get("until"))
	if err != nil {
		t.Fatalf("/audit page sent an unreadable until bound: %v", err)
	}
	// The picker works in local calendar days; the click-triggered request must
	// carry exactly the two local midnights converted to server instants.
	if !from.Equal(day) || !until.Equal(next) {
		t.Fatalf("/audit page sent [%s,%s), want local midnights [%s,%s)",
			from.UTC(), until.UTC(), day.UTC(), next.UTC())
	}

	// Reconcile every visible row with PG under the click request's conditions,
	// not a re-derived window.
	type row struct {
		id     uuid.UUID
		actor  uuid.UUID
		at     time.Time
		action string
		target string
		result string
	}
	var rows []row
	result, err := s.db.Query(ctx, `select id,actor_id,occurred_at,action,target,result from admin_audit_logs
		where actor_id=$1 and occurred_at>=$2 and occurred_at<$3 order by occurred_at desc,id desc`,
		actorA, from, until)
	if err != nil {
		t.Fatalf("could not read the selected audit window: %v", err)
	}
	defer result.Close()
	for result.Next() {
		var v row
		if err := result.Scan(&v.id, &v.actor, &v.at, &v.action, &v.target, &v.result); err != nil {
			t.Fatalf("could not scan the selected audit window: %v", err)
		}
		rows = append(rows, v)
	}
	if err := result.Err(); err != nil {
		t.Fatalf("could not read the selected audit window: %v", err)
	}
	if len(rows) != 1 || rows[0].id != targetID {
		t.Fatalf("selected window should hold exactly the synthetic target row %s, got %+v", targetID, rows)
	}

	// Controls: dropping either filter must return more than the selected row.
	var sameActor, sameDay int
	if err := s.db.QueryRow(ctx, `select count(*) from admin_audit_logs where actor_id=$1`, actorA).Scan(&sameActor); err != nil {
		t.Fatalf("could not count same-actor rows: %v", err)
	}
	if err := s.db.QueryRow(ctx, `select count(*) from admin_audit_logs where occurred_at>=$1 and occurred_at<$2`,
		day, next).Scan(&sameDay); err != nil {
		t.Fatalf("could not count same-day rows: %v", err)
	}
	if sameActor != 3 || sameDay != 2 {
		t.Fatalf("controls are not discriminating: same-actor=%d (want 3), same-day=%d (want 2)",
			sameActor, sameDay)
	}

	if len(shown.Rows) != len(rows) {
		t.Fatalf("/audit page rendered %d rows, PG has %d under the click request: rendered=%+v pg=%+v",
			len(shown.Rows), len(rows), shown.Rows, rows)
	}
	labels := map[string]string{"ok": "成功", "denied": "拒绝", "failed": "失败"}
	for i, want := range rows {
		label, ok := labels[want.result]
		if !ok {
			t.Fatalf("synthetic audit row has an unexpected result %q", want.result)
		}
		expected := receiptRow{
			Title:     label + "  ·  " + want.action,
			Time:      want.at.In(time.Local).Format("2006-01-02 15:04:05"),
			Selection: fmt.Sprintf("操作人：%s\n对象：%s", want.actor, want.target),
		}
		if shown.Rows[i] != expected {
			t.Fatalf("/audit row %d rendered %+v, want %+v", i, shown.Rows[i], expected)
		}
	}
	t.Logf("T13 /audit real page: actor=%s day=%s window=[%s,%s) rows=%d row=%s action=%s target=%s result=%s",
		actorA, day.Format("2006-01-02"), from.UTC(), until.UTC(), len(rows),
		rows[0].id, rows[0].action, rows[0].target, rows[0].result)
}

// t13AuditRedact keeps a bounded diagnostic tail without the session token or
// the loopback origin.
func t13AuditRedact(output, token, origin string) string {
	output = strings.ReplaceAll(output, token, "[redacted]")
	output = strings.ReplaceAll(output, origin, "[redacted]")
	if len(output) > 4000 {
		output = output[len(output)-4000:]
	}
	return output
}
