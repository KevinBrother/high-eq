package service

import (
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestEmotionRequiresAuthenticatedSession(t *testing.T) {
	r := (&Runtime{}).Router()
	for _, op := range [][2]string{{"POST", "signal-windows"}, {"GET", "signal-baselines"}, {"DELETE", "signal-windows?channel=voice&starts_at=" + time.Now().UTC().Format(time.RFC3339)}, {"POST", "signal-events"}, {"GET", "signal-events"}, {"PATCH", "signal-events/" + uuid.NewString()}} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(op[0], "/v1/"+op[1], nil))
		if w.Code != 401 {
			t.Errorf("%v: %d", op, w.Code)
		}
	}
}
