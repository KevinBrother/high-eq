package service

import (
	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/reviews"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestReviewHTTPBoundary(t *testing.T) {
	r := gin.New()
	app.RegisterHandlersWithOptions(r, appAPI{}, app.GinServerOptions{Middlewares: []app.MiddlewareFunc{gate(nil)}})
	path := "/v1/reviews/" + uuid.NewString()
	for _, op := range [][2]string{{"POST", "/v1/reviews"}, {"GET", "/v1/reviews"}, {"GET", path}, {"DELETE", path}} {
		w := httptest.NewRecorder()
		r.ServeHTTP(w, httptest.NewRequest(op[0], op[1], nil))
		if w.Code != 401 {
			t.Fatalf("%s %s: %d", op[0], op[1], w.Code)
		}
	}
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	reviewError(c, reviews.ErrModeration)
	if w.Code != 503 || !strings.Contains(w.Body.String(), `"retryable":true`) || strings.Contains(w.Body.String(), gateway.HelpMessage) {
		t.Fatal("moderation outage must not become safety")
	}
	w = httptest.NewRecorder()
	c, _ = gin.CreateTestContext(w)
	reviewError(c, reviews.ErrRecoveryExpired)
	if w.Code != 409 || !strings.Contains(w.Body.String(), `"code":"conflict"`) || !strings.Contains(w.Body.String(), "恢复窗口已过期") {
		t.Fatalf("expired recovery response: %d %s", w.Code, w.Body.String())
	}
}
