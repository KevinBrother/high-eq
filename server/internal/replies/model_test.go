package replies

import (
	"github.com/google/uuid"
	"high-eq/server/internal/api/app"

	"strings"
	"testing"
)

const sample = `{"possible_feeling":"可能有些着急","possible_need":"想了解安排","suggestions":[{"style":"确认","text":"你想先对齐时间吗？","reason":"先问需求"},{"style":"直接","text":"我们可以先定个时间。","reason":"提出可行下一步"}]}`

func TestApprovedShape(t *testing.T) {
	id := uuid.New()
	v, e := decodeResult(id, []byte(sample), "合成原文", nil)
	if e != nil || v.Id != id || len(v.Suggestions) != 2 {
		t.Fatal("valid rejected")
	}
	for _, bad := range []string{strings.Replace(sample, "直接", "确认", 1), strings.Replace(sample, "提出可行下一步", " ", 1), strings.Replace(sample, "可能有些着急", "合成原文", 1), strings.Replace(sample, `"style":"直接"`, `"extra":true,"style":"直接"`, 1), sample + "{}", `{}`, strings.Replace(sample, `"possible_need":`, `"possible_need":"歧义","possible_need":`, 1), strings.Replace(sample, `"possible_need":`, `"safety_flag":true,"possible_need":`, 1)} {
		if _, e := decodeResult(id, []byte(bad), "合成原文", nil); e == nil {
			t.Fatal("invalid accepted")
		}
	}
}

func TestExplicitSelfJudgment(t *testing.T) {
	for _, tc := range []struct{ tag, want string }{{"overwhelmed", "本人上头"}, {"not_overwhelmed", "本人没有上头"}, {"对方上头", ""}, {"本人上头", ""}, {"", ""}} {
		k := app.RateReplyInputSelfReport(tc.tag)
		if got := judgment(&k); got != tc.want {
			t.Fatal("ambiguous attribution")
		}
	}
	if judgment(nil) != "" {
		t.Fatal("invented self evidence")
	}
}

func TestDecodeResultRejectsSpeakerlessChatFragment(t *testing.T) {
	id := uuid.New()
	leaked := strings.Replace(sample, "提出可行下一步", "合成编号 A17。", 1)
	if _, e := decodeResult(id, []byte(leaked), "甲：合成编号 A17。", nil); e == nil {
		t.Fatal("speakerless source fragment was persisted")
	}
}

func TestDecodeResultRejectsPartialChatFragment(t *testing.T) {
	id := uuid.New()
	leaked := strings.Replace(sample, "提出可行下一步", "合成编号", 1)
	if _, e := decodeResult(id, []byte(leaked), "甲：合成编号 A17。", nil); e == nil {
		t.Fatal("partial source fragment was persisted")
	}
}

func TestDecodeResultRejectsGoalFragment(t *testing.T) {
	id := uuid.New()
	goal := "希望周三前确认安排"
	leaked := strings.Replace(sample, "提出可行下一步", goal, 1)
	if _, e := decodeResult(id, []byte(leaked), "甲：合成编号 A17。", &goal); e == nil {
		t.Fatal("source goal fragment was persisted")
	}
}

func TestDecodeResultRejectsNormalizedPartialGoalFragment(t *testing.T) {
	id := uuid.New()
	goal := "希望 周三，前确认安排"
	leaked := strings.Replace(sample, "提出可行下一步", "周三前确认", 1)
	if _, e := decodeResult(id, []byte(leaked), "甲：合成编号 A17。", &goal); e == nil {
		t.Fatal("normalized goal fragment was persisted")
	}
}

func TestDecodeResultRejectsShortChatFragment(t *testing.T) {
	id := uuid.New()
	leaked := strings.Replace(sample, "提出可行下一步", "先确认暗号乙是否正确", 1)
	if _, e := decodeResult(id, []byte(leaked), "甲：暗号乙", nil); e == nil {
		t.Fatal("complete short chat source was persisted")
	}
}

func TestDecodeResultRejectsShortGoalFragment(t *testing.T) {
	id := uuid.New()
	goal := "暗号乙"
	leaked := strings.Replace(sample, "提出可行下一步", "先确认暗号乙是否正确", 1)
	if _, e := decodeResult(id, []byte(leaked), "甲：合成编号 A17。", &goal); e == nil {
		t.Fatal("complete short goal source was persisted")
	}
}

func TestDecodeResultRejectsColonTerminatedSources(t *testing.T) {
	id := uuid.New()
	for _, tc := range []struct {
		name, source string
		goal         bool
	}{
		{name: "colon-terminated chat", source: "合成暗号："},
		{name: "speaker-labelled colon", source: "甲：合成暗号："},
		{name: "colon-terminated goal", source: "合成暗号：", goal: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			leaked := strings.Replace(sample, "提出可行下一步", "请先确认「合成暗号：」", 1)
			var goal *string
			if tc.goal {
				goal = &tc.source
			}
			if _, e := decodeResult(id, []byte(leaked), tc.source, goal); e == nil {
				t.Fatal("colon-terminated source was persisted")
			}
		})
	}
}

func TestDecodeResultRejectsCompleteShortSources(t *testing.T) {
	id := uuid.New()
	for _, tc := range []struct {
		name, source, leak string
		goal               bool
	}{
		{name: "chat one rune", source: "甲：乙", leak: "乙"},
		{name: "chat two runes", source: "甲：暗号", leak: "暗号"},
		{name: "chat three runes", source: "甲：暗号乙", leak: "暗号乙"},
		{name: "goal one rune", source: "乙", leak: "乙", goal: true},
		{name: "goal two runes", source: "暗号", leak: "暗号", goal: true},
		{name: "goal three runes", source: "暗号乙", leak: "暗号乙", goal: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			leaked := strings.Replace(sample, "提出可行下一步", "先确认"+tc.leak+"是否正确", 1)
			var goal *string
			if tc.goal {
				goal = &tc.source
			}
			if _, e := decodeResult(id, []byte(leaked), tc.source, goal); e == nil {
				t.Fatal("complete short source was persisted")
			}
		})
	}
}

func TestDecodeResultRejectsPunctuationOnlySources(t *testing.T) {
	id := uuid.New()
	for _, tc := range []struct {
		name, source string
		goal         bool
	}{
		{name: "chat punctuation", source: "？？？"},
		{name: "speaker-labelled punctuation", source: "甲：？？？"},
		{name: "goal punctuation", source: "？？？", goal: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			leaked := strings.Replace(sample, "提出可行下一步", "对方用「？？？」表达困惑", 1)
			var goal *string
			if tc.goal {
				goal = &tc.source
			}
			if _, e := decodeResult(id, []byte(leaked), tc.source, goal); e == nil {
				t.Fatal("punctuation-only source was persisted")
			}
		})
	}
}
