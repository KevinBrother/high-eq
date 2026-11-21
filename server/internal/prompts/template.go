// Package prompts stores platform configuration, never per-account text or assignments.
package prompts

import (
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"
)

// Errors crossing service boundaries are fixed strings, not snippets or variable values.
var (
	ErrTemplate = errors.New("invalid prompt template")
	ErrVariable = errors.New("missing or invalid prompt variable")
	ErrRelease  = errors.New("invalid prompt release")
	ErrNotFound = errors.New("prompt configuration not found")
	ErrStorage  = errors.New("prompt configuration unavailable")
)

const maxTemplate = 64 << 10
const maxRendered = 256 << 10

var identifier = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

func Validate(template string) error { _, err := expand(template, nil, false); return err }
func Render(template string, vars map[string]string) (string, error) {
	return expand(template, vars, true)
}

// Only double-brace identifiers are interpreted. Replacements are never parsed again.
func expand(src string, vars map[string]string, render bool) (string, error) {
	if len(src) > maxTemplate || !utf8.ValidString(src) || strings.ContainsRune(src, 0) || strings.TrimSpace(src) == "" {
		return "", ErrTemplate
	}
	var out strings.Builder
	write := func(s string) bool {
		if !render {
			return true
		}
		if len(s) > maxRendered-out.Len() {
			return false
		}
		out.WriteString(s)
		return true
	}
	start := 0
	for i := 0; i+1 < len(src); {
		switch src[i : i+2] {
		case "}}":
			return "", ErrTemplate
		case "{{":
			if !write(src[start:i]) {
				return "", ErrVariable
			}
			i += 2
			end := strings.Index(src[i:], "}}")
			if end < 0 {
				return "", ErrTemplate
			}
			key := strings.Trim(src[i:i+end], " \t")
			if !identifier.MatchString(key) {
				return "", ErrTemplate
			}
			if render {
				v, ok := vars[key]
				if !ok || len(v) > maxRendered-out.Len() || !utf8.ValidString(v) || strings.ContainsRune(v, 0) || !write(v) {
					return "", ErrVariable
				}
			}
			i += end + 2
			start = i
		default:
			i++
		}
	}
	if !write(src[start:]) || render && strings.TrimSpace(out.String()) == "" {
		return "", ErrVariable
	}
	return out.String(), nil
}
