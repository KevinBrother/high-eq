// Package prompts stores platform configuration, never per-account text or assignments.
package prompts

import (
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"

	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/promptvars"
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

type variableContract struct {
	maxBytes   int
	guaranteed bool
}

// taskVariables is the executable contract between the admin editor and every
// production gateway call. maxBytes is the largest value actually supplied by
// current producers, not the larger custom-scenario input ceiling. A task may
// use only these variables, including in historical versions selected by a
// rollback. A template must render visibly using only values every production
// call supplies; scoring's optional variables are empty on some legal calls.
var taskVariables = map[admin.Task]map[string]variableContract{
	admin.TaskRolePlay: {
		"scene": {maxBytes: promptvars.RolePlaySceneMaxBytes, guaranteed: true},
	},
	admin.TaskScoring: {
		"assessment":  {maxBytes: promptvars.ScoringAssessmentMaxBytes, guaranteed: true},
		"target_item": {maxBytes: promptvars.ScoringTargetItemMaxBytes},
		"retry":       {maxBytes: promptvars.ScoringRetryMaxBytes},
	},
	admin.TaskProfileInference: {
		"scene":   {maxBytes: promptvars.ProfileSceneMaxBytes, guaranteed: true},
		"options": {maxBytes: promptvars.ProfileOptionsMaxBytes, guaranteed: true},
	},
	admin.TaskReplySuggestion:   {},
	admin.TaskReviewAnalysis:    {},
	admin.TaskContentGeneration: {},
	admin.TaskClassification:    {},
}

func Validate(template string) error { _, err := expand(template, nil, false); return err }

// ValidateForTask keeps syntactically valid but unusable template variables
// out of storage and out of a release. Render still reports missing values at
// runtime, but only for variables the task actually supplies.
func ValidateForTask(task admin.Task, template string) error {
	allowed, ok := taskVariables[task]
	if !ok {
		return ErrTemplate
	}
	if err := Validate(template); err != nil {
		return err
	}
	for i := 0; i+1 < len(template); i++ {
		if template[i:i+2] != "{{" {
			continue
		}
		end := strings.Index(template[i+2:], "}}")
		key := strings.Trim(template[i+2:i+2+end], " \t")
		if _, ok := allowed[key]; !ok {
			return ErrVariable
		}
		i += end + 3
	}
	minimal := make(map[string]string, len(allowed))
	for key, contract := range allowed {
		minimal[key] = ""
		if contract.guaranteed {
			minimal[key] = "x"
		}
	}
	if _, err := Render(template, minimal); err != nil {
		return ErrVariable
	}
	worstCase := make(map[string]string, len(allowed))
	for key, contract := range allowed {
		worstCase[key] = strings.Repeat("x", contract.maxBytes)
	}
	if _, err := Render(template, worstCase); err != nil {
		return ErrVariable
	}
	return nil
}

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
