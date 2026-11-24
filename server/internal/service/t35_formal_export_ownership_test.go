//go:build integration && t26flutter

package service

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/assessment"
	"high-eq/server/internal/growth"
)

func TestT35ExportAssessmentOwnership(t *testing.T) {
	a := t35OwnershipFixture("work", 1, assessment.Dimension{Mean: 1, Level: "L1"})
	b := t35OwnershipFixture("partner", 7, assessment.Dimension{Mean: 7, Percent: 100, Display: 100, Level: "L5"})
	for _, pair := range []struct{ owner, foreign t35ExportOwner }{{a, b}, {b, a}} {
		owner, foreign := pair.owner, pair.foreign
		t.Run(owner.scene, func(t *testing.T) {
			scratch := t.TempDir()
			observed := t35WriteOwnershipFixture(t, scratch, owner, "", nil)
			original := t35ReadDeliveredZIP(t, scratch, "fixture", owner.account, observed)
			contentSwap := owner.assessment
			contentSwap.Answers = foreign.assessment.Answers
			foreignScores := owner.assessment
			foreignScores.Scores = foreign.assessment.Scores
			for _, tc := range []struct {
				name, partition string
				rows            any
			}{
				{name: "original"},
				{"swapped-assessment", "assessments", []t35ExportAssessment{foreign.assessment}},
				{"foreign-answers-with-own-id", "assessments", []t35ExportAssessment{contentSwap}},
				{"foreign-scores-with-own-id", "assessments", []t35ExportAssessment{foreignScores}},
				{"missing-assessment", "assessments", []t35ExportAssessment{}},
				{"duplicate-assessment", "assessments", []t35ExportAssessment{owner.assessment, owner.assessment}},
				{"swapped-plan", "growth", []growth.PlanExportRecord{t35FixturePlan(foreign)}},
				{"missing-plan", "growth", []growth.PlanExportRecord{}},
				{"foreign-assessment-in-another-partition", "training", []map[string]uuid.UUID{{"source_id": foreign.assessment.ID}}},
			} {
				t.Run(tc.name, func(t *testing.T) {
					parts := original
					if tc.partition != "" {
						scratch := t.TempDir()
						observed := t35WriteOwnershipFixture(t, scratch, owner, tc.partition, tc.rows)
						parts = t35ReadDeliveredZIP(t, scratch, "fixture", owner.account, observed)
						for name, body := range original {
							wantChanged := name == tc.partition+".json"
							if gotChanged := !bytes.Equal(body, parts[name]); gotChanged != wantChanged {
								t.Fatalf("unexpected fixture mutation of %s", name)
							}
						}
					}
					err := t35VerifyExportOwner(parts, owner, foreign)
					if tc.partition == "" && err != nil {
						t.Fatalf("correct delivery was rejected: %v", err)
					}
					if tc.partition != "" && err == nil {
						t.Fatal("wrong ownership evidence was accepted after the ZIP and HTTP digest matched")
					}
				})
			}
		})
	}
}

func t35OwnershipFixture(scene string, option int, score assessment.Dimension) t35ExportOwner {
	at := time.Date(2026, time.January, 2, 3, 4, 5, 0, time.UTC)
	return t35ExportOwner{
		account:     uuid.New(),
		mark:        uuid.New(),
		scene:       scene,
		seedPlanDay: at.Format(time.DateOnly),
		assessment: t35ExportAssessment{
			Result: assessment.Result{
				ID:             uuid.New(),
				CompletedAt:    at,
				NextEligibleAt: at.AddDate(0, 0, 28),
				Scores: assessment.Scores{
					Dimensions: map[string]assessment.Dimension{"SEA": score, "OEA": score, "UOE": score, "ROE": score},
					Total:      score,
				},
			},
			Version: "t26-synthetic-1",
			Answers: slices.Repeat([]int{option}, 16),
		},
	}
}

func t35FixturePlan(owner t35ExportOwner) growth.PlanExportRecord {
	return growth.PlanExportRecord{
		RecordType:   "plan",
		AssessmentID: &owner.assessment.ID,
		Day:          owner.seedPlanDay,
		Items: []growth.PlanItemExportRecord{
			{ID: uuid.NewSHA1(owner.account, []byte("item")), Kind: "exercise", Title: "Synthetic exercise", ContentID: uuid.NameSpaceOID},
		},
	}
}

func t35WriteOwnershipFixture(t *testing.T, scratch string, owner t35ExportOwner, partition string, replacement any) t35ExportObservation {
	t.Helper()
	rows := map[string]any{
		"accounts":     []map[string]any{{"kind": "account", "user_id": owner.account}},
		"manual_marks": []map[string]any{{"id": owner.mark, "scene": owner.scene}},
		"assessments":  []t35ExportAssessment{owner.assessment},
		"growth":       []growth.PlanExportRecord{t35FixturePlan(owner)},
	}
	if partition != "" {
		rows[partition] = replacement
	}
	var body bytes.Buffer
	archive := zip.NewWriter(&body)
	write := func(name string, value any) {
		t.Helper()
		entry, err := archive.Create(name)
		if err != nil || json.NewEncoder(entry).Encode(value) != nil {
			t.Fatal("could not encode synthetic ZIP entry")
		}
	}
	files := []string{"manifest.json"}
	for _, module := range t35ExportModules {
		files = append(files, module+".json")
	}
	write("manifest.json", map[string][]string{"modules": t35ExportModules, "files": files})
	for _, module := range t35ExportModules {
		value, exists := rows[module]
		if !exists {
			value = []json.RawMessage{}
		}
		write(module+".json", value)
	}
	if archive.Close() != nil || os.WriteFile(filepath.Join(scratch, "accepted-fixture.zip"), body.Bytes(), 0600) != nil {
		t.Fatal("could not deliver synthetic ZIP")
	}
	// Model the digest of the response that actually carried this archive.
	// A server can send the wrong row while the receiver gets every byte intact.
	return t35ExportObservation{account: owner.account, valid: true, digest: sha256.Sum256(body.Bytes())}
}
