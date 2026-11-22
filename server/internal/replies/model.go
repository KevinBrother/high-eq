// Package replies owns non-streaming, moderated coaching requests and their feedback.
package replies

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"unicode"

	"github.com/google/uuid"
	"high-eq/server/internal/api/app"
)

var errShape = errors.New("invalid reply object")

// Exact keys, including case and multiplicity: never reinterpret an ambiguous
// reviewed object with encoding/json's last-value-wins struct decoding.
func fields(raw []byte, names ...string) (map[string]json.RawMessage, error) {
	d := json.NewDecoder(bytes.NewReader(raw))
	tok, e := d.Token()
	if e != nil || tok != json.Delim('{') {
		return nil, errShape
	}
	out := map[string]json.RawMessage{}
	for d.More() {
		tok, e := d.Token()
		k, ok := tok.(string)
		if e != nil || !ok || out[k] != nil {
			return nil, errShape
		}
		var v json.RawMessage
		if d.Decode(&v) != nil {
			return nil, errShape
		}
		out[k] = v
	}
	if _, e = d.Token(); e != nil || d.Decode(new(any)) != io.EOF || len(out) != len(names) {
		return nil, errShape
	}
	for _, k := range names {
		if out[k] == nil {
			return nil, errShape
		}
	}
	return out, nil
}

// sourceFragments returns every normalized four-rune window from a source
// line, or the complete normalized line when it is shorter. A speaker label is
// not a privacy boundary: stripping it must not make a quoted sentence safe to
// persist.
func sourceFragments(text string) []string {
	const minRunes = 4
	var out []string
	seen := map[string]struct{}{}
	add := func(value string) {
		runes := []rune(normalizedText(value))
		if len(runes) == 0 {
			// Punctuation-only sources have no normalized text, but they are still
			// source text. Keep the whitespace-free original as a fallback so an
			// output quoting it cannot turn it into durable history.
			fragment := compactText(value)
			if fragment != "" {
				if _, ok := seen[fragment]; !ok {
					seen[fragment] = struct{}{}
					out = append(out, fragment)
				}
			}
			return
		}
		if len(runes) < minRunes {
			fragment := string(runes)
			if _, ok := seen[fragment]; !ok {
				seen[fragment] = struct{}{}
				out = append(out, fragment)
			}
			return
		}
		for i := 0; i+minRunes <= len(runes); i++ {
			fragment := string(runes[i : i+minRunes])
			if _, ok := seen[fragment]; ok {
				continue
			}
			seen[fragment] = struct{}{}
			out = append(out, fragment)
		}
	}
	for _, line := range strings.FieldsFunc(text, func(r rune) bool { return r == '\r' || r == '\n' }) {
		line = strings.TrimSpace(line)
		// Keep the whole line as well as its speakerless body. A speaker label is
		// not a privacy boundary, and a colon-only line must still contribute its
		// complete short source fragment.
		add(line)
		if i := strings.IndexAny(line, "：:"); i > 0 {
			prefix := []rune(line[:i])
			if len(prefix) <= 20 && !strings.ContainsAny(string(prefix), "，。！？；,.!?;") {
				add(strings.TrimSpace(string([]rune(line)[len(prefix)+1:])))
			}
		}
	}
	return out
}

func normalizedText(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) || strings.ContainsRune("，。！？；：、,.!?;:\"'“”‘’（）()【】[]", r) {
			return -1
		}
		return unicode.ToLower(r)
	}, s)
}

func compactText(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsSpace(r) {
			return -1
		}
		return unicode.ToLower(r)
	}, s)
}

func leaksSource(value string, fragments []string) bool {
	normalized, compact := normalizedText(value), compactText(value)
	for _, fragment := range fragments {
		if n := normalizedText(fragment); n != "" && strings.Contains(normalized, n) {
			return true
		}
		if c := compactText(fragment); c != "" && strings.Contains(compact, c) {
			return true
		}
	}
	return false
}

func decodeResult(id uuid.UUID, raw []byte, chat string, goal *string) (v app.Reply, err error) {
	root, e := fields(raw, "possible_feeling", "possible_need", "suggestions")
	if e != nil {
		return v, e
	}
	var options []json.RawMessage
	if json.Unmarshal(root["suggestions"], &options) != nil || len(options) < 2 || len(options) > 3 {
		return v, errShape
	}
	for _, r := range options {
		if _, e = fields(r, "style", "text", "reason"); e != nil {
			return v, e
		}
	}
	if json.Unmarshal(raw, &v) != nil {
		return v, errShape
	}
	v.Id = id
	// A model that quotes an imported line, even without its speaker label,
	// cannot turn it into long-lived history.
	fragments := sourceFragments(chat)
	if goal != nil {
		fragments = append(fragments, sourceFragments(*goal)...)
	}
	valid := func(s string) bool {
		return strings.TrimSpace(s) != "" && !leaksSource(s, fragments)
	}
	if !valid(v.PossibleFeeling) || !valid(v.PossibleNeed) {
		return v, errShape
	}
	seen := map[string]bool{}
	for _, s := range v.Suggestions {
		k := strings.ToLower(strings.TrimSpace(s.Style))
		if seen[k] || !valid(s.Style) || !valid(s.Text) || !valid(s.Reason) {
			return v, errShape
		}
		seen[k] = true
	}
	return v, nil
}
