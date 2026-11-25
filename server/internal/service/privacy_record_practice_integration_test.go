//go:build integration

package service

import (
	"bytes"
	"errors"
	"io"
	"math"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/training"
)

func TestSamePracticeRightsWire(t *testing.T) {
	h := newPracticeWire(t)
	owner, other := h.assessmentUser(), h.user()
	var instrument app.GetInstrumentResult
	h.json(owner.AccessToken, "GET", "assessments/instrument", nil, 200, &instrument)
	h.json(owner.AccessToken, "POST", "assessments", app.SubmitAssessmentInput{
		Version: instrument.Version,
		Answers: []int{4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4},
	}, 200, nil)

	finish := func(user app.Tokens, mode string) (string, training.Session) {
		t.Helper()
		path := h.create(user, 5)
		h.send(user, path)
		h.set(mode)
		h.json(user.AccessToken, "POST", path+"/finish", nil, 200, nil)
		h.set("")
		return path, h.history(user, path)
	}
	targetPath, target := finish(owner, "first_score")
	controlPath, control := finish(owner, "")
	foreignPath, foreign := finish(other, "")
	if len(target.Messages) != 2 || target.Result == nil || target.Result.Score == nil ||
		target.Result.Score.TargetTurn == nil || *target.Result.Score.TargetTurn != 1 {
		t.Fatal("practice fixture did not produce messages and a cited score")
	}

	key := privacy.ScoreKey{UserID: owner.UserId, ActivityID: target.ID, SourceID: target.Result.Score.ID, Kind: "practice"}
	h.must(h.s.db.QueryRow(h.ctx, `select occurred_at from scores where id=$1 and activity_id=$2`, key.SourceID, target.ID).Scan(&key.OccurredAt))
	var callID uuid.UUID
	h.must(h.s.db.QueryRow(h.ctx, `select id from ai_calls where user_id=$1 and activity_id=$2 and score_id=$3 and task='scoring' and outcome='ok' limit 1`,
		key.UserID, key.ActivityID, key.SourceID).Scan(&callID))

	before := t35Download(t, h.s.Router(), owner.AccessToken)
	var trainingRows []struct {
		training.Session
		Source uuid.UUID `json:"source_id"`
	}
	t35Decode(t, t35Part(t, before, "training"), &trainingRows)
	var found bool
	for _, row := range trainingRows {
		if row.ID != target.ID {
			continue
		}
		found = true
		if row.Source != key.SourceID || row.Result == nil || row.Result.Score == nil ||
			row.Result.Score.ID != key.SourceID || row.Result.Score.TargetTurn == nil ||
			*row.Result.Score.TargetTurn != 1 || row.Result.Score.NVC.Observation.Reason == "" ||
			len(row.Messages) != len(target.Messages) {
			t.Fatal("export did not retain the target's message and score chain")
		}
		for i, message := range row.Messages {
			if message.Id != target.Messages[i].Id || message.Text != target.Messages[i].Text {
				t.Fatal("exported message differs from practice history")
			}
		}
	}
	if !found || !bytes.Contains(t35Part(t, before, "growth"), []byte(key.SourceID.String())) ||
		!bytes.Contains(t35Part(t, before, "ai_calls"), []byte(callID.String())) {
		t.Fatal("target practice is missing from its export chain")
	}
	t35Exclude(t, t35Part(t, before, "training"), foreign.ID.String())

	checkGrowth := func(count int, behavior float64) {
		t.Helper()
		var got app.GetGrowthResult
		h.json(owner.AccessToken, "GET", "growth", nil, 200, &got)
		if got.ValidBehaviorCount != count || got.WleisPercent == nil || got.TrainingReference == nil {
			t.Fatalf("growth reference = %+v, want %d behavior scores and a reference", got, count)
		}
		want := (float64(*got.WleisPercent) + behavior) / 2
		if math.Abs(float64(*got.TrainingReference)-want) > 1e-4 {
			t.Fatalf("growth reference = %v, want %v", *got.TrainingReference, want)
		}
	}
	checkGrowth(2, 71) // The target contributes 57 and the control contributes 85.

	var records wireRecordLocatorPage
	h.json(owner.AccessToken, "GET", "me/data/sessions", nil, 200, &records)
	if len(records.Items) != 2 || !recordPageContains(records, target.ID) || !recordPageContains(records, control.ID) {
		t.Fatalf("practice locators do not match the owner's sessions: %+v", records)
	}
	deletePath := "me/data/sessions/" + target.ID.String()
	h.json(other.AccessToken, "DELETE", deletePath, nil, 404, nil)
	response := h.open(owner.AccessToken, "DELETE", deletePath, nil, 200)
	defer response.Body.Close()
	receipt, err := io.ReadAll(response.Body)
	h.must(err)
	if !bytes.Equal(receipt, []byte(`{"ok":true}`)) {
		t.Fatalf("practice deletion receipt = %s", receipt)
	}
	h.json(owner.AccessToken, "GET", targetPath, nil, 404, nil)
	h.json(owner.AccessToken, "GET", "me/data/sessions", nil, 200, &records)
	if len(records.Items) != 1 || !recordPageContains(records, control.ID) {
		t.Fatalf("practice locators after deletion = %+v", records)
	}
	h.history(owner, controlPath)
	h.history(other, foreignPath)
	checkGrowth(1, 85)

	if err := h.s.Bus.PublishScore(h.ctx, events.Score{ScoreKey: key}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("deleted practice replay = %v, want no source", err)
	}
	checkGrowth(1, 85)
	var residues bool
	h.must(h.s.db.QueryRow(h.ctx, `select exists(select from activities where id=$1)
		or exists(select from practice_messages where activity_id=$1)
		or exists(select from practice_work where activity_id=$1)
		or exists(select from scores where activity_id=$1 or id=$2)
		or exists(select from growth_scores where score_id=$2)
		or exists(select from ai_calls where activity_id=$1 or score_id=$2)`, target.ID, key.SourceID).Scan(&residues))
	if residues {
		t.Fatal("deleted practice retains a source or derivative")
	}
	after := t35Download(t, h.s.Router(), owner.AccessToken)
	for _, module := range []string{"training", "growth", "ai_calls"} {
		t35Exclude(t, t35Part(t, after, module), target.ID.String(), key.SourceID.String(), callID.String())
	}
	if !bytes.Contains(t35Part(t, after, "training"), []byte(control.ID.String())) {
		t.Fatal("the surviving practice disappeared from export")
	}
}

func recordPageContains(page wireRecordLocatorPage, id uuid.UUID) bool {
	for _, item := range page.Items {
		if item.Id != nil && *item.Id == id {
			return true
		}
	}
	return false
}
