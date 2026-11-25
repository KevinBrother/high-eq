package app_test

import (
	"maps"
	"strings"
	"testing"

	"github.com/getkin/kin-openapi/openapi3"
)

type object = map[string]any

func TestDataRecordPageContract(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromFile("../../../../docs/api/app.yaml")
	if err != nil {
		t.Fatal(err)
	}
	path := doc.Paths.Find("/v1/me/data/{kind}")
	if path == nil || path.Get == nil {
		t.Fatal("GET /v1/me/data/{kind} is missing")
	}
	for _, status := range []int{400, 401, 500, 503} {
		if path.Get.Responses.Status(status) == nil {
			t.Fatalf("record list response %d is missing", status)
		}
	}
	response := path.Get.Responses.Status(200)
	schema := response.Value.Content.Get("application/json").Schema.Value
	items := schema.Properties["items"]
	if items == nil || items.Value == nil {
		t.Fatal("DataRecordPage.items schema is missing")
	}
	for _, want := range []string{"OAS 3.0", "运行时", "错 kind", "混合 kind"} {
		if !strings.Contains(items.Value.Description, want) {
			t.Errorf("DataRecordPage.items description does not contain %q: %q", want, items.Value.Description)
		}
	}
	page := func(records ...any) object {
		if records == nil {
			records = []any{}
		}
		return object{"items": records, "next_cursor": nil}
	}
	change := func(base object, field string, value any) object {
		row := maps.Clone(base)
		row[field] = value
		return row
	}
	omit := func(base object, field string) object {
		row := maps.Clone(base)
		delete(row, field)
		return row
	}
	const id = "019abb00-1000-7000-8000-1234deadbeef"
	ordinary := object{"kind": "assessments", "id": id, "label": "测评", "recorded_at": "2026-11-21T09:30:00.123456789+08:00"}
	contact := object{"kind": "contacts", "id": id, "label": "关系人", "recorded_at": nil}
	window := object{"kind": "signal_windows", "label": "语音窗口", "channel": "voice", "recorded_at": "2026-11-21T09:30:30+08:00"}

	valid := map[string]object{
		"empty":         page(),
		"contact":       page(contact),
		"window":        page(window),
		"zero fraction": page(change(window, "recorded_at", "2026-11-21T09:30:00.000-05:45")),
		"calendar leap": page(change(ordinary, "recorded_at", "2000-02-29T09:30:00Z")),
		"opaque cursor": change(page(ordinary), "next_cursor", strings.Repeat("x", 300)),
	}
	for _, kind := range []string{"assessments", "sessions", "reviews", "replies", "manual_marks", "signal_events"} {
		valid[kind] = page(change(ordinary, "kind", kind))
	}
	for name, payload := range valid {
		t.Run(name, func(t *testing.T) {
			if err := schema.VisitJSON(payload, openapi3.EnableFormatValidation()); err != nil {
				t.Fatal(err)
			}
		})
	}

	invalid := map[string]object{
		"missing id":             page(omit(ordinary, "id")),
		"missing contact id":     page(omit(contact, "id")),
		"invalid id":             page(change(ordinary, "id", "0000")),
		"ordinary null time":     page(change(ordinary, "recorded_at", nil)),
		"contact time":           page(change(contact, "recorded_at", ordinary["recorded_at"])),
		"no contact time key":    page(omit(contact, "recorded_at")),
		"window missing channel": page(omit(window, "channel")),
		"window id":              page(change(window, "id", id)),
		"null ordinary channel":  page(change(ordinary, "channel", nil)),
		"bad hour":               page(change(window, "recorded_at", "2026-11-21T25:00:00Z")),
		"bad offset":             page(change(window, "recorded_at", "2026-11-21T09:30:30+08:60")),
		"no timezone":            page(change(window, "recorded_at", "2026-11-21T09:30:30")),
		"not aligned":            page(change(window, "recorded_at", "2026-11-21T09:30:31+08:00")),
		"fractional window":      page(change(window, "recorded_at", "2026-11-21T09:30:00.000000001Z")),
		"bad calendar":           page(change(ordinary, "recorded_at", "2100-02-29T09:30:00Z")),
		"unknown record field":   page(change(ordinary, "source_id", id)),
		"unknown page field":     change(page(ordinary), "source_id", id),
		"empty label":            page(change(ordinary, "label", "")),
		"empty cursor":           change(page(ordinary), "next_cursor", ""),
		"long cursor":            change(page(ordinary), "next_cursor", strings.Repeat("x", 301)),
		"missing cursor":         omit(page(ordinary), "next_cursor"),
	}
	for name, payload := range invalid {
		t.Run(name, func(t *testing.T) {
			if err := schema.VisitJSON(payload, openapi3.EnableFormatValidation()); err == nil {
				t.Fatalf("accepted invalid payload: %#v", payload)
			}
		})
	}
}

