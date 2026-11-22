//go:build integration

package service

import (
	"github.com/google/uuid"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/training"
	"testing"
)

func (h *practiceWire) checkRelaunch(t *testing.T) {
	h.set("normal")
	u, other := h.user(), h.user()
	h.json(u.AccessToken, "PUT", "me/consents/contacts", map[string]any{"version": "v1", "granted": true}, 200, nil)
	var c app.Contact
	h.json(u.AccessToken, "POST", "contacts", map[string]string{"nickname": "合成对象", "scene": "work"}, 200, &c)
	scenario := "合成预演目标"
	base, next := uuid.New(), uuid.New()
	makeInput := func(id uuid.UUID) map[string]any {
		return map[string]any{"request_id": id, "contact_id": c.Id, "scene": "work", "scenario": scenario}
	}
	var created map[string]any
	h.json(u.AccessToken, "POST", "sessions", makeInput(base), 200, &created)
	if _, ok := created["setup"]; ok {
		t.Fatal("create exposed repeat parameters")
	}
	first := "sessions/" + base.String()
	again := "sessions/" + next.String()
	in := makeInput(next)
	in["previous_id"] = base
	h.json(u.AccessToken, "POST", "sessions", in, 400, nil) // never compare against an unfinished session
	h.send(u, first)
	h.json(u.AccessToken, "POST", first+"/finish", nil, 200, nil)
	h.json(other.AccessToken, "GET", first, nil, 404, nil)
	h.json(other.AccessToken, "POST", "sessions", map[string]any{"request_id": uuid.New(), "scene": "work", "scenario": scenario, "previous_id": base}, 400, nil)
	different := makeInput(uuid.New())
	different["previous_id"] = base
	different["scenario"] = "另一次预演"
	h.json(u.AccessToken, "POST", "sessions", different, 400, nil)
	h.json(u.AccessToken, "POST", "sessions", in, 200, nil)
	var detail training.Session
	h.json(u.AccessToken, "GET", again, nil, 200, &detail)
	if detail.Setup == nil || detail.Setup.Previous == nil || *detail.Setup.Previous != base || detail.Setup.Scenario == nil || *detail.Setup.Scenario != scenario || detail.Setup.Contact == nil || *detail.Setup.Contact != c.Id {
		t.Fatal("owner did not get exact repeat context")
	}
	unrelated := h.create(u, 0)
	var hist struct {
		Items []map[string]any `json:"items"`
	}
	h.json(u.AccessToken, "GET", "sessions", nil, 200, &hist)
	if len(hist.Items) != 3 {
		t.Fatalf("history items=%d", len(hist.Items))
	}
	for _, i := range hist.Items {
		if _, ok := i["setup"]; ok {
			t.Fatal("history unexpectedly exposed launch context")
		}
	}
	h.json(u.AccessToken, "DELETE", "contacts/"+c.Id.String(), nil, 200, nil)
	h.json(u.AccessToken, "GET", first, nil, 404, nil)
	h.json(u.AccessToken, "GET", again, nil, 404, nil)
	h.json(u.AccessToken, "GET", unrelated, nil, 200, nil)
}
