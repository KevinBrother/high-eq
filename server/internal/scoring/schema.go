package scoring

import (
	"bytes"
	"encoding/json"
	"io"
	"slices"
	"strings"
	"unicode/utf8"
)

type fields map[string]json.RawMessage

// Walk each object instead of decoding directly into structs: encoding/json
// otherwise accepts case-insensitive keys, duplicates and null scalar values.
func object(raw []byte, required string, optional ...string) (fields, bool) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	open, err := dec.Token()
	if err != nil || open != json.Delim('{') {
		return nil, false
	}
	keys := strings.Fields(required)
	f := fields{}
	for dec.More() {
		token, err := dec.Token()
		key, ok := token.(string)
		if err != nil || !ok || f[key] != nil || (!slices.Contains(keys, key) && !slices.Contains(optional, key)) {
			return nil, false
		}
		var val json.RawMessage
		if dec.Decode(&val) != nil {
			return nil, false
		}
		f[key] = val
	}
	close, err := dec.Token()
	if err != nil || close != json.Delim('}') {
		return nil, false
	}
	if _, err = dec.Token(); err != io.EOF {
		return nil, false
	}
	for _, key := range keys {
		if f[key] == nil {
			return nil, false
		}
	}
	return f, true
}
func (f fields) text(key string) string {
	var s string
	if json.Unmarshal(f[key], &s) != nil || strings.TrimSpace(s) == "" {
		return ""
	}
	return s
}
func (f fields) number(key string) int {
	var i *int
	if json.Unmarshal(f[key], &i) != nil || i == nil {
		return -1
	}
	return *i
}
func validScore(n int) bool { return n == 0 || n == 5 || n == 10 || n == 15 || n == 25 }
func item(raw []byte) (Item, bool) {
	f, ok := object(raw, "score reason")
	i := Item{f.number("score"), f.text("reason")}
	return i, ok && validScore(i.Score) && i.Reason != ""
}
func level(raw []byte) (Level, bool) {
	f, ok := object(raw, "level reason")
	v := Level{f.number("level"), f.text("reason")}
	return v, ok && v.Level >= 1 && v.Level <= 5 && v.Reason != ""
}

// ParseFull validates the model response, not a client payload. The only repair
// permitted by the standard is replacing an in-range total with the item sum.
func ParseFull(raw []byte, userTurns int) (*Full, error) {
	f, ok := object(raw, "safety_flag mode nvc emotion better_version why_better", "target_turn")
	if !ok || !utf8.Valid(raw) || userTurns < 1 || string(f["safety_flag"]) != "false" {
		return nil, ErrSchema
	}
	v := Full{Mode: f.text("mode"), BetterVersion: f.text("better_version"), WhyBetter: f.text("why_better")}
	if (v.Mode != "express" && v.Mode != "respond") || v.BetterVersion == "" || utf8.RuneCountInString(v.BetterVersion) > 80 || v.WhyBetter == "" {
		return nil, ErrSchema
	}
	if f["target_turn"] != nil {
		n := f.number("target_turn")
		if n < 1 || n > userTurns {
			return nil, ErrSchema
		}
		v.TargetTurn = &n
	}
	n, ok := object(f["nvc"], "observation feeling need request total")
	if !ok || n.number("total") < 0 || n.number("total") > 100 {
		return nil, ErrSchema
	}
	for key, dst := range map[string]*Item{"observation": &v.NVC.Observation, "feeling": &v.NVC.Feeling, "need": &v.NVC.Need, "request": &v.NVC.Request} {
		x, ok := item(n[key])
		if !ok {
			return nil, ErrSchema
		}
		*dst = x
		v.NVC.Total += x.Score
	}
	e, ok := object(f["emotion"], "read_others self_management relationship")
	if !ok {
		return nil, ErrSchema
	}
	for key, dst := range map[string]*Level{"read_others": &v.Emotion.ReadOthers, "self_management": &v.Emotion.SelfManagement, "relationship": &v.Emotion.Relationship} {
		x, ok := level(e[key])
		if !ok {
			return nil, ErrSchema
		}
		*dst = x
	}
	return &v, nil
}
func validTarget(s string) bool {
	return s == "observation" || s == "feeling" || s == "need" || s == "request"
}
func parseSkill(raw []byte, target string) (*Progress, error) {
	f, ok := object(raw, "target_item score reason")
	i := Item{f.number("score"), f.text("reason")}
	if !ok || !utf8.Valid(raw) || f.text("target_item") != target || i.Reason == "" || !validScore(i.Score) || (target != "observation" && (i.Score == 5 || i.Score == 15)) {
		return nil, ErrSchema
	}
	action := "retry_now"
	if i.Score == 25 {
		action = "pass"
	} else if i.Score >= 10 {
		action = "retry_in_three_days"
	}
	return &Progress{target, i, action}, nil
}
