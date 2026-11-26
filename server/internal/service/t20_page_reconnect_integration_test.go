//go:build integration && t20reconnect

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

const (
	t20ReconnectLimit    = 6 * time.Minute
	t20ReconnectUserText = "断线后还能看到这句话吗？"
)

type t20ReconnectRendered struct {
	Text           string  `json:"text"`
	Left           float64 `json:"left"`
	Top            float64 `json:"top"`
	Right          float64 `json:"right"`
	Bottom         float64 `json:"bottom"`
	InsideViewport bool    `json:"inside_viewport"`
	HitTestable    bool    `json:"hit_testable"`
}

type t20ReconnectReceipt struct {
	SessionID               string                `json:"session_id"`
	UserText                string                `json:"user_text"`
	AssistantText           string                `json:"assistant_text"`
	FragmentVisible         bool                  `json:"fragment_visible_before_abort"`
	AbortedMarker           bool                  `json:"aborted_marker"`
	NoticeVisible           bool                  `json:"notice_visible"`
	RecoveryButtonBefore    bool                  `json:"recovery_button_before"`
	AssistantBeforeRecovery bool                  `json:"assistant_before_recovery"`
	Recovered               bool                  `json:"recovered"`
	UserRowsAfter           int                   `json:"user_rows_after"`
	AssistantRowsAfter      int                   `json:"assistant_rows_after"`
	InputEnabledAfter       bool                  `json:"input_enabled_after"`
	RetryVisibleAfter       bool                  `json:"retry_visible_after"`
	SettlementLabel         string                `json:"settlement_label"`
	MessagePosts            int                   `json:"message_posts"`
	SentPaths               []string              `json:"sent_paths"`
	CreatePosts             int                   `json:"create_posts"`
	CreatePaths             []string              `json:"create_paths"`
	SessionGets             []string              `json:"session_gets"`
	UserRendered            t20ReconnectRendered  `json:"user_rendered"`
	AssistantRendered       t20ReconnectRendered  `json:"assistant_rendered"`
}

