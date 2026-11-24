//go:build contract

package service

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/goccy/go-yaml"

	"high-eq/server/internal/privacy"
)

func TestPrivacyAccountRouteContract(t *testing.T) {
	body, err := os.ReadFile("../../../docs/api/app.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var contract struct {
		Paths map[string]map[string]struct {
			Responses map[string]struct {
				Ref string `yaml:"$ref"`
			} `yaml:"responses"`
		} `yaml:"paths"`
	}
	if err := yaml.Unmarshal(body, &contract); err != nil {
		t.Fatal(err)
	}

	router := newRouter(nil)
	for _, route := range []struct {
		method, path string
		frozen       bool
	}{
		{"GET", "/v1/me", true},
		{"PATCH", "/v1/me", false},
		{"POST", "/v1/me/closure", false},
		{"DELETE", "/v1/me/closure", true},
	} {
		t.Run(route.method+route.path, func(t *testing.T) {
			w := httptest.NewRecorder()
			router.ServeHTTP(w, httptest.NewRequest(route.method, route.path, nil))
			if w.Code != 401 {
				t.Errorf("anonymous route got %d, want 401", w.Code)
			}
			if frozen, ok := accountRoutes[route.method+" "+route.path]; !ok || frozen != route.frozen {
				t.Errorf("frozen policy (%v, implemented %v), want %v", frozen, ok, route.frozen)
			}
			if got := contract.Paths[route.path][strings.ToLower(route.method)].Responses["503"].Ref; got != "#/components/responses/E503ServiceUnavailable" {
				t.Errorf("privacy barrier 503 contract = %q", got)
			}
		})
	}
}

func TestPrivacyAccountBarrierResponse(t *testing.T) {
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	accountError(c, privacy.ErrHidden)
	var out struct {
		Code      string `json:"code"`
		Retryable bool   `json:"retryable"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
		t.Fatal(err)
	}
	if w.Code != 503 || out.Code != "service_unavailable" || !out.Retryable {
		t.Fatalf("privacy barrier got %d %s", w.Code, w.Body)
	}
}
