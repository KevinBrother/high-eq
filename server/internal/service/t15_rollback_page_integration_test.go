//go:build integration && t15rollback

package service

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/training"
)

// T15 acceptance, real wire: an already-provisioned synthetic operator rolls a
// published role-play prompt back to v1 from the shipped Flutter /prompts page.
// That page talks HTTP to the unchanged service process; the same synthetic App
// user's next normal request resolves the older template and its version ID at
// the synthetic upstream. No provider, browser, account or real credential.
//
// The separate integration && t15rollback tag keeps this off ordinary runs. A
// missing prerequisite fails; it never turns into a skipped "green".
func TestT15AdminRollbackNextAppCall(t *testing.T) {
	if os.Getenv("T15_DISPOSABLE") != "yes" {
		t.Fatal("T15_DISPOSABLE=yes is required for disposable loopback stores")
	}
	if os.Getenv("T19_DISPOSABLE") != "yes" && os.Getenv("T20_DISPOSABLE") != "yes" {
		t.Fatal("the shared practice fixture requires T19_DISPOSABLE=yes")
	}

	// Derive the checkout from this source file instead of taking a machine
	// path or a caller-supplied card root.
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the T15 test source")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(source), "..", "..", ".."))
	adminDir := filepath.Join(repoRoot, "admin")
	pageTest := filepath.Join("tool", "t15", "rollback_live_test.dart")
	if info, err := os.Stat(filepath.Join(adminDir, pageTest)); err != nil || !info.Mode().IsRegular() {
		t.Fatal("T15 Flutter /prompts page check is missing from the checkout")
	}

	h := newPracticeWire(t)
	const password = "fixture-password-only"
	login := uuid.NewString()
	operator, err := adminops.Provision(h.ctx, h.s.db, login, password, "operator")
	if err != nil {
		t.Fatal("could not provision the synthetic operator")
	}
	var auth admin.AdminSession
	h.admin("", "POST", "auth/login", admin.AdminLoginJSONBody{Login: login, Password: password}, 200, &auth)

	const v2Template = "T15 V2 合成模板：请围绕 {{scene}} 继续练习。"
	var v2 admin.PromptVersion
	h.admin(auth.AccessToken, "POST", "prompt-versions", admin.CreatePromptVersionJSONBody{
		Task:     admin.TaskRolePlay,
		Template: v2Template,
	}, 200, &v2)
	h.admin(auth.AccessToken, "PUT", "prompt-releases", admin.PromptRelease{
		Task:             admin.TaskRolePlay,
		ModelId:          h.primaryModel,
		PrimaryVersionId: v2.Id,
	}, 200, nil)
	seed := h.promptVersions[admin.TaskRolePlay]
	var seedVersion int
	h.must(h.s.db.QueryRow(h.ctx, `select version from prompt_versions where id=$1`, seed).Scan(&seedVersion))
	v2Name, seedName := fmt.Sprintf("v%d", v2.Version), fmt.Sprintf("v%d", seedVersion)

	user := h.user()
	roleModels := h.route("role_play")

	// One round is one create + one send. A role_play round also writes four
	// unversioned moderation rows, so the complete expectation is checked over
	// the generation models only: exactly one versioned source row. A
	// wrong-version attempt followed by the expected version cannot hide behind
	// a count filtered to the expected version.
	appCall := func(label string, wantVersion uuid.UUID, wantSystem string) uuid.UUID {
		t.Helper()
		before := h.generations.Load()
		path := h.create(user, 0)
		activity := uuid.MustParse(strings.TrimPrefix(path, "sessions/"))
		h.send(user, path)
		if got := h.generations.Load() - before; got != 1 {
			t.Fatalf("%s attempted %d generations, want exactly 1", label, got)
		}
		h.captureMu.Lock()
		system := h.lastSystem
		h.captureMu.Unlock()
		if system != wantSystem {
			t.Fatalf("%s upstream system template did not match the expected version", label)
		}
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
			t.Fatal("could not read the role-play generation source row")
		}
		if model != h.primaryModel || versionID == nil || *versionID != wantVersion || outcome != "ok" {
			t.Fatalf("%s generation source row model=%s version=%v outcome=%s, want %s/%s/ok",
				label, model, versionID, outcome, h.primaryModel, wantVersion)
		}
		return activity
	}

	firstActivity := appCall("first", v2.Id, strings.ReplaceAll(v2Template, "{{scene}}", "work"))

	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	beforeRollback := h.number(`select count(*) from admin_audit_logs where actor_id=$1 and action='setPromptRelease' and result='ok'`, operator)
	runCtx, cancel := context.WithTimeout(h.ctx, 6*time.Minute)
	defer cancel()
	receipt := filepath.Join(t.TempDir(), "rollback-receipt")
	cmd := exec.CommandContext(runCtx, flutter, "test", "--no-pub", "-r", "expanded", pageTest)
	cmd.Dir = adminDir
	cmd.Env = append(os.Environ(),
		"T15_ADMIN_ORIGIN="+h.api.URL,
		"T15_ADMIN_TOKEN="+auth.AccessToken,
		"T15_MODEL_LABEL=primary · "+h.primaryModel.String(),
		"T15_CURRENT="+v2Name,
		"T15_ROLLBACK="+seedName,
		"T15_RECEIPT="+receipt,
	)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Run(); err != nil {
		t.Fatalf("T15 Flutter /prompts page stopped the flow (exit=%v): %s", err, t15Redact(output.String(), auth.AccessToken, h.api.URL))
	}
	receiptData, err := os.ReadFile(receipt)
	if err != nil || strings.TrimSpace(string(receiptData)) != "rollback="+seedName {
		t.Fatalf("T15 Flutter /prompts page finished without rolling back")
	}

	var primary, experiment *uuid.UUID
	var percent int
	if err := h.s.db.QueryRow(h.ctx, `select primary_version_id, experiment_version_id, experiment_percent
		from prompt_releases where task='role_play' and model_id=$1`, h.primaryModel).Scan(&primary, &experiment, &percent); err != nil {
		t.Fatal("could not read the synthetic release pointer")
	}
	if primary == nil || *primary != seed || experiment != nil || percent != 0 {
		t.Fatalf("rollback pointer did not return to %s with no experiment and zero percent", seedName)
	}
	if got := h.number(`select count(*) from admin_audit_logs where actor_id=$1 and action='setPromptRelease' and result='ok'`, operator) - beforeRollback; got != 1 {
		t.Fatalf("rollback audit wrote %d successful releases, want 1", got)
	}
	// Minimal audit check: the fixed action, object and result only. The row is
	// not treated as a way to recover the task, model or version.
	var action, target, result string
	if err := h.s.db.QueryRow(h.ctx, `select action, target, result from admin_audit_logs
		where actor_id=$1 order by occurred_at desc, id desc limit 1`, operator).Scan(&action, &target, &result); err != nil {
		t.Fatal("could not read the operator's latest audit row")
	}
	if action != "setPromptRelease" || target != "prompts" || result != "ok" {
		t.Fatalf("rollback audit action/target/result=%s/%s/%s", action, target, result)
	}

	secondActivity := appCall("next", seed, training.Seed())
	if got := h.number(`select count(*) from activities where id in ($1,$2) and user_id=$3`, firstActivity, secondActivity, user.UserId); got != 2 {
		t.Fatalf("the two App attempts did not belong to the same synthetic user: %d rows", got)
	}
	t.Logf("T15 page->next call: page_releases=1 audit=%s/%s/%s pointer=%s calls=%s->%s", action, target, result, seedName, v2Name, seedName)
}

// t15Redact keeps a bounded diagnostic tail without the session token or the
// loopback origin.
func t15Redact(output, token, origin string) string {
	output = strings.ReplaceAll(output, token, "[redacted]")
	output = strings.ReplaceAll(output, origin, "[redacted]")
	if len(output) > 4000 {
		output = output[len(output)-4000:]
	}
	return output
}
