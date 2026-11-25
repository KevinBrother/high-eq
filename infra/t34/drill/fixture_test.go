package main

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestDrillProgressAADMatchesProductionEnvelope(t *testing.T) {
	user, source := uuid.New(), uuid.New()
	want := []byte("practice/progress/" + user.String() + "/" + source.String())
	if got := drillProgressAAD(user, source); !bytes.Equal(got, want) {
		t.Fatalf("progress AAD = %q, want %q", got, want)
	}
}

func TestWaitHealthRetriesUntilProductionHealthIsReady(t *testing.T) {
	var attempts atomic.Int32
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/health" {
			t.Errorf("unexpected health path %q", r.URL.Path)
		}
		if attempts.Add(1) < 2 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := waitHealth(ctx, handler); err != nil {
		t.Fatalf("health wait failed: %v", err)
	}
	if attempts.Load() != 2 {
		t.Fatalf("health attempts = %d, want 2", attempts.Load())
	}
}

func TestWaitHealthFailsClosedOnTimeout(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	if err := waitHealth(ctx, handler); err == nil {
		t.Fatal("health wait succeeded without a 200 response")
	}
}

func TestStatusKeepsBearerMaterialOutOfTheURL(t *testing.T) {
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RawQuery != "" || r.URL.Path != "/v1/me" {
			t.Errorf("request leaked material into URL: %s", r.URL.String())
		}
		if r.Header.Get("Authorization") != "Bearer synthetic-token" {
			t.Errorf("authorization header missing")
		}
		w.WriteHeader(http.StatusOK)
	})
	code := status(context.Background(), handler, "/v1/me", "synthetic-token")
	if code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
}

func capturePanic(fn func()) (recovered any) {
	defer func() { recovered = recover() }()
	fn()
	return nil
}

func TestMustReportsFixedStageAndCallerWithoutLeakingError(t *testing.T) {
	previousStage, previousSite := activeStage, activeSite
	t.Cleanup(func() {
		activeStage, activeSite = previousStage, previousSite
	})
	activeStage = stageSeedAssessmentSubmit
	activeSite = drillSite{file: "fallback.go", line: 1}
	const secret = "postgres://user:password@db/example SELECT token"
	report := safeFailureMessage(
		capturePanic(func() { must(errors.New(secret)) }),
		activeStage,
		activeSite,
	)
	if !strings.HasPrefix(report, "offline drill refused stage=seed.assessment_submit at=fixture_test.go:") {
		t.Fatalf("unexpected failure report %q", report)
	}
	if strings.Count(report, "\n") != 1 {
		t.Fatalf("failure report must be one line, got %q", report)
	}
	for _, forbidden := range []string{secret, "postgres://", "SELECT", "token", "password", "panic", "goroutine"} {
		if strings.Contains(report, forbidden) {
			t.Fatalf("failure report leaked %q: %q", forbidden, report)
		}
	}
}

func TestUnknownPanicUsesOnlyTheStageEntrySite(t *testing.T) {
	report := safeFailureMessage(
		"postgres://user:password@db/example SELECT token",
		stageSeedDrillEvent,
		drillSite{file: "fixture.go", line: 130},
	)
	const want = "offline drill refused stage=seed.drill_event at=fixture.go:130\n"
	if report != want {
		t.Fatalf("failure report = %q, want %q", report, want)
	}
}
