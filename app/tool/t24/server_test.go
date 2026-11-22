//go:build t24live

// Mounted into the T23 service test package only in an isolated Compose job.
package service

import (
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"os"
	"testing"
)

func TestT24LiveServer(t *testing.T) {
	token := os.Getenv("T24_FIXTURE_TOKEN")
	if token == "" {
		t.Fatal("T24_FIXTURE_TOKEN is required")
	}

	f := &reviewUpstream{entered: make(chan struct{}), resume: make(chan struct{})}
	close(f.resume)
	s := reviewRuntime(t, f)
	app := s.Router()

	writeJSON := func(w http.ResponseWriter, status int, value any) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		if err := json.NewEncoder(w).Encode(value); err != nil {
			t.Errorf("write fixture response: %v", err)
		}
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/__t24/state":
			got := r.Header.Get("X-T24-Fixture-Token")
			if len(got) != len(token) || subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			if r.Method != http.MethodGet {
				w.Header().Set("Allow", http.MethodGet)
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			writeJSON(w, http.StatusOK, map[string]int32{
				"analyses": f.analyses.Load(),
				"scores":   f.scores.Load(),
			})
		case "/__t24/mode":
			got := r.Header.Get("X-T24-Fixture-Token")
			if len(got) != len(token) || subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			if r.Method != http.MethodPut {
				w.Header().Set("Allow", http.MethodPut)
				http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
				return
			}
			var in struct {
				Mode *int32 `json:"mode"`
			}
			decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&in); err != nil || in.Mode == nil || *in.Mode < 0 || *in.Mode > 4 {
				http.Error(w, "invalid fixture mode", http.StatusBadRequest)
				return
			}
			f.mode.Store(*in.Mode)
			writeJSON(w, http.StatusOK, map[string]int32{"mode": f.mode.Load()})
		default:
			app.ServeHTTP(w, r)
		}
	})

	// The harness publishes this port only on the host's 127.0.0.1 interface.
	t.Fatal(http.ListenAndServe(":8080", handler))
}
