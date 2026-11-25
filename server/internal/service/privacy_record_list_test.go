package service

import (
	"encoding/json"
	"errors"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/recordlocator"
)

func TestDataRecordRawQueryIsStrictForCursorAndLimit(t *testing.T) {
	cursor := url.QueryEscape("valid-cursor")
	tests := map[string]string{
		"empty":                  "",
		"valid":                  "limit=20&cursor=" + cursor,
		"unknown parameter":      "userId=another-user",
		"unknown duplicate":      "tag=one&tag=two",
		"malformed cursor":       "cursor=%ZZ",
		"malformed limit":        "limit=%ZZ",
		"duplicate cursor":       "cursor=one&cursor=two",
		"duplicate limit":        "limit=1&limit=2",
		"malformed cursor value": "cursor=one&cursor=%ZZ",
	}
	wantInvalid := map[string]bool{
		"malformed cursor":       true,
		"malformed limit":        true,
		"duplicate cursor":       true,
		"duplicate limit":        true,
		"malformed cursor value": true,
	}
	for name, rawQuery := range tests {
		t.Run(name, func(t *testing.T) {
			err := validateDataRecordQuery(rawQuery)
			if got := errors.Is(err, recordlocator.ErrInvalidQuery); got != wantInvalid[name] {
				t.Fatalf("validateDataRecordQuery(%q) error = %v, want invalid=%t", rawQuery, err, wantInvalid[name])
			}
		})
	}
}

func TestDataRecordListRequiresAuthentication(t *testing.T) {
	router := newRouterWithHealth(nil, nil)
	request := httptest.NewRequest("GET", "/v1/me/data/assessments", nil)
	response := httptest.NewRecorder()

	router.ServeHTTP(response, request)

	if response.Code != 401 {
		t.Fatalf("GET /v1/me/data/assessments: got %d, want 401: %s", response.Code, response.Body.String())
	}
	var body app.Error
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("response is not an API error: %v: %s", err, response.Body.String())
	}
	if body.Code != "unauthenticated" {
		t.Fatalf("error code = %q, want unauthenticated", body.Code)
	}
}

func TestDataRecordPageAcceptsOnlyTheRequestedKind(t *testing.T) {
	recordedAt := time.Date(2026, 11, 24, 9, 30, 0, 0, time.FixedZone("CST", 8*60*60))
	cursor := "next-page"

	for _, kind := range recordlocator.AllKinds() {
		t.Run(string(kind), func(t *testing.T) {
			item := recordlocator.Item{
				Kind:  kind,
				ID:    uuid.New(),
				Label: "static label",
			}
			if kind == recordlocator.KindContact {
				item.RecordedAt = nil
			} else {
				item.RecordedAt = &recordedAt
			}
			if kind == recordlocator.KindSignalWindows {
				item.Channel = recordlocator.ChannelVoice
			}

			page, err := dataRecordPage(kind, recordlocator.Page{
				Items:      []recordlocator.Item{item},
				NextCursor: &cursor,
			})
			if err != nil {
				t.Fatalf("dataRecordPage(%q): %v", kind, err)
			}
			if len(page.Items) != 1 || page.NextCursor == nil || *page.NextCursor != cursor {
				t.Fatalf("page = %+v", page)
			}

			body, err := json.Marshal(page)
			if err != nil {
				t.Fatal(err)
			}
			var wire struct {
				Items []struct {
					Kind       string  `json:"kind"`
					Id         string  `json:"id"`
					Label      string  `json:"label"`
					RecordedAt *string `json:"recorded_at"`
					Channel    *string `json:"channel"`
				} `json:"items"`
			}
			if err := json.Unmarshal(body, &wire); err != nil {
				t.Fatal(err)
			}
			if len(wire.Items) != 1 || wire.Items[0].Kind != string(kind) {
				t.Fatalf("wire page = %s", body)
			}
			if kind == recordlocator.KindContact {
				if wire.Items[0].RecordedAt != nil {
					t.Fatalf("contact recorded_at = %v, want null: %s", *wire.Items[0].RecordedAt, body)
				}
				return
			}
			if wire.Items[0].RecordedAt == nil {
				t.Fatalf("timed record omitted recorded_at: %s", body)
			}
			if kind == recordlocator.KindSignalWindows {
				if wire.Items[0].Channel == nil || *wire.Items[0].Channel != string(recordlocator.ChannelVoice) {
					t.Fatalf("window channel = %v: %s", wire.Items[0].Channel, body)
				}
				if wire.Items[0].Id != "" {
					t.Fatalf("window has unexpected id %q: %s", wire.Items[0].Id, body)
				}
				return
			}
			if wire.Items[0].Id != item.ID.String() {
				t.Fatalf("record id = %q, want %q: %s", wire.Items[0].Id, item.ID, body)
			}
		})
	}
}

func TestDataRecordPageRejectsWrongAndMixedKinds(t *testing.T) {
	recordedAt := time.Date(2026, 11, 24, 9, 30, 0, 0, time.UTC)
	matching := recordlocator.Item{
		Kind:       recordlocator.KindAssessments,
		ID:         uuid.New(),
		Label:      "assessment",
		RecordedAt: &recordedAt,
	}
	wrong := recordlocator.Item{
		Kind:       recordlocator.KindReviews,
		ID:         uuid.New(),
		Label:      "review",
		RecordedAt: &recordedAt,
	}

	tests := map[string]recordlocator.Page{
		"single wrong kind": {Items: []recordlocator.Item{wrong}},
		"mixed kinds":       {Items: []recordlocator.Item{matching, wrong}},
	}
	for name, page := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := dataRecordPage(recordlocator.KindAssessments, page)
			if !errors.Is(err, errDataRecordKindMismatch) {
				t.Fatalf("error = %v, want %v", err, errDataRecordKindMismatch)
			}
		})
	}
}

func TestDataRecordPageRejectsTimedRecordWithoutRecordedAt(t *testing.T) {
	for _, kind := range recordlocator.AllKinds() {
		if kind == recordlocator.KindContact {
			continue
		}
		t.Run(string(kind), func(t *testing.T) {
			_, err := dataRecordPage(kind, recordlocator.Page{Items: []recordlocator.Item{{
				Kind:  kind,
				ID:    uuid.New(),
				Label: "timed record",
			}}})
			if !errors.Is(err, errDataRecordTimeMissing) {
				t.Fatalf("error = %v, want %v", err, errDataRecordTimeMissing)
			}
		})
	}
}
