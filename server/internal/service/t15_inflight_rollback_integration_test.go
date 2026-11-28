//go:build integration && t15inflight

package service

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/training"
)

// TestT15RollbackPreservesInflightAttempt is the normal-path boundary proof for
// T11's "an attempt that already resolved a version is not withdrawn": one
// ordinary role-play request has already received its system template at the
// synthetic upstream and is held there; a normal operator rollback commits; the
// held attempt is released and completes ok on the version it selected, and the
// next normal request resolves the rolled-back primary. Every claim is read
// back from the persisted ai_calls rows, not from the release pointer.
//
// The separate integration && t15inflight tag keeps this out of ordinary runs.
// Both the fixture prerequisite and every other missing prerequisite fail; none
// of them may turn into a skipped "green".
func TestT15RollbackPreservesInflightAttempt(t *testing.T) {
	if os.Getenv("T15_DISPOSABLE") != "yes" {
		t.Fatal("T15_DISPOSABLE=yes is required for disposable loopback stores")
	}
	// The shared practice fixture skips when neither flag is set. Check the
	// same condition here first so this named entry fails instead.
	if os.Getenv("T19_DISPOSABLE") != "yes" && os.Getenv("T20_DISPOSABLE") != "yes" {
		t.Fatal("the shared practice fixture requires T19_DISPOSABLE=yes; this named case must not skip")
	}

	h := newPracticeWire(t)
	token := h.adminLogin()

	const v2Template = "T15 在途版本合成模板：请围绕 {{scene}} 继续练习。"
	var v2 admin.PromptVersion
	h.admin(token, "POST", "prompt-versions", admin.CreatePromptVersionJSONBody{
		Task:     admin.TaskRolePlay,
		Template: v2Template,
	}, 200, &v2)
	h.admin(token, "PUT", "prompt-releases", admin.PromptRelease{
		Task:             admin.TaskRolePlay,
		ModelId:          h.primaryModel,
		PrimaryVersionId: v2.Id,
	}, 200, nil)
	seed := h.promptVersions[admin.TaskRolePlay]
	wantV2 := strings.ReplaceAll(v2Template, "{{scene}}", "work")

	user := h.user()
	roleModels := h.route("role_play")

	// Hold every generation at the provider after the first fragment. Reading
	// that fragment is the bounded signal that the selected template already
	// reached the upstream; nothing here waits on a wall-clock guess.
	release := h.hold()
	released := false
	defer func() {
		if !released {
			release()
		}
	}()

	before := h.generations.Load()
	key := uuid.NewString()
	path := h.create(user, 0)
	inflight := uuid.MustParse(strings.TrimPrefix(path, "sessions/"))
	resp := h.stream(user, path, key)
	defer resp.Body.Close()
	reader := bufio.NewReader(resp.Body)

	// Exactly three frames make up one successful ordinary reply: the held
	// first fragment, the second fragment after release, then the save receipt.
	requireFrame := func(stage, want string) json.RawMessage {
		t.Helper()
		name, data, err := t15ReadFrame(t, reader, 10*time.Second, stage)
		if err != nil {
			t.Fatalf("%s: %v", stage, err)
		}
		if name != want {
			t.Fatalf("%s: event %q, want %q", stage, name, want)
		}
		return data
	}
	decode := func(stage string, data json.RawMessage, out any) {
		t.Helper()
		if err := json.Unmarshal(data, out); err != nil {
			t.Fatalf("%s: %v", stage, err)
		}
	}
	var fragment struct {
		ClientMessageID uuid.UUID `json:"client_message_id"`
		Text            string    `json:"text"`
	}
	decode("first fragment", requireFrame("first fragment", "fragment"), &fragment)
	if fragment.ClientMessageID != uuid.MustParse(key) || fragment.Text != "合成甲。" {
		t.Fatalf("held attempt first fragment did not belong to the request or the fixture text")
	}
	if got := h.generations.Load() - before; got != 1 {
		t.Fatalf("in-flight attempt reached the provider %d times, want exactly 1", got)
	}
	h.captureMu.Lock()
	system := h.lastSystem
	h.captureMu.Unlock()
	if system != wantV2 {
		t.Fatalf("in-flight upstream template did not match the selected version")
	}

	// Normal operator rollback while the attempt is still held.
	h.admin(token, "PUT", "prompt-releases", admin.PromptRelease{
		Task:             admin.TaskRolePlay,
		ModelId:          h.primaryModel,
		PrimaryVersionId: seed,
	}, 200, nil)
	var primary, experiment *uuid.UUID
	var percent int
	if err := h.s.db.QueryRow(h.ctx, `select primary_version_id, experiment_version_id, experiment_percent
		from prompt_releases where task='role_play' and model_id=$1`, h.primaryModel).Scan(&primary, &experiment, &percent); err != nil {
		t.Fatal("could not read the rolled-back release pointer")
	}
	if primary == nil || *primary != seed || experiment != nil || percent != 0 {
		t.Fatalf("rollback pointer did not commit to the older primary before release")
	}

	release()
	released = true
	decode("second fragment", requireFrame("second fragment", "fragment"), &fragment)
	if fragment.ClientMessageID != uuid.MustParse(key) || fragment.Text != "合成乙。" {
		t.Fatalf("released attempt second fragment did not belong to the request or the fixture text")
	}
	var receipt struct {
		ClientMessageID uuid.UUID       `json:"client_message_id"`
		MessageID       uuid.UUID       `json:"message_id"`
		Settlement      json.RawMessage `json:"settlement"`
	}
	decode("save receipt", requireFrame("save receipt", "reply_saved"), &receipt)
	if receipt.ClientMessageID != uuid.MustParse(key) || receipt.MessageID == uuid.Nil || len(receipt.Settlement) == 0 {
		t.Fatalf("released attempt save receipt was incomplete")
	}
	// The old stream must stop at that receipt: no repeated or reordered event.
	if name, _, err := t15ReadFrame(t, reader, 5*time.Second, "end of the held attempt"); err != io.EOF {
		t.Fatalf("held attempt ended with event %q / %v, want EOF after reply_saved", name, err)
	}

	// Re-check the whole old round only after its stream ended. An extra
	// provider arrival between the first fragment and EOF cannot hide here.
	inflightGenerations := h.generations.Load() - before
	if inflightGenerations != 1 {
		t.Fatalf("held attempt reached the provider %d times over the whole round, want exactly 1", inflightGenerations)
	}

	// One generation source row per round, on the primary model, tagged with the
	// version the attempt actually used and a successful outcome. Counts are
	// limited to the role-play primary/fallback generation models; the four
	// unversioned moderation rows of the same activity are excluded.
	requireRound := func(label string, activity, wantVersion uuid.UUID) {
		t.Helper()
		if got := h.number(`select count(*) from ai_calls
			where activity_id=$1 and task='role_play' and model_id in ($2,$3)`,
			activity, roleModels.primary, roleModels.fallback); got != 1 {
			t.Fatalf("%s generated %d role-play calls, want exactly 1", label, got)
		}
		var model uuid.UUID
		var versionID *uuid.UUID
		var outcome string
		if err := h.s.db.QueryRow(h.ctx, `select model_id, prompt_version_id, outcome
			from ai_calls where activity_id=$1 and task='role_play' and model_id in ($2,$3)`,
			activity, roleModels.primary, roleModels.fallback).Scan(&model, &versionID, &outcome); err != nil {
			t.Fatalf("%s: could not read the generation source row", label)
		}
		if model != h.primaryModel || versionID == nil || *versionID != wantVersion || outcome != "ok" {
			t.Fatalf("%s source row model=%s version=%v outcome=%s, want %s/%s/ok",
				label, model, versionID, outcome, h.primaryModel, wantVersion)
		}
	}
	requireRound("in-flight", inflight, v2.Id)

	// The next ordinary request, after the rollback committed, resolves the
	// older primary. The provider is unheld from here on.
	h.set("")
	nextBefore := h.generations.Load()
	nextPath := h.create(user, 0)
	next := uuid.MustParse(strings.TrimPrefix(nextPath, "sessions/"))
	h.send(user, nextPath)
	nextGenerations := h.generations.Load() - nextBefore
	if nextGenerations != 1 {
		t.Fatalf("next attempt reached the provider %d times, want exactly 1", nextGenerations)
	}
	h.captureMu.Lock()
	system = h.lastSystem
	h.captureMu.Unlock()
	if system != training.Seed() {
		t.Fatal("next upstream template did not match the rolled-back primary")
	}
	requireRound("next", next, seed)

	if got := h.number(`select count(*) from activities where id in ($1,$2) and user_id=$3`, inflight, next, user.UserId); got != 2 {
		t.Fatalf("the two ordinary attempts did not belong to the same synthetic user: %d rows", got)
	}
	t.Logf("T15 in-flight rollback: held_attempt=%s next_attempt=%s generations=%d+%d source_rows=%s->%s",
		v2.Id, seed, inflightGenerations, nextGenerations, v2.Id, seed)
}

