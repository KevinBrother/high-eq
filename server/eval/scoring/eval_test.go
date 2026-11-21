package main

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"

	"high-eq/server/internal/scoring"
)

func TestPlan(t *testing.T) {
	cs, e := loadCases()
	if e != nil {
		t.Fatal(e)
	}
	var b bytes.Buffer
	if e = plan(cs, &b); e != nil {
		t.Fatal(e)
	}
	lines := strings.Split(strings.TrimSpace(b.String()), "\n")
	if len(lines) != 160 || strings.Contains(b.String(), `"expected"`) || strings.Contains(b.String(), `"label_status"`) {
		t.Fatal("plan size or label leak")
	}
	var x job
	if json.Unmarshal([]byte(lines[55]), &x) != nil || x.Case != 12 || x.Run != 1 || x.Temperature != 0.2 || len(x.Messages) != 2 {
		t.Fatal("wrong plan")
	}
}
func TestMetrics(t *testing.T) {
	c := sample{Case: 12, Turns: []scoring.Turn{{Role: "user", Text: "合成"}, {Role: "user", Text: "样例"}}, Expected: label{Mode: "express", NVC: []int{15, 0, 0, 0}, Total: 15, Emotion: []int{1, 1, 1}}}
	cs, e := loadCases()
	if e != nil {
		t.Fatal(e)
	}
	raw := string(cs[11].Reference)
	ev := observation{Case: 12, Model: "fake", Version: "fixture", Seed: seedHash(), Temperature: 0.2, Output: raw}
	for _, bad := range []string{"", "format", "turn", "regression", "stability", "emotion_range", "accuracy", "mean_emotion", "mixed_model", "mixed_version", "temp", "missing", "duplicate", "extra", "pending"} {
		t.Run(bad, func(t *testing.T) {
			var buf bytes.Buffer
			enc := json.NewEncoder(&buf)
			cc := c
			cc.LabelStatus = "规范回归"
			for j := 1; j <= 5; j++ {
				v := ev
				v.Run = j
				if j == 5 {
					switch bad {
					case "format":
						v.Output = "{}"
					case "turn":
						v.Output = strings.Replace(raw, `"target_turn":2`, `"target_turn":1`, 1)
					case "regression":
						v.Output = strings.Replace(raw, `"score":15`, `"score":10`, 1)
					case "mixed_model":
						v.Model = "changed"
					case "mixed_version":
						v.Version = "changed"
					case "temp":
						v.Temperature = 1
					case "missing":
						continue
					case "duplicate":
						v.Run = 1
					case "extra":
						enc.Encode(v)
					case "emotion_range":
						v.Output = strings.Replace(raw, `"level":1`, `"level":3`, 1)
					case "stability":
						v.Output = strings.Replace(raw, `"score":0`, `"score":25`, 1)
					}
				}
				if bad == "mean_emotion" {
					v.Output = strings.Replace(raw, `"level":1`, `"level":3`, 1)
				}
				if bad == "accuracy" {
					v.Output = strings.Replace(raw, `"score":0`, `"score":25`, 1)
				}
				if bad == "pending" {
					cc.LabelStatus = "待人工复核"
				}
				enc.Encode(v)
			}
			if e := check([]sample{cc}, &buf, io.Discard); (e != nil) != (bad != "") {
				t.Error("wrong gate result", e)
			}
		})
	}
}

// Independent constant-output fake, intentionally NOT a good model. Proves all
// 160 observations are counted, both regressions execute, and drafts block sign-off.
func TestOfflineBatch(t *testing.T) {
	cs, err := loadCases()
	if err != nil {
		t.Fatal(err)
	}
	var in, out bytes.Buffer
	enc := json.NewEncoder(&in)
	for _, c := range cs {
		for i := 1; i <= 5; i++ {
			if err = enc.Encode(observation{Case: c.Case, Run: i, Model: "constant-local-fake", Version: "fixture", Seed: seedHash(), Temperature: .2, Output: string(cs[10].Reference)}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err = check(cs, &in, &out); err == nil || !strings.Contains(out.String(), "format=160/160 pending_human_reviews=20") || !strings.Contains(out.String(), "regression=false") {
		t.Fatal("batch accepted synthetic answers as proof")
	}
}
func TestReviewerSidecar(t *testing.T) {
	cs, err := loadCases()
	if err != nil {
		t.Fatal(err)
	}
	const row = `{"case":13,"label_status":"已人工复核","expected":{"mode":"express","nvc":[25,25,25,25],"total":100,"emotion":[3,5,4]}}`
	for _, line := range []string{strings.Replace(row, "已人工复核", "待人工复核", 1), strings.Replace(row, `"case":13`, `"case":1`, 1), strings.Replace(row, "100", "99", 1)} {
		if applyReviews(cs, strings.NewReader(line)) == nil {
			t.Fatal("invalid review accepted")
		}
	}
	if applyReviews(cs, strings.NewReader(row)) != nil || applyReviews(cs, strings.NewReader(row)) == nil {
		t.Fatal("review validation")
	}
}
