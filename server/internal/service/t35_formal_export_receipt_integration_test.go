//go:build integration && t26flutter

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
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
		"T35_EXPORT_MARK_A_KEEP="+a.mark.String(), "T35_EXPORT_MARK_A_DELETE="+a.deleteMark.String(),
		"T35_EXPORT_MARK_B="+b.mark.String(),
	)
	receipt, err := os.CreateTemp(scratch, "flutter-*.jsonl")
	if err != nil {
		t.Fatal("could not open private Flutter receipt stream")
	}
	receiptPath := receipt.Name()
	defer os.Remove(receiptPath)
	var stderr bytes.Buffer
	cmd.Stdout = receipt
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	if err := receipt.Close(); err != nil {
		t.Fatal("could not close private Flutter receipt stream")
	}
	if receiptDir := t35ExportReceiptDir(t); receiptDir != "" {
		t35CopyReceipt(t, receiptPath, filepath.Join(receiptDir, "flutter.jsonl"))
		if err := os.WriteFile(filepath.Join(receiptDir, "flutter.stderr.log"), stderr.Bytes(), 0o600); err != nil {
			t.Fatal("could not preserve Flutter stderr receipt")
		}
	}
	receipt, err = os.Open(receiptPath)
	if err != nil {
		t.Fatal("could not reopen private Flutter receipt stream")
	}
	defer receipt.Close()
	confirmed := t35RequireFlutterReceipt(t, receipt)
	if runErr != nil || !confirmed {
		t.Fatal("Flutter did not complete the exact selected-mark export journey and handoff receipts")
	}
}

