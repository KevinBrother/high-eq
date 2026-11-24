//go:build integration && t26flutter

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/growth"
)

func t35RunExportFlutter(t *testing.T, ctx context.Context, origin, scratch string, a, b t35ExportOwner) {
	t.Helper()
	ctx, cancel := context.WithTimeout(ctx, 4*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Getenv("T27_HISTORY_DART"), os.Getenv("T27_HISTORY_FLUTTER_SNAPSHOT"),
		"--no-version-check", "test", "--no-pub", "--reporter", "json", "tool/t35-privacy/formal_export_test.dart")
	cmd.Dir = os.Getenv("T27_HISTORY_APP")
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
	cmd.WaitDelay = 5 * time.Second
	for _, key := range []string{
		"PATH", "LANG", "LC_ALL", "HOME", "TMPDIR", "PUB_CACHE", "FLUTTER_ROOT",
		"CI", "FLUTTER_SUPPRESS_ANALYTICS", "DART_SUPPRESS_ANALYTICS",
		"XDG_CACHE_HOME", "XDG_CONFIG_HOME", "FLUTTER_STORAGE_BASE_URL", "PUB_HOSTED_URL",
	} {
		if value, present := os.LookupEnv(key); present {
			cmd.Env = append(cmd.Env, key+"="+value)
		}
	}
	cmd.Env = append(cmd.Env,
		"T35_EXPORT_ORIGIN="+origin, "T35_EXPORT_SCRATCH="+scratch,
		"T35_EXPORT_TICKET_A="+a.ticket, "T35_EXPORT_TICKET_B="+b.ticket,
		"T35_EXPORT_ACCOUNT_A="+a.account.String(), "T35_EXPORT_ACCOUNT_B="+b.account.String(),
	)
	receipt, err := os.CreateTemp(scratch, "flutter-*.jsonl")
	if err != nil {
		t.Fatal("could not open private Flutter receipt stream")
	}
	defer receipt.Close()
	cmd.Stdout = receipt
	runErr := cmd.Run()
	if _, err := receipt.Seek(0, io.SeekStart); err != nil {
		t.Fatal("could not rewind Flutter receipt stream")
	}
	confirmed := t35RequireFlutterReceipt(t, receipt)
	if runErr != nil || !confirmed {
		t.Fatal("Flutter did not complete the exact export test and handoff receipts")
	}
}

func t35RequireFlutterReceipt(t *testing.T, stream io.Reader) bool {
	t.Helper()
	const name = "T35 formal account export over real HTTP (variant: TargetPlatform.iOS)"
	var required = []string{"BEGIN(page.account-a)", "PASS(page.account-a)", "BEGIN(page.account-b)", "PASS(page.account-b)"}
	decoder := json.NewDecoder(stream)
	testID, phase := -1, 0
	testDone, runDone := false, false
	for {
		var e struct {
			Type, Result, Message string
			TestID                int
			Test                  struct {
				ID   int
				Name string
			}
			Hidden, Skipped, Success bool
		}
		if err := decoder.Decode(&e); err != nil {
			return err == io.EOF && phase == len(required) && testDone && runDone
		}
		if runDone {
			return false
		}
		switch {
		case e.Type == "testStart" && e.Test.Name == name:
			if testID != -1 {
				return false
			}
			testID = e.Test.ID
		case e.Type == "print" && testID != -1 && e.TestID == testID && slices.Contains(required, e.Message):
			if testDone || phase == len(required) || e.Message != required[phase] {
				return false
			}
			t.Log(required[phase])
			phase++
		case e.Type == "testDone" && testID != -1 && e.TestID == testID:
			if testDone || e.Hidden || e.Skipped || e.Result != "success" {
				return false
			}
			testDone = true
		case e.Type == "done":
			if !e.Success {
				return false
			}
			runDone = true
		}
	}
}

// This inventory is the export contract. Every entry below must come from the
// app-delivered HTTP response, including partitions with no seeded rows.
var t35ExportModules = []string{
	"accounts", "ai_calls", "assessments", "chat_imports", "emotion", "growth", "manual_marks",
	"membership", "payments", "profiles", "replies", "reviews", "training",
}

