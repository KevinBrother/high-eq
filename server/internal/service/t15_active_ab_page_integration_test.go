//go:build integration && t15ab

package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
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

	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/training"
)

// T15 acceptance, real wire: an already-provisioned synthetic operator opens the
// shipped Flutter /prompts page, picks the same role-play task and generation
// model, publishes a 50% split across two already-saved versions, and reads the
// primary/experiment line back from the page after a real reload. Two
// independent synthetic App users then take two normal rounds each through the
// unchanged gateway. Their arm is deterministic: the published bucket function
// is reproduced here only to pick candidate users, never to claim a random
// sample. Version attribution is reconciled from ai_calls, not from the receipt.
// No provider, browser, account or real credential.
//
// The separate integration && t15ab tag keeps this off ordinary runs. A missing
// prerequisite fails; it never turns into a skipped "green".
func TestT15ActiveABReleaseJourney(t *testing.T) {
	if os.Getenv("T15_DISPOSABLE") != "yes" {
		t.Fatal("T15_DISPOSABLE=yes is required for disposable loopback stores")
	}
	if os.Getenv("T19_DISPOSABLE") != "yes" && os.Getenv("T20_DISPOSABLE") != "yes" {
		t.Fatal("the shared practice fixture requires T19_DISPOSABLE=yes")
	}

	// Derive the checkout from this source file instead of taking a machine path
	// or a caller-supplied card root.
	_, source, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate the T15 test source")
	}
	repoRoot := filepath.Clean(filepath.Join(filepath.Dir(source), "..", "..", ".."))
	adminDir := filepath.Join(repoRoot, "admin")
	pageTest := filepath.Join("tool", "t15", "ab_live_test.dart")
	if info, err := os.Stat(filepath.Join(adminDir, pageTest)); err != nil || !info.Mode().IsRegular() {
		t.Fatal("T15 Flutter /prompts A/B page check is missing from the checkout")
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

	const v2Template = "T15 A/B 主模板：请围绕 {{scene}} 继续练习。"
	var v2 admin.PromptVersion
	h.admin(auth.AccessToken, "POST", "prompt-versions", admin.CreatePromptVersionJSONBody{
		Task:     admin.TaskRolePlay,
		Template: v2Template,
	}, 200, &v2)
	seed := h.promptVersions[admin.TaskRolePlay]
	var seedVersion int
	h.must(h.s.db.QueryRow(h.ctx, `select version from prompt_versions where id=$1`, seed).Scan(&seedVersion))
	if v2.Version == seedVersion {
		t.Fatalf("the two selected versions are not distinct: v%d", v2.Version)
	}
	var havePrimary *uuid.UUID
	var haveExperiment *uuid.UUID
	var havePercent int
	if err := h.s.db.QueryRow(h.ctx, `select primary_version_id, experiment_version_id, experiment_percent
		from prompt_releases where task='role_play' and model_id=$1`, h.primaryModel).Scan(&havePrimary, &haveExperiment, &havePercent); err != nil {
		t.Fatal("could not read the starting release pointer")
	}
	if havePrimary == nil || *havePrimary != seed || haveExperiment != nil || havePercent != 0 {
		t.Fatalf("fixture did not start from an unsplit release at %s", seed)
	}

	seedName, v2Name := fmt.Sprintf("v%d", seedVersion), fmt.Sprintf("v%d", v2.Version)
	const wantPercent = 50

	// Count only the page's own admin writes, through a loopback proxy. Bodies,
	// tokens and IDs are not recorded. The preparation create above used
	// h.api.URL directly and is outside this boundary.
	backend, err := url.Parse(h.api.URL)
	if err != nil {
		t.Fatal("could not resolve the fixture admin origin")
	}
	proxy := httputil.NewSingleHostReverseProxy(backend)
	var putMu sync.Mutex
	pagePuts := 0
	pageServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPut && r.URL.Path == "/admin/v1/prompt-releases" {
			putMu.Lock()
			pagePuts++
			putMu.Unlock()
		}
		proxy.ServeHTTP(w, r)
	}))
	defer pageServer.Close()

	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	beforePublish := h.number(`select count(*) from admin_audit_logs where actor_id=$1 and action='setPromptRelease' and result='ok'`, operator)
	runCtx, cancel := context.WithTimeout(h.ctx, 6*time.Minute)
	defer cancel()
	receipt := filepath.Join(t.TempDir(), "ab-receipt")
	cmd := exec.CommandContext(runCtx, flutter, "test", "--no-pub", "-r", "expanded", pageTest)
	cmd.Dir = adminDir
	cmd.Env = append(os.Environ(),
		"T15_ADMIN_ORIGIN="+pageServer.URL,
		"T15_ADMIN_TOKEN="+auth.AccessToken,
		"T15_MODEL_LABEL=primary · "+h.primaryModel.String(),
		"T15_CURRENT="+seedName,
		"T15_EXPERIMENT="+seedName,
		`T15_PRIMARY=`+v2Name,
		"T15_PERCENT="+fmt.Sprint(wantPercent),
		"T15_RECEIPT="+receipt,
	)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Run(); err != nil {
		t.Fatalf("T15 Flutter /prompts A/B page stopped the flow (exit=%v): %s", err, t15abRedact(output.String(), auth.AccessToken, pageServer.URL))
	}
	receiptData, err := os.ReadFile(receipt)
	if err != nil {
		t.Fatal("the Flutter page wrote no receipt")
	}

	var primary, experiment *uuid.UUID
	var percent int
	if err := h.s.db.QueryRow(h.ctx, `select primary_version_id, experiment_version_id, experiment_percent
		from prompt_releases where task='role_play' and model_id=$1`, h.primaryModel).Scan(&primary, &experiment, &percent); err != nil {
		t.Fatal("could not read the published release pointer")
	}
	if primary == nil || *primary != v2.Id || experiment == nil || *experiment != seed || percent != wantPercent {
		t.Fatalf("published pointer primary=%v experiment=%v percent=%d, want %s/%s/%d",
			primary, experiment, percent, v2Name, seedName, wantPercent)
	}

	// The receipt is the text the page actually rendered after its own reload.
	// Rebuild the same line from the persisted pointer and the immutable version
	// numbers, so a hardcoded or stale page line cannot pass.
	wantLine := fmt.Sprintf("线上主版本：%s   /   实验：%s · %d%%", v2Name, seedName, percent)
	if got := strings.TrimSpace(string(receiptData)); got != "release="+wantLine {
		t.Fatalf("the page rendered %q, want the persisted pointer line %q", got, "release="+wantLine)
	}
	// Exactly one write must come from the single page publish; a retry or an
	// extra request beyond the UI boundary is a failure, not a bigger number.
	putMu.Lock()
	puts := pagePuts
	putMu.Unlock()
	if puts != 1 {
		t.Fatalf("the /prompts page issued %d PUT /admin/v1/prompt-releases requests, want exactly 1", puts)
	}
	if got := h.number(`select count(*) from admin_audit_logs where actor_id=$1 and action='setPromptRelease' and result='ok'`, operator) - beforePublish; got != 1 {
		t.Fatalf("publish audit wrote %d successful releases, want 1", got)
	}

	// Mirrors the published bucket function only to choose synthetic samples.
	// The gateway performs the real resolution below.
	bucketOf := func(user uuid.UUID) int {
		hsh := sha256.New()
		hsh.Write([]byte("prompt-ab:v1\x00role_play\x00"))
		hsh.Write(h.primaryModel[:])
		hsh.Write(user[:])
		return int(binary.BigEndian.Uint64(hsh.Sum(nil)[:8]) % 100)
	}
	var primaryUser, experimentUser app.Tokens
	var primaryBucket, experimentBucket int
	for i := 0; i < 200 && (primaryUser.UserId == uuid.Nil || experimentUser.UserId == uuid.Nil); i++ {
		u := h.user()
		b := bucketOf(u.UserId)
		if b >= wantPercent && primaryUser.UserId == uuid.Nil {
			primaryUser, primaryBucket = u, b
		}
		if b < wantPercent && experimentUser.UserId == uuid.Nil {
			experimentUser, experimentBucket = u, b
		}
	}
	if primaryUser.UserId == uuid.Nil || experimentUser.UserId == uuid.Nil || primaryUser.UserId == experimentUser.UserId {
		t.Fatal("could not find one synthetic user per arm")
	}

	roleModels := h.route("role_play")
	round := func(label string, u app.Tokens, wantVersion uuid.UUID, wantSystem string) uuid.UUID {
		t.Helper()
		before := h.generations.Load()
		path := h.create(u, 0)
		activity := uuid.MustParse(strings.TrimPrefix(path, "sessions/"))
		h.send(u, path)
		if got := h.generations.Load() - before; got != 1 {
			t.Fatalf("%s attempted %d generations, want exactly 1", label, got)
		}
		h.captureMu.Lock()
		system := h.lastSystem
		h.captureMu.Unlock()
		if system != wantSystem {
			t.Fatalf("%s upstream system template did not carry the expected version", label)
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

	// The primary arm receives the freshly published template; the experiment
	// arm receives the immutable seed. Both rounds per user must stay on the
	// same arm, which the repeated expected version checks by construction.
	renderedV2 := strings.ReplaceAll(v2Template, "{{scene}}", "work")
	primary1 := round("primary/1", primaryUser, v2.Id, renderedV2)
	primary2 := round("primary/2", primaryUser, v2.Id, renderedV2)
	experiment1 := round("experiment/1", experimentUser, seed, training.Seed())
	experiment2 := round("experiment/2", experimentUser, seed, training.Seed())

	if got := h.number(`select count(*) from activities where id in ($1,$2,$3,$4) and user_id in ($5,$6)`,
		primary1, primary2, experiment1, experiment2, primaryUser.UserId, experimentUser.UserId); got != 4 {
		t.Fatalf("the four rounds did not belong to the two synthetic users: %d rows", got)
	}
	for _, want := range []struct {
		version uuid.UUID
		name    string
		user    app.Tokens
	}{
		{v2.Id, v2Name, primaryUser},
		{seed, seedName, experimentUser},
	} {
		if got := h.number(`select count(*) from ai_calls
			where task='role_play' and model_id=$1 and prompt_version_id=$2 and outcome='ok'
			  and activity_id in (select id from activities where user_id=$3)`,
			h.primaryModel, want.version, want.user.UserId); got != 2 {
			t.Fatalf("%s reached %d generation calls, want exactly 2", want.name, got)
		}
	}
	t.Logf("T15 A/B: page_puts=%d pointer=%s/%s@%d%% buckets primary=%d(>=%d) experiment=%d(<%d) calls=%s x2, %s x2 page_line=%q",
		puts, v2Name, seedName, percent, primaryBucket, wantPercent, experimentBucket, wantPercent, v2Name, seedName, wantLine)
}

// t15abRedact keeps a bounded diagnostic tail without the session token or the
// loopback origin.
func t15abRedact(output, token, origin string) string {
	output = strings.ReplaceAll(output, token, "[redacted]")
	output = strings.ReplaceAll(output, origin, "[redacted]")
	if len(output) > 4000 {
		output = output[len(output)-4000:]
	}
	return output
}
