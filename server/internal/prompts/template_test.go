package prompts

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"
	"high-eq/server/internal/api/admin"
)

func TestTaskVariableContract(t *testing.T) {
	contract := map[admin.Task][]string{
		admin.TaskRolePlay:          {"scene"},
		admin.TaskScoring:           {"assessment", "target_item", "retry"},
		admin.TaskProfileInference:  {"scene", "options"},
		admin.TaskReplySuggestion:   {},
		admin.TaskReviewAnalysis:    {},
		admin.TaskContentGeneration: {},
		admin.TaskClassification:    {},
	}
	for task, allowed := range contract {
		var parts []string
		for _, key := range allowed {
			parts = append(parts, "{{"+key+"}}")
		}
		src := strings.Join(parts, " / ")
		if src == "" {
			src = "literal"
		}
		if err := ValidateForTask(task, src); err != nil {
			t.Errorf("%s rejected its contract: %v", task, err)
		}
		if err := ValidateForTask(task, "{{profile}}"); !errors.Is(err, ErrVariable) {
			t.Errorf("%s accepted unsupported {{profile}}: %v", task, err)
		}
	}
	if err := ValidateForTask(admin.TaskRolePlay, "请围绕 {{ scene }} 展开练习。"); err != nil {
		t.Fatalf("official role-play template rejected: %v", err)
	}
	if err := ValidateForTask(admin.Task("unknown"), "literal"); !errors.Is(err, ErrTemplate) {
		t.Fatalf("unknown task accepted: %v", err)
	}
}

func TestValidateForTaskRejectsBlankRuntimeRender(t *testing.T) {
	for _, src := range []string{"{{retry}}", "{{target_item}}", "{{retry}}{{target_item}}"} {
		if err := ValidateForTask(admin.TaskScoring, src); !errors.Is(err, ErrVariable) {
			t.Errorf("scoring accepted runtime-blank template %q: %v", src, err)
		}
	}
	if err := ValidateForTask(admin.TaskScoring, "评估 {{assessment}}；{{retry}}"); err != nil {
		t.Fatalf("scoring template with a guaranteed nonblank variable rejected: %v", err)
	}
}

func TestValidateForTaskUsesRuntimeVariableBounds(t *testing.T) {
	// role_play.scene is either a validated category or a frozen catalog scene;
	// the longest current catalog scene is 94 UTF-8 bytes. A custom scenario's
	// 6,000-byte input never becomes the system variable.
	repeated := strings.Repeat("{{scene}}", 44)
	if err := ValidateForTask(admin.TaskRolePlay, repeated); err != nil {
		t.Fatalf("rejected template valid for every runtime scene: %v", err)
	}
	if err := ValidateForTask(admin.TaskRolePlay, strings.Repeat("{{scene}}", 2788)); err != nil {
		t.Fatalf("rejected render at the 256 KiB boundary: %v", err)
	}
	if err := ValidateForTask(admin.TaskRolePlay, strings.Repeat("{{scene}}", 2789)); !errors.Is(err, ErrVariable) {
		t.Fatalf("accepted render over 256 KiB for the longest scene: %v", err)
	}
	if err := ValidateForTask(admin.TaskRolePlay, "请围绕 {{scene}} 展开练习。"); err != nil {
		t.Fatalf("official template rejected for legal maximum scene: %v", err)
	}
	scene := strings.Repeat("场", 2000) // 6,000 UTF-8 bytes, the custom scenario input limit.
	if got, err := Render("{{scene}}", map[string]string{"scene": scene}); err != nil || len(got) != len(scene) {
		t.Fatalf("maximum legal scene is not renderable: bytes=%d err=%v", len(got), err)
	}
}

