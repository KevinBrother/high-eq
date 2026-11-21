package adminops

import "testing"

func TestOperatorMonitoringPolicy(t *testing.T) {
	for _, key := range []string{"GET /metrics", "GET /prompt-models"} {
		if p := rules[key]; !p.live || p.super {
			t.Errorf("operator cannot use %s", key)
		}
	}
}