// t15ReadFrame reads one complete SSE frame under a bounded wait. It returns
// io.EOF when the stream ended cleanly before another frame.
func t15ReadFrame(t *testing.T, reader *bufio.Reader, timeout time.Duration, stage string) (string, json.RawMessage, error) {
	t.Helper()
	type result struct {
		name string
		data json.RawMessage
		err  error
	}
	done := make(chan result, 1)
	go func() {
		line, err := reader.ReadString('\n')
		if err == io.EOF {
			done <- result{err: io.EOF}
			return
		}
		if err != nil {
			done <- result{err: err}
			return
		}
		if !strings.HasPrefix(line, "event: ") || !strings.HasSuffix(line, "\n") {
			done <- result{err: fmt.Errorf("malformed event line %q", line)}
			return
		}
		data, err := reader.ReadString('\n')
		if err != nil {
			done <- result{err: fmt.Errorf("reading data line: %w", err)}
			return
		}
		if !strings.HasPrefix(data, "data: ") || !strings.HasSuffix(data, "\n") {
			done <- result{err: fmt.Errorf("malformed data line %q", data)}
			return
		}
		blank, err := reader.ReadString('\n')
		if err != nil {
			done <- result{err: fmt.Errorf("reading frame terminator: %w", err)}
			return
		}
		if blank != "\n" {
			done <- result{err: fmt.Errorf("missing frame terminator, got %q", blank)}
			return
		}
		done <- result{
			name: strings.TrimSuffix(strings.TrimPrefix(line, "event: "), "\n"),
			data: json.RawMessage(strings.TrimSuffix(strings.TrimPrefix(data, "data: "), "\n")),
		}
	}()
	select {
	case got := <-done:
		return got.name, got.data, got.err
	case <-time.After(timeout):
		t.Fatalf("%s: timed out waiting for an SSE frame", stage)
		return "", nil, nil
	}
}
