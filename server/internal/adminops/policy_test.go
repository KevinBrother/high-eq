package adminops

import (
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

// A new generated route must be classified even if its feature is not yet live.
func TestPolicyCoversContract(t *testing.T) {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	Register(r, nil)
	seen := map[string]bool{}
	for _, route := range r.Routes() {
		key := route.Method + " " + strings.TrimPrefix(route.Path, "/admin/v1")
		p, ok := rules[key]
		if !ok || p.action == "" || p.target == "" || seen[p.action] {
			t.Errorf("missing/ambiguous admin policy for %s", key)
		}
		seen[p.action] = true
	}
	if len(seen) != len(rules) {
		t.Error("stale admin policy")
	}
}