// T20 acceptance, real wire: one synthetic already-consented user creates one
// ordinary custom practice through the shipped lobby, sends one turn through
// the shipped chat composer, and the test client itself aborts that SSE
// connection after the first fragment but before reply_saved can reach the
// page. The detached production worker still persists the reply through PG and
// charges once. The same page then recovers through its own "恢复会话" button,
// and the rendered user/assistant rows must equal the stored conversation.
//
// Only the loopback scripted role-play/moderation/scoring upstream is used. No
// production route, proxy, fault endpoint, real credential, real network or
// Android device participates.
func TestT20PageReconnectSavedConversation(t *testing.T) {
	if os.Getenv("T20_DISPOSABLE") != "yes" {
		t.Fatal("T20_DISPOSABLE=yes is required for disposable loopback stores")
	}
	if os.Getenv("T19_DISPOSABLE") != "yes" {
		t.Fatal("the shared practice fixture requires T19_DISPOSABLE=yes")
	}

	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the T20 reconnect test source")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(source), "..", "..", ".."))
	appDir := filepath.Join(repoRoot, "app")
	pageTest := filepath.Join("tool", "t20", "page_reconnect_test.dart")
	if info, err := os.Stat(filepath.Join(appDir, pageTest)); err != nil || !info.Mode().IsRegular() {
		t.Fatal("T20 reconnect Flutter page check is missing from the checkout")
	}

	h := newPracticeWire(t)
	user := h.user()
	// Hold the provider after the first fragment so the client can hang up
	// before reply_saved exists. The page writes a marker only after it has
	// witnessed the closed stream; that resumes the loopback scripted provider.
	release := h.hold()
	var releaseOnce sync.Once
	releaseProvider := func() { releaseOnce.Do(release) }
	defer releaseProvider()
	tmp := t.TempDir()
	aborted := filepath.Join(tmp, "t20-reconnect-aborted")
	stopWatcher := make(chan struct{})
	defer close(stopWatcher)
	go func() {
		ticker := time.NewTicker(10 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-stopWatcher:
				return
			case <-ticker.C:
				if _, err := os.Stat(aborted); err == nil {
					releaseProvider()
					return
				}
			}
		}
	}()

	tokensJSON, err := json.Marshal(user)
	if err != nil {
		t.Fatal(err)
	}
	receipt := filepath.Join(tmp, "t20-reconnect-receipt.json")
	phase := filepath.Join(tmp, "t20-reconnect-phase")
	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	runCtx, cancel := context.WithTimeout(h.ctx, t20ReconnectLimit)
	defer cancel()
	cmd := exec.CommandContext(runCtx, flutter, "--no-version-check", "test", "--no-pub", "--reporter", "expanded", pageTest)
	cmd.Dir = appDir
	cmd.WaitDelay = 5 * time.Second
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.Env = t20ReconnectEnv(h.api.URL, string(tokensJSON), receipt, aborted, phase)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	runErr := cmd.Run()
	h.set("")
	if runErr != nil {
		outputLines := bytes.Count(output.Bytes(), []byte("\n"))
		if output.Len() > 0 && output.Bytes()[output.Len()-1] != '\n' {
			outputLines++
		}
		var dbID uuid.UUID
		var dbState string
		if scanErr := h.s.db.QueryRow(h.ctx, `select id,state from activities where user_id=$1 and kind='practice'`, user.UserId).Scan(&dbID, &dbState); scanErr == nil {
			var storedUser, storedAssistant int
			_ = h.s.db.QueryRow(h.ctx, `select count(*) from practice_messages where activity_id=$1 and role='user'`, dbID).Scan(&storedUser)
			_ = h.s.db.QueryRow(h.ctx, `select count(*) from practice_messages where activity_id=$1 and role='assistant'`, dbID).Scan(&storedAssistant)
			t.Logf("DB after Flutter failure: session_present=true state=%s user_rows=%d assistant_rows=%d provider_calls=%d", dbState, storedUser, storedAssistant, h.generations.Load())
		} else {
			t.Logf("DB after Flutter failure: no practice session")
		}
		var exitErr *exec.ExitError
		where := t20ReconnectPhase(phase)
		if runCtx.Err() != nil {
			t.Fatalf("Flutter reconnect journey terminated (%s) phase=%q output_lines=%d", runCtx.Err(), where, outputLines)
		}
		if errors.As(runErr, &exitErr) {
			t.Fatalf("Flutter reconnect journey failed (exit=%d) phase=%q output_lines=%d", exitErr.ExitCode(), where, outputLines)
		}
		t.Fatalf("could not run the Flutter reconnect journey phase=%q output_lines=%d", where, outputLines)
	}

	raw, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatalf("the Flutter page returned no reconnect receipt: %v", err)
	}
	var shown t20ReconnectReceipt
	if err := json.Unmarshal(raw, &shown); err != nil {
		t.Fatalf("the reconnect receipt is not valid JSON (%d bytes)", len(raw))
	}
	sessionID, err := uuid.Parse(shown.SessionID)
	if err != nil {
		t.Fatal("the reconnect receipt has no valid session id")
	}
	path := "sessions/" + shown.SessionID

	if shown.UserText != t20ReconnectUserText {
		t.Fatal("the page sent a different user text")
	}
	if !shown.FragmentVisible {
		t.Fatal("the page never rendered the first streamed fragment")
	}
	if !shown.AbortedMarker {
		t.Fatal("the page did not confirm the client-side disconnect to the scripted provider")
	}
	if !shown.NoticeVisible || !shown.RecoveryButtonBefore {
		t.Fatalf("disconnect state visible=%t recovery=%t, want both true", shown.NoticeVisible, shown.RecoveryButtonBefore)
	}
	if shown.AssistantBeforeRecovery {
		t.Fatal("the page displayed the saved reply before recovery; the disconnect was not before delivery")
	}
	if !shown.Recovered {
		t.Fatal("the page did not recover through its own recovery action")
	}
	if shown.UserRowsAfter != 1 || shown.AssistantRowsAfter != 1 {
		t.Fatalf("rendered rows user=%d assistant=%d, want one each", shown.UserRowsAfter, shown.AssistantRowsAfter)
	}
	if !shown.InputEnabledAfter || shown.RetryVisibleAfter {
		t.Fatalf("after recovery input=%t retry=%t, want input enabled with no retry", shown.InputEnabledAfter, shown.RetryVisibleAfter)
	}
	if shown.SettlementLabel != "本场净扣 1 次" {
		t.Fatal("the settlement line did not show one net charge")
	}
	if shown.MessagePosts != 1 || len(shown.SentPaths) != 1 {
		t.Fatalf("message POSTs = %d, want exactly one", shown.MessagePosts)
	}
	if shown.SentPaths[0] != "/v1/sessions/"+shown.SessionID+"/messages" {
		t.Fatal("the message POST did not target the recovered session")
	}
	if shown.CreatePosts != 1 || len(shown.CreatePaths) != 1 {
		t.Fatalf("session creations = %d, want exactly one", shown.CreatePosts)
	}
	if shown.CreatePaths[0] != "/v1/sessions" {
		t.Fatal("the creation POST did not target the sessions endpoint")
	}
	if len(shown.SessionGets) == 0 {
		t.Fatal("the page did not read the original session during recovery")
	}
	for _, got := range shown.SessionGets {
		if got != "/v1/sessions/"+shown.SessionID {
			t.Fatal("recovery read a session other than the recovered one")
		}
	}
	for label, row := range map[string]t20ReconnectRendered{
		"user":      shown.UserRendered,
		"assistant": shown.AssistantRendered,
	} {
		if !row.InsideViewport || !row.HitTestable || row.Right <= row.Left || row.Bottom <= row.Top {
			t.Fatalf("%s row was not a rendered, visible, hit-testable line", label)
		}
	}
	if shown.UserRendered.Text != shown.UserText {
		t.Fatal("the rendered user row did not match the stored user text")
	}
	if shown.AssistantRendered.Text != shown.AssistantText {
		t.Fatal("the rendered assistant row did not match the stored reply")
	}

	// Read the stored conversation through the product's own owner-only detail
	// endpoint after the page closed. It must be the same session, one user row,
	// one assistant row, one client message id and one net charge.
	saved := h.history(user, path)
	if saved.ID != sessionID {
		t.Fatalf("saved session = %s, want %s", saved.ID, sessionID)
	}
	if saved.Status != "active" || saved.Settlement.Net != 1 {
		t.Fatalf("saved status/settlement = %s/%d, want active/1", saved.Status, saved.Settlement.Net)
	}
	if len(saved.Messages) != 2 {
		t.Fatalf("stored messages = %d, want 2", len(saved.Messages))
	}
	if saved.Messages[0].Role != "user" || saved.Messages[0].Text != t20ReconnectUserText {
		t.Fatal("the stored user row did not match the sent text")
	}
	if saved.Messages[1].Role != "assistant" || saved.Messages[1].Text != shown.AssistantText {
		t.Fatal("the stored assistant row did not match the rendered reply")
	}
	if saved.Messages[0].ClientMessageId == uuid.Nil ||
		saved.Messages[0].ClientMessageId != saved.Messages[1].ClientMessageId {
		t.Fatal("the stored user and assistant rows do not share one non-empty client message id")
	}

	var userRows, assistantRows int
	h.must(h.s.db.QueryRow(h.ctx, `select count(*) from practice_messages where activity_id=$1 and role='user'`, sessionID).Scan(&userRows))
	h.must(h.s.db.QueryRow(h.ctx, `select count(*) from practice_messages where activity_id=$1 and role='assistant'`, sessionID).Scan(&assistantRows))
	if userRows != 1 || assistantRows != 1 {
		t.Fatalf("stored rows user=%d assistant=%d, want one each", userRows, assistantRows)
	}
	if h.generations.Load() != 1 {
		t.Fatalf("role-play provider calls = %d, want 1", h.generations.Load())
	}
	if n := h.number(`select count(*) from activities where user_id=$1 and kind='practice'`, user.UserId); n != 1 {
		t.Fatalf("practice sessions for the account = %d, want 1", n)
	}
	if n := h.number(`select count(*) from quota_ledger where activity_id=$1`, sessionID); n != 1 {
		t.Fatalf("quota ledger rows = %d, want 1", n)
	}
	h.ledger(user, path, "active", 1)

	t.Logf("T20 reconnect: session_present=true message_posts=%d create_posts=%d session_gets=%d provider_calls=%d user_rows=%d assistant_rows=%d rendered_rows=%d/%d stored_match=%t screen_match=%t net_charge=%d settlement_shown=%t",
		shown.MessagePosts, shown.CreatePosts, len(shown.SessionGets), h.generations.Load(),
		userRows, assistantRows, shown.UserRowsAfter, shown.AssistantRowsAfter,
		saved.Messages[0].Text == shown.UserRendered.Text && saved.Messages[1].Text == shown.AssistantRendered.Text,
		shown.UserRendered.Text == shown.UserText && shown.AssistantRendered.Text == shown.AssistantText,
		saved.Settlement.Net, shown.SettlementLabel == "本场净扣 1 次")
}

func t20ReconnectEnv(origin, tokens, receipt, aborted, phase string) []string {
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
		"T20_USER_TEXT="+t20ReconnectUserText,
		"T20_RECEIPT="+receipt,
		"T20_ABORTED="+aborted,
		"T20_PHASE="+phase,
	)
}

func t20ReconnectPhase(path string) string {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "unknown"
	}
	phase := strings.TrimSpace(string(raw))
	if phase == "" {
		return "unknown"
	}
	return phase
}