func TestWindowDeleteStartsAtContract(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromFile("../../../../docs/api/app.yaml")
	if err != nil {
		t.Fatal(err)
	}
	path := doc.Paths.Find("/v1/signal-windows")
	if path == nil || path.Delete == nil {
		t.Fatal("DELETE /v1/signal-windows is missing")
	}
	var startsAt *openapi3.Schema
	for _, parameter := range path.Delete.Parameters {
		if parameter.Value != nil && parameter.Value.In == "query" && parameter.Value.Name == "starts_at" {
			if parameter.Value.Schema == nil || parameter.Value.Schema.Value == nil {
				t.Fatal("starts_at schema is missing")
			}
			startsAt = parameter.Value.Schema.Value
			break
		}
	}
	if startsAt == nil {
		t.Fatal("starts_at query parameter is missing")
	}
	if !strings.Contains(startsAt.Description, "带时区") || !strings.Contains(startsAt.Description, "30 秒") {
		t.Fatalf("starts_at description does not state timezone and alignment: %q", startsAt.Description)
	}

	for _, value := range []string{
		"2026-11-21T09:00:00+08:00",
		"2026-11-21T09:00:30Z",
	} {
		t.Run("valid/"+value, func(t *testing.T) {
			if err := startsAt.VisitJSON(value, openapi3.EnableFormatValidation()); err != nil {
				t.Fatalf("rejected valid starts_at %q: %v", value, err)
			}
		})
	}
	for _, value := range []string{
		"2026-11-21T09:00:01+08:00",
		"2026-11-21T09:00:00",
		"2026-11-21T09:00:00+08:60",
	} {
		t.Run("invalid/"+value, func(t *testing.T) {
			if err := startsAt.VisitJSON(value, openapi3.EnableFormatValidation()); err == nil {
				t.Fatalf("accepted invalid starts_at %q", value)
			}
		})
	}
}

func TestSelectedSourceDeleteContract(t *testing.T) {
	doc, err := openapi3.NewLoader().LoadFromFile("../../../../docs/api/app.yaml")
	if err != nil {
		t.Fatal(err)
	}
	path := doc.Paths.Find("/v1/me/data/{kind}/{id}")
	if path == nil || path.Delete == nil {
		t.Fatal("DELETE /v1/me/data/{kind}/{id} is missing")
	}
	responses := path.Delete.Responses
	if responses.Status(501) != nil {
		t.Error("selected-record deletion still advertises 501")
	}
	for status, ref := range map[int]string{
		400: "E400", 401: "E401", 404: "E404", 500: "E500", 503: "E503ServiceUnavailable",
	} {
		if response := responses.Status(status); response == nil || response.Ref != "#/components/responses/"+ref {
			t.Errorf("response %d does not reference %s", status, ref)
		}
	}
	ack := responses.Status(200).Value.Content.Get("application/json").Schema.Value
	if err := ack.VisitJSON(object{"ok": true}); err != nil {
		t.Fatalf("rejected successful receipt: %v", err)
	}
	for _, payload := range []object{{}, {"ok": false}, {"ok": true, "id": "unexpected"}} {
		if err := ack.VisitJSON(payload); err == nil {
			t.Errorf("accepted invalid deletion receipt: %#v", payload)
		}
	}
}
