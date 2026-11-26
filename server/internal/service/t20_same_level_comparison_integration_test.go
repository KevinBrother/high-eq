//go:build integration && t20compare

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
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

	"high-eq/server/internal/training"
)

const (
	t20CompareFlutter = "tool/t20/same_level_comparison_test.dart"
	t20CompareLimit   = 6 * time.Minute
)

type t20Reads struct {
	mu     sync.Mutex
	list   int
	detail map[string]int
}

func (r *t20Reads) record(method, path string) {
	if method != http.MethodGet {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if path == "/v1/sessions" {
		r.list++
		return
	}
	if id, ok := strings.CutPrefix(path, "/v1/sessions/"); ok && !strings.Contains(id, "/") {
		r.detail[id]++
	}
}

func (r *t20Reads) snapshot(id string) (int, int) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.list, r.detail[id]
}

// T20 acceptance, real wire: one synthetic already-consented user owns two
// completed single-skill sessions on the same level and target plus one newer
// completed session at a different level. The shipped Flutter lobby opens the
// second session from its history page; the comparison score is read from the
// session list, never supplied to the result widget. Only the TLS model,
// moderation and scoring upstream is scripted and loopback-only.
//
// The separate integration && t20compare tag keeps this off ordinary runs. A
// missing prerequisite fails; it never turns into a skipped "green".
func TestT20SameLevelResultComparison(t *testing.T) {
	if os.Getenv("T20_DISPOSABLE") != "yes" {
		t.Fatal("T20_DISPOSABLE=yes is required for disposable loopback stores")
	}
	if os.Getenv("T19_DISPOSABLE") != "yes" {
		t.Fatal("the shared practice fixture requires T19_DISPOSABLE=yes")
	}

	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the T20 comparison test source")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(source), "..", "..", ".."))
	appDir := filepath.Join(repoRoot, "app")
	pageTest := filepath.Join("tool", "t20", "same_level_comparison_test.dart")
	if info, err := os.Stat(filepath.Join(appDir, pageTest)); err != nil || !info.Mode().IsRegular() {
		t.Fatal("T20 Flutter history/result check is missing from the checkout")
	}

	h := newPracticeWire(t)
	user := h.user()

	// Deterministic synthetic completions created through the real HTTP router
	// before the page opens. They are fixture data for this round, not model
	// output: first_score=15 and second_score=25 come from the loopback scorer.
	// The control level is appended only in t20compare binaries, so it keeps the
	// same single_skill mode and observation target while changing the level.
	controlLevel := training.AddT20CompareObservationLevel()
	completed := func(path, text, mode string) training.Session {
		t.Helper()
		h.framesWithMessage(
			user, path,
			map[string]string{"client_message_id": uuid.NewString(), "text": text},
			"fragment", "fragment", "reply_saved",
		)
		h.set(mode)
		h.json(user.AccessToken, "POST", path+"/finish", nil, 200, nil)
		h.set("")
		session := h.history(user, path)
		if session.Status != "complete" || session.Result == nil {
			t.Fatalf("%s did not complete", text)
		}
		return session
	}
	first := completed(h.create(user, 1), "第一场同关发言", "first_score")
	second := completed(h.create(user, 1), "第二场合成发言", "second_score")
	control := completed(h.createLevel(user, controlLevel), "第三场另关发言", "first_score")

	if first.Result.Progress == nil || second.Result.Progress == nil ||
		first.Result.Progress.Score != 15 || second.Result.Progress.Score != 25 {
		t.Fatalf("single-skill scores = %+v / %+v, want 15 / 25",
			first.Result.Progress, second.Result.Progress)
	}
	if first.Level == nil || second.Level == nil || *first.Level != *second.Level ||
		first.Mode != "single_skill" || second.Mode != "single_skill" ||
		first.Target == nil || second.Target == nil || *first.Target != *second.Target {
		t.Fatal("the two compared completions are not the same level, mode and target")
	}
	if control.Level == nil || *control.Level == *first.Level ||
		control.Mode != "single_skill" || control.Target == nil || *control.Target != *first.Target ||
		control.Result.Progress == nil {
		t.Fatal("the control must be a different level with the same single_skill mode and target")
	}
	if first.ID == second.ID || second.ID == control.ID {
		t.Fatal("fixture sessions must be distinct")
	}

	reads := &t20Reads{detail: map[string]int{}}
	backend, err := url.Parse(h.api.URL)
	if err != nil {
		t.Fatal("could not resolve the fixture API origin")
	}
	proxy := httputil.NewSingleHostReverseProxy(backend)
	wrapped := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		reads.record(r.Method, r.URL.Path)
		proxy.ServeHTTP(w, r)
	}))
	t.Cleanup(wrapped.Close)

	tokensJSON, err := json.Marshal(user)
	if err != nil {
		t.Fatal(err)
	}
	receipt := filepath.Join(t.TempDir(), "t20-comparison-receipt.json")
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	runCtx, cancel := context.WithTimeout(h.ctx, t20CompareLimit)
	defer cancel()
	cmd := exec.CommandContext(runCtx, flutter, "--no-version-check", "test", "--no-pub", "--reporter", "expanded", pageTest)
	cmd.Dir = appDir
	cmd.WaitDelay = 5 * time.Second
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.Env = t20CompareEnv(wrapped.URL, string(tokensJSON), receipt)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	runErr := cmd.Run()
	if runErr != nil {
		t.Logf("Flutter output:\n%s", t20Tail(output.String(), 80))
		var exitErr *exec.ExitError
		if runCtx.Err() != nil {
			t.Fatalf("Flutter history/result journey terminated (%s)", runCtx.Err())
		}
		if errors.As(runErr, &exitErr) {
			t.Fatalf("Flutter history/result journey failed (exit=%d)", exitErr.ExitCode())
		}
		t.Fatalf("could not run the Flutter history/result journey (%s)", runErr)
	}

	type rendered struct {
		Text           string  `json:"text"`
		Left           float64 `json:"left"`
		Top            float64 `json:"top"`
		Right          float64 `json:"right"`
		Bottom         float64 `json:"bottom"`
		InsideViewport bool    `json:"inside_viewport"`
		HitTestable    bool    `json:"hit_testable"`
	}
	var shown struct {
		SameLevel      rendered `json:"same_level"`
		DifferentLevel rendered `json:"different_level"`
		ReturnedLobby  bool     `json:"returned_to_lobby"`
		ReturnedHome   bool     `json:"returned_to_home"`
	}
	raw, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatalf("the Flutter page returned no comparison receipt: %v", err)
	}
	if err := json.Unmarshal(raw, &shown); err != nil {
		t.Fatalf("comparison receipt = %q", raw)
	}
	if shown.SameLevel.Text != "上次 15 → 本次 25（+10 分）" {
		t.Fatalf("same-level comparison on screen = %q", shown.SameLevel.Text)
	}
	if shown.DifferentLevel.Text != "暂无可比的上次成绩" {
		t.Fatalf("different-level control on screen = %q", shown.DifferentLevel.Text)
	}
	for label, row := range map[string]rendered{"same": shown.SameLevel, "control": shown.DifferentLevel} {
		if !row.InsideViewport || !row.HitTestable || row.Right <= row.Left || row.Bottom <= row.Top {
			t.Fatalf("%s comparison was not a rendered, visible, hit-testable line: %+v", label, row)
		}
	}
	if !shown.ReturnedLobby || !shown.ReturnedHome {
		t.Fatal("the journey did not return through the lobby to the real practice home")
	}

	// The lobby read its own history list and the second session's detail.
	// It did not receive the prior score as a widget argument or a direct read.
	listReads, secondReads := reads.snapshot(second.ID.String())
	_, controlReads := reads.snapshot(control.ID.String())
	_, firstReads := reads.snapshot(first.ID.String())
	if listReads == 0 || secondReads == 0 || controlReads == 0 {
		t.Fatalf("page reads list=%d second=%d control=%d", listReads, secondReads, controlReads)
	}
	if firstReads != 0 {
		t.Fatalf("page read the predecessor detail %d times; comparison must come from the history list", firstReads)
	}

	// Re-read the same backend after the page closed: different real sessions
	// and scores, and the control is a different level.
	var listed training.Page
	h.json(user.AccessToken, "GET", "sessions", nil, 200, &listed)
	var seenFirst, seenSecond, seenControl *training.SessionSummary
	for i := range listed.Items {
		switch listed.Items[i].ID {
		case first.ID:
			seenFirst = &listed.Items[i]
		case second.ID:
			seenSecond = &listed.Items[i]
		case control.ID:
			seenControl = &listed.Items[i]
		}
	}
	if seenFirst == nil || seenSecond == nil || seenControl == nil ||
		seenFirst.Result == nil || seenSecond.Result == nil ||
		seenControl.Result == nil || seenFirst.Result.Progress == nil ||
		seenSecond.Result.Progress == nil || seenControl.Result.Progress == nil ||
		seenFirst.Result.Progress.Score != 15 || seenSecond.Result.Progress.Score != 25 {
		t.Fatal("the history list did not expose the two distinct prior scores")
	}
	var prior training.Session
	h.json(user.AccessToken, "GET", "sessions/"+first.ID.String(), nil, 200, &prior)
	if prior.Result == nil || prior.Result.Progress == nil || prior.Result.Progress.Score != 15 {
		t.Fatal("the predecessor's stored score was not 15")
	}

	// Discrimination check over the same real history list: the lobby's actual
	// predicate (complete + same mode + same level) must select nothing for the
	// control. Dropping only the level condition would select the newer
	// same-mode second session and show its 25 as if it belonged to this level.
	index := func(id uuid.UUID) int {
		for i := range listed.Items {
			if listed.Items[i].ID == id {
				return i
			}
		}
		return -1
	}
	older := func(from int, level *uuid.UUID) *training.SessionSummary {
		for i := from + 1; i < len(listed.Items); i++ {
			row := &listed.Items[i]
			if row.Status != "complete" || row.Mode != "single_skill" {
				continue
			}
			if level != nil && (row.Level == nil || *row.Level != *level) {
				continue
			}
			return row
		}
		return nil
	}
	secondIndex := index(second.ID)
	if secondIndex < 0 {
		t.Fatal("the second session is missing from the history list")
	}
	sameLevelPrior := older(secondIndex, second.Level)
	if sameLevelPrior == nil || sameLevelPrior.ID != first.ID {
		t.Fatal("the same-level lookup did not resolve the predecessor")
	}
	controlIndex := index(control.ID)
	if controlIndex < 0 {
		t.Fatal("the control session is missing from the history list")
	}
	if filtered := older(controlIndex, control.Level); filtered != nil {
		t.Fatalf("the control unexpectedly found a same-level prior %s", filtered.ID)
	}
	unfiltered := older(controlIndex, nil)
	if unfiltered == nil || unfiltered.ID != second.ID ||
		unfiltered.Result == nil || unfiltered.Result.Progress == nil ||
		unfiltered.Result.Progress.Score == control.Result.Progress.Score {
		t.Fatal("without the level condition the control would not capture a wrong comparison")
	}

	t.Logf("T20 comparison: first=%s/%d second=%s/%d control=%s/%d same_level_target=%s list_reads=%d second_detail=%d first_detail=%d screen=%q control_screen=%q unfiltered_would_pick=%s/%d",
		seenFirst.ID, seenFirst.Result.Progress.Score,
		seenSecond.ID, seenSecond.Result.Progress.Score,
		seenControl.ID, seenControl.Result.Progress.Score,
		*first.Target, listReads, secondReads, firstReads,
		shown.SameLevel.Text, shown.DifferentLevel.Text, unfiltered.ID, unfiltered.Result.Progress.Score)
}

func t20CompareEnv(origin, tokens, receipt string) []string {
	var env []string
	for _, key := range []string{
		"PATH", "HOME", "TMPDIR", "TMP", "TEMP", "PUB_CACHE", "FLUTTER_ROOT",
		"FLUTTER_ALREADY_LOCKED", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM",
		"GIT_OPTIONAL_LOCKS", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
		"XDG_STATE_HOME", "XDG_RUNTIME_DIR", "CI", "FLUTTER_SUPPRESS_ANALYTICS",
		"DART_SUPPRESS_ANALYTICS", "LANG", "LC_ALL",
	} {
		if value, ok := os.LookupEnv(key); ok {
			env = append(env, key+"="+value)
		}
	}
	return append(env,
		"T20_ORIGIN="+origin,
		"T20_TOKENS="+tokens,
		"T20_RECEIPT="+receipt,
	)
}

func t20Tail(output string, lines int) string {
	all := strings.Split(strings.TrimRight(output, "\n"), "\n")
	if len(all) <= lines {
		return strings.Join(all, "\n")
	}
	return fmt.Sprintf("... %d earlier lines omitted\n%s", len(all)-lines, strings.Join(all[len(all)-lines:], "\n"))
}