func t35ReadDeliveredZIP(t *testing.T, scratch, label string, owner uuid.UUID, observed t35ExportObservation) map[string][]byte {
	t.Helper()
	const manifest = "manifest.json"
	const maxSyntheticBytes = 2 << 20
	file, err := os.Open(filepath.Join(scratch, "accepted-"+label+".zip"))
	if err != nil {
		t.Fatal("synthetic receiver did not capture a ZIP")
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maxSyntheticBytes+1))
	if err != nil || len(raw) > maxSyntheticBytes || !observed.valid || observed.account != owner || sha256.Sum256(raw) != observed.digest {
		t.Fatal("receiver ZIP must match the owner's authenticated HTTP 200 ZIP response byte for byte")
	}
	archive, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil || len(archive.File) != len(t35ExportModules)+1 || archive.File[0].Name != manifest {
		t.Fatal("delivered ZIP must begin with a manifest and contain every partition")
	}
	parts := make(map[string][]byte, len(archive.File))
	for _, entry := range archive.File {
		if _, duplicate := parts[entry.Name]; duplicate {
			t.Fatal("delivered ZIP contains a duplicate name")
		}
		r, err := entry.Open()
		if err != nil {
			t.Fatal("delivered ZIP entry cannot be opened")
		}
		body, err := io.ReadAll(io.LimitReader(r, maxSyntheticBytes+1))
		r.Close()
		if err != nil || len(body) > maxSyntheticBytes {
			t.Fatal("delivered ZIP entry failed full read or checksum")
		}
		parts[entry.Name] = body
	}
	var inventory struct{ Modules, Files []string }
	if json.Unmarshal(parts[manifest], &inventory) != nil {
		t.Fatal("delivered ZIP manifest cannot be decoded")
	}
	expectedFiles := []string{manifest}
	for _, module := range t35ExportModules {
		name := module + ".json"
		expectedFiles = append(expectedFiles, name)
		var rows []json.RawMessage
		if json.Unmarshal(parts[name], &rows) != nil || rows == nil {
			t.Fatal("delivered ZIP is missing a partition or contains invalid partition JSON")
		}
	}
	slices.Sort(expectedFiles)
	slices.Sort(inventory.Files)
	slices.Sort(inventory.Modules)
	if !slices.Equal(inventory.Modules, t35ExportModules) || !slices.Equal(inventory.Files, expectedFiles) {
		t.Fatal("delivered manifest and actual runtime partitions must match the complete contract")
	}
	return parts
}

type t35ExportAssessment struct {
	assessment.Result
	Version string `json:"version"`
	Answers []int  `json:"answers"`
}

func t35CheckExportOwner(t *testing.T, parts map[string][]byte, owner, foreign t35ExportOwner) {
	t.Helper()
	if err := t35VerifyExportOwner(parts, owner, foreign); err != nil {
		t.Fatal(err)
	}
}

func t35VerifyExportOwner(parts map[string][]byte, owner, foreign t35ExportOwner) error {
	var accounts []struct {
		Kind   string
		UserID uuid.UUID `json:"user_id"`
	}
	var marks []app.Mark
	if json.Unmarshal(parts["accounts.json"], &accounts) != nil || len(accounts) == 0 ||
		accounts[0].Kind != "account" || accounts[0].UserID != owner.account ||
		json.Unmarshal(parts["manual_marks.json"], &marks) != nil || len(marks) != 1 ||
		marks[0].Id != owner.mark || marks[0].Scene == nil || *marks[0].Scene != owner.scene {
		return errors.New("delivered ZIP must contain the authenticated owner's persisted account and manual mark")
	}
	if !t35MatchesAssessment(parts["assessments.json"], owner.assessment) {
		return errors.New("delivered assessments must contain exactly the owner's seeded assessment and content")
	}
	if !t35MatchesPlanOwnership(parts["growth.json"], owner) {
		return errors.New("delivered growth plans must reference the owner's assessment and include its seeded plan")
	}
	foreignIDs := []uuid.UUID{foreign.account, foreign.mark, foreign.assessment.ID}
	for _, body := range parts {
		for _, id := range foreignIDs {
			if bytes.Contains(body, []byte(id.String())) {
				return errors.New("delivered ZIP contains another account's fixture data")
			}
		}
	}
	return nil
}

func t35MatchesAssessment(body []byte, expected t35ExportAssessment) bool {
	// Compare JSON objects so key order is immaterial and an omitted zero-valued
	// field cannot match a real score of zero from the public result.
	var rows []map[string]any
	if json.Unmarshal(body, &rows) != nil || len(rows) != 1 {
		return false
	}
	var expectedRow map[string]any
	encoded, err := json.Marshal(expected)
	return err == nil && json.Unmarshal(encoded, &expectedRow) == nil && reflect.DeepEqual(rows[0], expectedRow)
}

func t35MatchesPlanOwnership(body []byte, owner t35ExportOwner) bool {
	var rows []growth.PlanExportRecord
	if json.Unmarshal(body, &rows) != nil {
		return false
	}
	seeded := 0
	for _, row := range rows {
		if row.RecordType != "plan" {
			continue
		}
		if row.AssessmentID == nil || *row.AssessmentID != owner.assessment.ID || len(row.Items) == 0 {
			return false
		}
		if row.Day == owner.seedPlanDay {
			seeded++
		}
	}
	return seeded == 1
}
