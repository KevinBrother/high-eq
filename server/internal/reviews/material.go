// Package reviews owns the text journal and its single, completed behavior score.
package reviews

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/scoring"
)

var ErrGeneration = errors.New("review generation failed")
var ErrModeration = errors.New("moderation unavailable")
var ErrConsent = errors.New("review disclosure not accepted")

func validScene(s string) bool {
	switch s {
	case "work", "partner", "family", "friends", "social":
		return true
	}
	return false
}
func valid(in app.ReviewInput) bool {
	if in.RequestId == uuid.Nil || in.Scene != nil && !validScene(string(*in.Scene)) {
		return false
	}
	for _, id := range []*uuid.UUID{in.ContactId, in.MarkId, in.SignalEventId} {
		if id != nil && *id == uuid.Nil {
			return false
		}
	}
	for _, s := range []string{in.Happened, in.MyFeeling, in.TheirPossibleFeeling, in.MyAction, in.NextAction} {
		if strings.TrimSpace(s) == "" {
			return false
		}
	}
	return true
}
func repair(b []byte) (string, error) {
	d := json.NewDecoder(bytes.NewReader(b))
	open, e := d.Token()
	if e != nil || open != json.Delim('{') {
		return "", ErrGeneration
	}
	key, e := d.Token()
	var s string
	if e != nil || key != "repair_phrase" || d.Decode(&s) != nil || d.More() {
		return "", ErrGeneration
	}
	if close, e := d.Token(); e != nil || close != json.Delim('}') || d.Decode(new(any)) != io.EOF {
		return "", ErrGeneration
	}
	s = strings.TrimSpace(s)
	if s == "" || !utf8.Valid(b) || utf8.RuneCountInString(s) > 80 {
		return "", ErrGeneration
	}
	core := strings.TrimRight(s, "。！？!?．.")
	if strings.TrimSpace(core) == "" || hasInnerSentenceBoundary(core) {
		return "", ErrGeneration
	}
	for _, bad := range strings.Fields("都是你的错 还不是因为你 你逼我的 你太敏感 都是我的错 我什么都听你的 只要你不生气") {
		if strings.Contains(s, bad) {
			return "", ErrGeneration
		}
	}
	return s, nil
}

func hasInnerSentenceBoundary(s string) bool {
	r := []rune(s)
	for i, c := range r {
		switch c {
		case '。', '．', '！', '？', '!', '?', '\n', '\r':
			return true
		case '.':
			// Keep decimal numbers readable while rejecting an ASCII full stop
			// that starts another sentence, with or without following whitespace.
			if i == 0 || i == len(r)-1 || !unicode.IsDigit(r[i-1]) || !unicode.IsDigit(r[i+1]) {
				return true
			}
		}
	}
	return false
}

type analyzeHooks struct {
	BeforeScore func() error
	Analysis    scoring.Hooks
	Scoring     scoring.Hooks
}

// The only scored turn is MyAction. Never send source IDs, timestamps, marks or sensor events.
func analyze(ctx context.Context, r scoring.Runner, scope gateway.Scope, in app.ReviewInput, profile, phrase string, checkpoint func(string) error, hooks analyzeHooks) (string, *scoring.Full, uuid.UUID, *gateway.Terminal, error) {
	scene := "日常交流"
	if in.Scene != nil {
		scene = string(*in.Scene)
	}
	bg := map[string]string{"happened": in.Happened, "my_feeling": in.MyFeeling, "their_possible_feeling": in.TheirPossibleFeeling, "next_action": in.NextAction}
	background, _ := json.Marshal(bg)
	if phrase == "" {
		bg["my_action"] = in.MyAction
		bg["scene"] = scene
		bg["profile_summary"] = profile
		b, _ := json.Marshal(bg)
		reply, e := r.Run(ctx, gateway.Call{Scope: scope, Task: gateway.ReviewAnalysis, Mode: gateway.JSONObject, Messages: []gateway.Message{{Role: "user", Content: string(b)}}, BeforeGenerate: hooks.Analysis.BeforeGenerate, OnGenerated: hooks.Analysis.OnGenerated, Generated: hooks.Analysis.Generated})
		if reply.Terminal != nil || e != nil {
			return "", nil, uuid.Nil, reply.Terminal, e
		}
		phrase, e = repair(reply.Result.Object)
		if e == nil {
			e = checkpoint(phrase)
		}
		if e != nil {
			return "", nil, uuid.Nil, nil, e
		}
	}
	if hooks.BeforeScore != nil {
		if e := hooks.BeforeScore(); e != nil {
			return "", nil, uuid.Nil, nil, e
		}
	}
	out, e := scoring.New(r, scope, hooks.Scoring).Score(ctx, scene, string(background), in.MyAction, profile)
	if out.Status != scoring.Success && out.Terminal == nil && e == nil {
		e = ErrGeneration
	}
	return phrase, out.Value, out.CallID, out.Terminal, e
}
