package training

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
)

func TestPreviousSessionContractAndValidation(t *testing.T) {
	id, previous := uuid.New(), uuid.New()
	var in Input
	raw, err := json.Marshal(map[string]any{
		"request_id":  id,
		"scene":       "work",
		"scenario":    "合成重练",
		"previous_id": previous,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &in); err != nil {
		t.Fatal(err)
	}
	if in.Previous == nil || *in.Previous != previous {
		t.Fatal("previous_id was not decoded")
	}

	scene, text := "work", "合成重练"
	nilPrevious := uuid.Nil
	if _, _, _, _, err = (Input{
		ID: id, Scene: &scene, Scenario: &text, Previous: &nilPrevious,
	}).describe(); err != accounts.ErrInvalid {
		t.Fatalf("nil previous_id accepted: %v", err)
	}
	other := Input{ID: id, Scene: &scene, Scenario: &text, Previous: &previous}
	if !reflect.DeepEqual(in, other) {
		t.Fatal("decode changed the idempotent setup")
	}
	other.Previous = nil
	if reflect.DeepEqual(in, other) {
		t.Fatal("previous_id is not part of the idempotency comparison")
	}
}

func TestSessionSummaryCannotProjectSetup(t *testing.T) {
	id, contact, previous := uuid.New(), uuid.New(), uuid.New()
	scene, text := "friends", "只用于本人会话详情的合成场景"
	r := record{
		Session: Session{SessionSummary: SessionSummary{
			ID:         id,
			Status:     "active",
			Mode:       "full_session",
			Messages:   []app.Message{},
			Settlement: Settlement{Status: "uncharged"},
		}},
		input: Input{
			ID: id, Scene: &scene, Scenario: &text,
			Contact: &contact, Previous: &previous,
		},
	}

	summaryJSON, err := json.Marshal(r.summary())
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"setup", "scenario", "contact_id", "previous_id"} {
		if containsJSONKey(summaryJSON, forbidden) {
			t.Fatalf("summary leaked %q: %s", forbidden, summaryJSON)
		}
	}
	if _, ok := reflect.TypeOf(SessionSummary{}).FieldByName("Setup"); ok {
		t.Fatal("SessionSummary exposes a setup field")
	}

	detail := r.detail()
	if detail.Setup == nil || detail.Setup.Scenario == nil || *detail.Setup.Scenario != text {
		t.Fatal("detail did not retain setup")
	}
	detailJSON, err := json.Marshal(detail)
	if err != nil {
		t.Fatal(err)
	}
	for _, required := range []string{"setup", "scenario", "contact_id", "previous_id"} {
		if !containsJSONKey(detailJSON, required) {
			t.Fatalf("detail lost %q: %s", required, detailJSON)
		}
	}

	items := reflect.TypeOf(Page{}).Field(0).Type
	if items.Kind() != reflect.Slice || items.Elem() != reflect.TypeOf(SessionSummary{}) {
		t.Fatalf("history page is not a summary-only projection: %v", items)
	}
}

func TestCreateReturnsSummaryInsteadOfDetail(t *testing.T) {
	method, ok := reflect.TypeOf((*Service)(nil)).MethodByName("Create")
	if !ok {
		t.Fatal("Service.Create is missing")
	}
	if got := method.Type.Out(0); got != reflect.TypeOf(SessionSummary{}) {
		t.Fatalf("Create returns %v; setup-bearing detail must be reserved for Get", got)
	}
}

func containsJSONKey(raw []byte, key string) bool {
	var value any
	if json.Unmarshal(raw, &value) != nil {
		return false
	}
	var walk func(any) bool
	walk = func(v any) bool {
		switch v := v.(type) {
		case map[string]any:
			if _, ok := v[key]; ok {
				return true
			}
			for _, child := range v {
				if walk(child) {
					return true
				}
			}
		case []any:
			for _, child := range v {
				if walk(child) {
					return true
				}
			}
		}
		return false
	}
	return walk(value)
}
