//go:build integration

package service

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestRecordLocatorRawHTTPQueryBoundary(t *testing.T) {
	f := newDeletionHTTPFixture(t)
	owner := f.register(t, uuid.NewString())
	other := f.register(t, uuid.NewString())

	newestAt := time.Date(2026, 11, 24, 10, 0, 0, 0, time.UTC)
	olderAt := newestAt.Add(-time.Minute)
	otherAt := olderAt.Add(-time.Minute)
	newest, older, otherRecord := uuid.New(), uuid.New(), uuid.New()
	f.exec(t, `insert into assessments(id,user_id,instrument_version,answers_enc,scores_enc,completed_at)
		values($1,$2,'fixture',$3,$4,$5),($6,$2,'fixture',$7,$8,$9),($10,$11,'fixture',$12,$13,$14)`,
		newest, owner.UserId, []byte("RAW-OWNER-NEWEST"), []byte("RAW-SCORE-NEWEST"), newestAt,
		older, []byte("RAW-OWNER-OLDER"), []byte("RAW-SCORE-OLDER"), olderAt,
		otherRecord, other.UserId, []byte("RAW-OTHER"), []byte("RAW-OTHER-SCORE"), otherAt,
	)

	server := httptest.NewServer(f.Router())
	defer server.Close()

	request := func(requestURI, token string) (int, []byte) {
		t.Helper()
		return rawRecordListRequest(t, server.URL, requestURI, token)
	}
	page := func(status int, body []byte) wireRecordLocatorPage {
		t.Helper()
		if status != http.StatusOK {
			t.Fatalf("record page status = %d, want 200: %s", status, body)
		}
		var out wireRecordLocatorPage
		decoder := json.NewDecoder(bytes.NewReader(body))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&out); err != nil {
			t.Fatalf("decode record page: %v: %s", err, body)
		}
		return out
	}

	status, body := request("/v1/me/data/assessments?limit=1", owner.AccessToken)
	first := page(status, body)
	if len(first.Items) != 1 || first.Items[0].Id == nil || *first.Items[0].Id != newest || first.NextCursor == nil {
		t.Fatalf("first raw record page = %+v: %s", first, body)
	}
	cursor := url.QueryEscape(*first.NextCursor)

	status, body = request("/v1/me/data/assessments?limit=1&cursor="+cursor, owner.AccessToken)
	second := page(status, body)
	if len(second.Items) != 1 || second.Items[0].Id == nil || *second.Items[0].Id != older {
		t.Fatalf("second raw record page = %+v: %s", second, body)
	}
	if *second.Items[0].Id == *first.Items[0].Id {
		t.Fatal("raw cursor pagination repeated the first page")
	}

	status, body = request("/v1/me/data/assessments?cursor="+cursor, other.AccessToken)
	crossAccount := page(status, body)
	if len(crossAccount.Items) != 1 || crossAccount.Items[0].Id == nil || *crossAccount.Items[0].Id != otherRecord {
		t.Fatalf("owner cursor on other account = %+v: %s", crossAccount, body)
	}
	for _, ownerID := range []uuid.UUID{newest, older} {
		if bytes.Contains(body, []byte(ownerID.String())) {
			t.Fatalf("other account read owner record %s through shared cursor: %s", ownerID, body)
		}
	}

	malformed := []string{
		"/v1/me/data/assessments?cursor=%ZZ",
		"/v1/me/data/assessments?limit=%ZZ",
		"/v1/me/data/assessments?limit=1&limit=2",
		"/v1/me/data/assessments?cursor=" + cursor + "&cursor=" + cursor,
	}
	for _, requestURI := range malformed {
		status, body = request(requestURI, owner.AccessToken)
		if status != http.StatusBadRequest {
			t.Fatalf("raw request %q = %d, want 400: %s", requestURI, status, body)
		}
		var wireErr struct {
			Code string `json:"code"`
		}
		if err := json.Unmarshal(body, &wireErr); err != nil || wireErr.Code != "invalid_argument" {
			t.Fatalf("raw request %q error = %v, code %q: %s", requestURI, err, wireErr.Code, body)
		}
		for _, forbidden := range []string{
			`"items"`, `"next_cursor"`, newest.String(), older.String(), otherRecord.String(),
			"RAW-OWNER", "RAW-OTHER", "RAW-SCORE",
		} {
			if bytes.Contains(body, []byte(forbidden)) {
				t.Fatalf("raw request %q leaked %q: %s", requestURI, forbidden, body)
			}
		}
	}
}

func rawRecordListRequest(t *testing.T, serverURL, requestURI, token string) (int, []byte) {
	t.Helper()
	target, err := url.Parse(serverURL)
	requireDeletionFixture(t, err)
	conn, err := net.DialTimeout("tcp", target.Host, 5*time.Second)
	requireDeletionFixture(t, err)
	defer conn.Close()

	wire := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n", requestURI, target.Host)
	if token != "" {
		wire += "Authorization: Bearer " + token + "\r\n"
	}
	wire += "\r\n"
	if _, err := io.WriteString(conn, wire); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodGet})
	requireDeletionFixture(t, err)
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	requireDeletionFixture(t, err)
	return response.StatusCode, body
}