func t35RequireFlutterReceipt(t *testing.T, stream io.Reader) bool {
	t.Helper()
	const name = "T35 formal account export over real HTTP (variant: TargetPlatform.iOS)"
	required := []string{
		"BEGIN(page.account-a.before)", "PASS(page.account-a.before)",
		"BEGIN(page.account-a.delete)", "PASS(page.account-a.delete)",
		"BEGIN(page.account-a.after)", "PASS(page.account-a.after)",
		"BEGIN(page.account-b.before)", "PASS(page.account-b.before)",
		"BEGIN(page.account-b.after)", "PASS(page.account-b.after)",
	}
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
	path := filepath.Join(scratch, "accepted-"+label+".zip")
	file, err := os.Open(path)
	if err != nil {
		t.Fatal("synthetic receiver did not capture a ZIP")
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maxSyntheticBytes+1))
	if err != nil || len(raw) > maxSyntheticBytes || !observed.valid || observed.account != owner ||
		sha256.Sum256(raw) != observed.digest || len(raw) != observed.size {
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
	if receiptDir := t35ExportReceiptDir(t); receiptDir != "" {
		t35CopyReceipt(t, path, filepath.Join(receiptDir, "accepted-"+label+".zip"))
		t35WriteJSONReceipt(t, filepath.Join(receiptDir, "wire."+label+".json"), map[string]any{
			"schema": "t35-formal-export-wire-v1", "label": label, "account": owner,
			"method": "GET", "path": "/v1/me/export", "query": "", "accept": "application/zip",
			"status": 200, "content_type": "application/zip",
			"content_disposition": `attachment; filename="high-eq-export.zip"`,
			"validated":           true, "archive_bytes": len(raw), "archive_sha256": hex.EncodeToString(observed.digest[:]),
		})
		t35WriteJSONReceipt(t, filepath.Join(receiptDir, "archive."+label+".json"), map[string]any{
			"schema": "t35-formal-export-archive-v1", "label": label, "account": owner,
			"archive_bytes": len(raw), "archive_sha256": hex.EncodeToString(observed.digest[:]),
			"entries": t35PartitionReceipt(parts),
		})
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

func t35CheckExportOwnerBeforeDelete(t *testing.T, parts map[string][]byte, owner, foreign t35ExportOwner) {
	t.Helper()
	if err := t35VerifyExportOwnerBeforeDelete(parts, owner, foreign); err != nil {
		t.Fatal(err)
	}
}

func t35CheckSelectedMarkDeletion(t *testing.T, before, after map[string][]byte, owner t35ExportOwner) {
	t.Helper()
	if err := t35VerifySelectedMarkDeletion(before, after, owner); err != nil {
		t.Fatal(err)
	}
	t35WriteSelectedMarkDiffReceipt(t, before, after, owner)
}

func t35CheckPartitionsIdentical(t *testing.T, before, after map[string][]byte) {
	t.Helper()
	if err := t35VerifyPartitionsIdentical(before, after); err != nil {
		t.Fatal(err)
	}
}

func t35VerifyExportOwner(parts map[string][]byte, owner, foreign t35ExportOwner) error {
	if err := t35VerifyExportOwnerEnvelope(parts, owner, foreign); err != nil {
		return err
	}
	var marks []app.Mark
	if json.Unmarshal(parts["manual_marks.json"], &marks) != nil || len(marks) != 1 ||
		marks[0].Id != owner.mark || marks[0].Scene == nil || *marks[0].Scene != owner.scene {
		return errors.New("delivered ZIP must contain the authenticated owner's persisted account and manual mark")
	}
	return nil
}

func t35VerifyExportOwnerBeforeDelete(parts map[string][]byte, owner, foreign t35ExportOwner) error {
	if err := t35VerifyExportOwnerEnvelope(parts, owner, foreign); err != nil {
		return err
	}
	var marks []app.Mark
	if json.Unmarshal(parts["manual_marks.json"], &marks) != nil || len(marks) != len(owner.marks) {
		return errors.New("pre-delete ZIP must contain exactly both seeded manual marks")
	}
	got := make(map[uuid.UUID]string, len(marks))
	for _, mark := range marks {
		if mark.Scene == nil {
			return errors.New("pre-delete ZIP manual mark is missing its scene")
		}
		got[mark.Id] = *mark.Scene
	}
	for _, expected := range owner.marks {
		if scene, ok := got[expected.Id]; !ok || scene != owner.scene {
			return errors.New("pre-delete ZIP manual marks do not match the authenticated owner's fixtures")
		}
	}
	return nil
}

func t35VerifyExportOwnerEnvelope(parts map[string][]byte, owner, foreign t35ExportOwner) error {
	var accounts []struct {
		Kind   string
		UserID uuid.UUID `json:"user_id"`
	}
	if json.Unmarshal(parts["accounts.json"], &accounts) != nil || len(accounts) == 0 ||
		accounts[0].Kind != "account" || accounts[0].UserID != owner.account {
		return errors.New("delivered ZIP must contain the authenticated owner's persisted account")
	}
	if !t35MatchesAssessment(parts["assessments.json"], owner.assessment) {
		return errors.New("delivered assessments must contain exactly the owner's seeded assessment and content")
	}
	if !t35MatchesPlanOwnership(parts["growth.json"], owner) {
		return errors.New("delivered growth plans must reference the owner's assessment and include its seeded plan")
	}
	foreignIDs := []uuid.UUID{foreign.account, foreign.assessment.ID}
	for _, mark := range foreign.marks {
		foreignIDs = append(foreignIDs, mark.Id)
	}
	for _, body := range parts {
		for _, id := range foreignIDs {
			if bytes.Contains(body, []byte(id.String())) {
				return errors.New("delivered ZIP contains another account's fixture data")
			}
		}
	}
	return nil
}

func t35VerifySelectedMarkDeletion(before, after map[string][]byte, owner t35ExportOwner) error {
	if owner.deleteMark == uuid.Nil || len(owner.marks) != 2 {
		return errors.New("selected-mark deletion requires exactly two seeded owner marks")
	}
	if len(before) != len(after) || len(after) != len(t35ExportModules)+1 {
		return errors.New("before and after exports must retain the complete archive inventory")
	}
	for name, body := range before {
		changed, ok := after[name]
		if !ok {
			return errors.New("post-delete export omitted a partition")
		}
		if name != "manual_marks.json" && !bytes.Equal(body, changed) {
			return errors.New("selected-mark deletion changed an unrelated export partition")
		}
	}
	beforeMarks, err := t35DecodeExportMarks(before["manual_marks.json"])
	if err != nil || len(beforeMarks) != len(owner.marks) {
		return errors.New("pre-delete manual mark partition does not contain exactly the seeded marks")
	}
	afterMarks, err := t35DecodeExportMarks(after["manual_marks.json"])
	if err != nil || len(afterMarks) != 1 {
		return errors.New("post-delete manual mark partition must contain exactly the retained mark")
	}
	for _, mark := range owner.marks {
		if _, ok := beforeMarks[mark.Id.String()]; !ok {
			return errors.New("pre-delete manual mark partition is missing a seeded mark")
		}
	}
	retained, ok := afterMarks[owner.mark.String()]
	if !ok {
		return errors.New("post-delete manual mark partition omitted the retained mark")
	}
	if !reflect.DeepEqual(beforeMarks[owner.mark.String()], retained) {
		return errors.New("selected-mark deletion changed the retained mark")
	}
	if _, ok := afterMarks[owner.deleteMark.String()]; ok {
		return errors.New("post-delete manual mark partition still contains the selected mark")
	}
	for _, body := range after {
		if bytes.Contains(body, []byte(owner.deleteMark.String())) {
			return errors.New("post-delete export contains the selected mark identifier")
		}
	}
	return nil
}

func t35VerifyPartitionsIdentical(before, after map[string][]byte) error {
	if len(before) != len(after) {
		return errors.New("export partition count changed")
	}
	for name, body := range before {
		changed, ok := after[name]
		if !ok || !bytes.Equal(body, changed) {
			return errors.New("export partition changed for the unaffected account")
		}
	}
	return nil
}

func t35WriteSelectedMarkDiffReceipt(t *testing.T, before, after map[string][]byte, owner t35ExportOwner) {
	t.Helper()
	directory := t35ExportReceiptDir(t)
	if directory == "" {
		return
	}
	beforeMarks, err := t35DecodeExportMarks(before["manual_marks.json"])
	if err != nil {
		t.Fatal(err)
	}
	afterMarks, err := t35DecodeExportMarks(after["manual_marks.json"])
	if err != nil {
		t.Fatal(err)
	}
	changed := make([]string, 0, 1)
	for name, body := range before {
		if !bytes.Equal(body, after[name]) {
			changed = append(changed, name)
		}
	}
	slices.Sort(changed)
	retainedBefore := sha256.Sum256(beforeMarks[owner.mark.String()])
	retainedAfter := sha256.Sum256(afterMarks[owner.mark.String()])
	removed := sha256.Sum256(beforeMarks[owner.deleteMark.String()])
	t35WriteJSONReceipt(t, filepath.Join(directory, "diff.selected-mark.json"), map[string]any{
		"schema":                                "t35-formal-selected-mark-diff-v1",
		"changed_partitions":                    changed,
		"all_other_partitions_identical":        len(changed) == 1 && changed[0] == "manual_marks.json",
		"archive_entry_count_before":            len(before),
		"archive_entry_count_after":             len(after),
		"retained_mark_id":                      owner.mark,
		"removed_mark_id":                       owner.deleteMark,
		"retained_mark_sha256_before":           hex.EncodeToString(retainedBefore[:]),
		"retained_mark_sha256_after":            hex.EncodeToString(retainedAfter[:]),
		"removed_mark_sha256_before_deletion":   hex.EncodeToString(removed[:]),
		"removed_mark_absent_from_after_export": true,
	})
}

func t35DecodeExportMarks(body []byte) (map[string]json.RawMessage, error) {
	var rows []json.RawMessage
	if json.Unmarshal(body, &rows) != nil || rows == nil {
		return nil, errors.New("manual mark partition is not valid JSON")
	}
	marks := make(map[string]json.RawMessage, len(rows))
	for _, row := range rows {
		var identity struct {
			ID uuid.UUID `json:"id"`
		}
		if json.Unmarshal(row, &identity) != nil || identity.ID == uuid.Nil {
			return nil, errors.New("manual mark partition row has no valid identifier")
		}
		if _, duplicate := marks[identity.ID.String()]; duplicate {
			return nil, errors.New("manual mark partition contains a duplicate identifier")
		}
		marks[identity.ID.String()] = row
	}
	return marks, nil
}

func t35PartitionReceipt(parts map[string][]byte) []map[string]any {
	names := make([]string, 0, len(parts))
	for name := range parts {
		names = append(names, name)
	}
	slices.Sort(names)
	entries := make([]map[string]any, 0, len(names))
	for _, name := range names {
		digest := sha256.Sum256(parts[name])
		entries = append(entries, map[string]any{
			"name": name, "bytes": len(parts[name]), "sha256": hex.EncodeToString(digest[:]),
		})
	}
	return entries
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

func t35ExportReceiptDir(t *testing.T) string {
	t.Helper()
	value := os.Getenv("T35_EXPORT_RECEIPT_DIR")
	if value == "" {
		return ""
	}
	directory, err := filepath.Abs(value)
	if err != nil || os.MkdirAll(directory, 0o700) != nil {
		t.Fatal("could not prepare the private export receipt directory")
	}
	return directory
}

func t35CopyReceipt(t *testing.T, source, target string) {
	t.Helper()
	body, err := os.ReadFile(source)
	if err != nil || os.WriteFile(target, body, 0o600) != nil {
		t.Fatal("could not preserve an export receipt")
	}
}

func t35WriteJSONReceipt(t *testing.T, path string, value any) {
	t.Helper()
	body, err := json.MarshalIndent(value, "", "  ")
	if err != nil || os.WriteFile(path, append(body, '\n'), 0o600) != nil {
		t.Fatal("could not write an export receipt")
	}
}
