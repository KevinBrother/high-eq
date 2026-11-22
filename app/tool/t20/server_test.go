//go:build t20live

// Mounted into the T19 service test package only in an isolated Compose job.
// The HTTP router, auth, PG, both Redis instances and settlement are real; only
// the TLS model/moderation/scoring upstream is scripted and loopback-only.
package service

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

type t20Control struct {
	wire    *practiceWire
	mu      sync.Mutex
	release func()
}

func (c *t20Control) stopHeldCall() {
	if c.release != nil {
		c.release()
		c.release = nil
	}
}
func (c *t20Control) reply(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
func (c *t20Control) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		c.reply(w, http.StatusMethodNotAllowed, map[string]string{"error": "POST required"})
		return
	}
	action := r.URL.Query().Get("action")
	c.mu.Lock()
	defer c.mu.Unlock()
	switch action {
	case "normal", "safety", "outage":
		c.stopHeldCall()
		c.wire.set(action)
	case "hold":
		c.stopHeldCall()
		c.release = c.wire.hold()
	case "release":
		c.stopHeldCall()
	case "cap":
		id, err := uuid.Parse(r.URL.Query().Get("session_id"))
		if err != nil {
			c.reply(w, http.StatusBadRequest, map[string]string{"error": "valid session_id required"})
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		tag, err := c.wire.s.db.Exec(ctx, `update practice_work set used_tokens=29990 where activity_id=$1`, id)
		if err != nil {
			c.reply(w, http.StatusInternalServerError, map[string]string{"error": "cap update failed"})
			return
		}
		if tag.RowsAffected() != 1 {
			c.reply(w, http.StatusNotFound, map[string]string{"error": "session not found"})
			return
		}
	default:
		c.reply(w, http.StatusBadRequest, map[string]string{"error": "unknown action"})
		return
	}
	c.reply(w, http.StatusOK, map[string]string{"action": action})
}

func TestT20LiveServer(t *testing.T) {
	h := newPracticeWire(t)
	// The fixture's in-process URL cannot cross the container boundary. The
	// harness publishes only 127.0.0.1, and the control route exists only here.
	h.api.Close()
	control := &t20Control{wire: h}
	mux := http.NewServeMux()
	mux.Handle("/_t20/control", control)
	mux.Handle("/", h.s.Router())
	err := http.ListenAndServe(":8080", mux)
	if !errors.Is(err, http.ErrServerClosed) {
		t.Fatal(err)
	}
}
