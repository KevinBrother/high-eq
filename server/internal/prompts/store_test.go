package prompts

import (
	"context"
	"errors"
	"testing"

	"high-eq/server/internal/api/admin"
)

func TestCreateRejectsUnsupportedVariableBeforeStorage(t *testing.T) {
	_, err := Create(context.Background(), nil, admin.CreatePromptVersionJSONBody{
		Task:     admin.TaskReplySuggestion,
		Template: "literal {{profile}}",
	})
	if !errors.Is(err, ErrVariable) {
		t.Fatalf("Create reused storage for an unsupported variable: %v", err)
	}
}
