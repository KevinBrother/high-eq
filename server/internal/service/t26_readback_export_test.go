//go:build integration && t26flutter

package service

import (
	"testing"

	"github.com/google/uuid"
)

func TestT26PracticeExportReadback(t *testing.T) {
	session, level, source := uuid.New(), uuid.New(), uuid.New()
	userMessage, assistantMessage := uuid.New(), uuid.New()
	// The archive omits the request ID and both client message IDs.
	record := map[string]any{
		"session_id": session, "level_id": level, "source_id": source,
		"status": "complete", "mode": "full_session",
		"setup": map[string]any{"level_id": level},
		"messages": []map[string]any{
			{"id": userMessage, "role": "user", "seq": 1, "text": "合成提问。"},
			{"id": assistantMessage, "role": "assistant", "seq": 2, "text": "合成甲。合成乙。"},
		},
		"result": map[string]any{"score": map[string]any{
			"score_id": source, "target_turn": 1, "nvc": map[string]any{"total": 100},
		}},
	}
	practice, err := t26PracticeExport(record)
	if err != nil {
		t.Fatal(err)
	}
	if practice.ID != session || practice.Source != source || practice.Level == nil || *practice.Level != level ||
		practice.Setup == nil || practice.Setup.Level == nil || *practice.Setup.Level != level {
		t.Fatal("lost the practice session, source, or pinned setup level")
	}
	if len(practice.Messages) != 2 || practice.Messages[0].ID != userMessage || practice.Messages[1].ID != assistantMessage ||
		practice.Messages[0].Text != "合成提问。" || practice.Messages[1].Text != "合成甲。合成乙。" {
		t.Fatal("lost the exported message identities or contents")
	}
	if practice.Result == nil || practice.Result.Score == nil || practice.Result.Score.ID != source ||
		practice.Result.Score.TargetTurn == nil || *practice.Result.Score.TargetTurn != 1 || practice.Result.Score.NVC.Total != 100 {
		t.Fatal("lost the exported score, target turn, or total")
	}
}
