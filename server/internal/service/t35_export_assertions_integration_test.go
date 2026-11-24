//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/training"
)

func t35Download(t *testing.T, router http.Handler, token string) *zip.Reader {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/me/export", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("GET /v1/me/export: %d: %s", w.Code, w.Body)
	}
	if got := w.Header().Get("Content-Type"); got != "application/zip" {
		t.Fatalf("export Content-Type = %q", got)
	}
	if got := w.Header().Get("Content-Disposition"); got != `attachment; filename="high-eq-export.zip"` {
		t.Fatalf("export Content-Disposition = %q", got)
	}
	z, err := zip.NewReader(bytes.NewReader(w.Body.Bytes()), int64(w.Body.Len()))
	if err != nil {
		t.Fatal(err)
	}
	return z
}

func t35Part(t *testing.T, z *zip.Reader, name string) []byte {
	t.Helper()
	f, err := z.Open(name + ".json")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	body, err := io.ReadAll(f)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func t35Decode(t *testing.T, body []byte, dst any) {
	t.Helper()
	if err := json.Unmarshal(body, dst); err != nil {
		t.Fatalf("decode ZIP entry: %v", err)
	}
}

func t35Exclude(t *testing.T, body []byte, forbidden ...string) {
	t.Helper()
	for _, value := range forbidden {
		if bytes.Contains(body, []byte(value)) {
			t.Fatalf("ZIP entry contains excluded field or fixture value %q", value)
		}
	}
}

func (h *practiceWire) exportDelete(t *testing.T, u app.Tokens, p string, id uuid.UUID, result training.Result) {
	t.Helper()
	archive := t35Download(t, h.s.Router(), u.AccessToken)
	data := t35Part(t, archive, "training")
	t35Exclude(t, data, `"worker":`, `"valid_until":`, `"settlement_pending":`, `"content_enc":`, `"request_id":`, `"client_message_id":`)
	var rows []struct {
		training.Session
		Source uuid.UUID `json:"source_id"`
	}
	t35Decode(t, data, &rows)
	detail := h.history(u, p)
	if detail.Setup == nil || detail.Setup.ID != id {
		t.Fatal("public session detail lost the submitted request ID")
	}
	detail.Setup.ID = uuid.Nil
	for i := range detail.Messages {
		t35Exclude(t, data, detail.Messages[i].ClientMessageId.String())
		detail.Messages[i].ClientMessageId = uuid.Nil
	}
	if len(rows) != 2 {
		t.Fatalf("training.json has %d sessions, want the owner's two attempts", len(rows))
	}
	var source uuid.UUID
	for _, row := range rows {
		if row.ID != id {
			continue
		}
		source = row.Source
		if row.Setup == nil || row.Setup.Level == nil ||
			!reflect.DeepEqual(row.Setup, detail.Setup) || !reflect.DeepEqual(row.Messages, detail.Messages) ||
			len(row.Messages) < 2 || row.Messages[0].Role != "user" || row.Messages[1].Role != "assistant" ||
			row.Result == nil || !reflect.DeepEqual(*row.Result, result) {
			t.Fatal("training.json is missing setup, messages or the completed result")
		}
		if h.number(`select count(*) from practice_messages where activity_id=$1 and position(convert_to($2,'UTF8') in content_enc)>0`, id, row.Messages[0].Text) != 0 {
			t.Fatal("plaintext at rest")
		}
	}
	if source == uuid.Nil {
		t.Fatal("training.json missing the owner's session and source ID")
	}
	if result.Progress != nil {
		growthData := t35Part(t, archive, "growth")
		t35Exclude(t, growthData, `"reason":`, `"review_activity_id":`, id.String())
		var drills []growth.DrillExportRecord
		t35Decode(t, growthData, &drills)
		var found bool
		for _, drill := range drills {
			found = found || drill.RecordType == "drill" && drill.LevelID == *detail.Level &&
				drill.TargetItem == "observation" && drill.Score == 25 && drill.Band == "pass" &&
				!drill.OccurredAt.IsZero() && drill.RetryAt == nil
		}
		if len(drills) != 2 || !found {
			t.Fatal("growth.json missing the owner's completed drill schedule")
		}
	}
	h.must(h.s.Data.Delete(h.ctx, privacy.Deletion{UserID: u.UserId, OperationID: uuid.New(), SourceID: source, Scope: "sessions"}))
	h.json(u.AccessToken, "GET", p, nil, 404, nil)
	for _, table := range []string{"practice_work", "practice_messages", "quota_attempts", "quota_ledger", "ai_calls", "scores", "drill_progress"} {
		if h.number(fmt.Sprintf("select count(*) from %s where activity_id=$1", table), id) != 0 {
			h.t.Fatal("retained", table)
		}
	}
}