func TestValidateForTaskAcceptsRealisticScoringRubric(t *testing.T) {
	// Fifteen rules remain well below the literal-size cap. The 45 placeholders
	// would exceed 256 KiB if each variable were incorrectly assumed to carry the
	// 6,000-byte custom-scenario input allowance.
	const rule = "规则：先确认事实，再区分感受、需要和请求；不要贴标签或替对方作判断。评估类型：{{assessment}}；本轮重点：{{target_item}}；重试说明：{{retry}}。"
	var rubric strings.Builder
	for i := range 15 {
		if i > 0 {
			rubric.WriteByte('\n')
		}
		rubric.WriteString(rule)
	}
	if got := strings.Count(rubric.String(), "{{"); got != 45 {
		t.Fatalf("fixture has %d placeholders, want 45", got)
	}
	if err := ValidateForTask(admin.TaskScoring, rubric.String()); err != nil {
		t.Fatalf("accepted runtime rubric rejected at save or publish: %v", err)
	}
}

func TestLiteralRender(t *testing.T) {
	vars := map[string]string{"scene": "{{other}}", "other": "合成"}
	got, e := Render(`{ "scene": "{{ scene }}" }/{{other}}/{{scene}}`, vars)
	if e != nil || got != `{ "scene": "{{other}}" }/合成/{{other}}` {
		t.Fatal("substitution is not literal")
	}
	for _, s := range []string{" ", "{{}}", "{{ scene", "oops }}", "{{.field}}", "{{call x}}", "{{a-b}}"} {
		if Validate(s) == nil {
			t.Error("accepted malformed template")
		}
	}
	if v, e := Render("private {{missing}}", nil); v != "" || !errors.Is(e, ErrVariable) {
		t.Fatal("missing variable sent or leaked")
	}
	if _, e := Render("{{x}}{{x}}", map[string]string{"x": strings.Repeat("a", maxRendered)}); !errors.Is(e, ErrVariable) {
		t.Fatal("unbounded output")
	}
	scene := strings.Repeat("场", 2000) // 6,000 UTF-8 bytes, the custom scenario limit.
	if got, e := Render("请围绕 {{scene}} 展开练习。", map[string]string{"scene": scene}); e != nil || !strings.Contains(got, scene) {
		t.Fatalf("maximum legal scene did not render: bytes=%d err=%v", len(got), e)
	}
	repeated := strings.Repeat("{{scene}}", 2789)
	if _, e := Render(repeated, map[string]string{"scene": strings.Repeat("x", 94)}); !errors.Is(e, ErrVariable) {
		t.Fatal("rendered-size cap did not reject expanded output")
	}
	for _, value := range []string{"", " \t\n", "nul\x00value"} {
		if got, e := Render("{{x}}", map[string]string{"x": value}); got != "" || !errors.Is(e, ErrVariable) {
			t.Fatalf("invalid rendered value accepted: %q %q %v", value, got, e)
		}
	}
	if e := Validate(strings.Repeat("a", maxTemplate+1)); !errors.Is(e, ErrTemplate) {
		t.Fatal("oversized template accepted")
	}
}
func TestModelScopedBucket(t *testing.T) {
	a, b := uuid.UUID{1}, uuid.UUID{2}
	var n, diff int
	for i := range 10000 {
		var u uuid.UUID
		binary.BigEndian.PutUint64(u[8:], uint64(i))
		k := bucket("scoring", a, u)
		if k < 0 || k >= 100 || k != bucket("scoring", a, u) {
			t.Fatal("unstable bucket")
		}
		if k < 25 {
			n++
		}
		if k != bucket("scoring", b, u) {
			diff++
		}
	}
	if n < 2200 || n > 2800 || diff < 9500 {
		t.Fatal(n, diff)
	}
}

// Real model cohorts must both see approximately the configured prompt percentage;
// reusing T10's user-only hash would exclude one arm from one of these cohorts.
func TestSplitWithinEachModel(t *testing.T) {
	var totals, hits [2]int
	for i := range 100000 {
		var u uuid.UUID
		binary.BigEndian.PutUint64(u[8:], uint64(i))
		h := sha256.Sum256(u[:])
		var m byte
		if binary.BigEndian.Uint64(h[:8])%100 < 20 {
			m = 1
		}
		totals[m]++
		if bucket("scoring", uuid.UUID{m + 1}, u) < 30 {
			hits[m]++
		}
	}
	for m, n := range totals {
		pct := float64(hits[m]) * 100 / float64(n)
		if pct < 29 || pct > 31 {
			t.Fatalf("model %d: %.2f%%", m, pct)
		}
	}
}
