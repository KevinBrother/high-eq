package training

import (
	"errors"
	"testing"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
)

func TestRunnerErrorPreservesAuthorization(t *testing.T) {
	for _, want := range []error{
		accounts.ErrAuth,
		accounts.ErrInvalid,
		privacy.ErrHidden,
		ErrConsent,
		membership.ErrForbidden,
		membership.ErrConflict,
	} {
		if got := runnerError(want); !errors.Is(got, want) {
			t.Fatalf("runner error %v was folded into %v", want, got)
		}
	}
	if got := runnerError(errors.New("provider failed")); !errors.Is(got, ErrGeneration) {
		t.Fatalf("provider failure mapped to %v want generation error", got)
	}
}
