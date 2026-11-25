//go:build integration && t26flutter

package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9/logging"

	"high-eq/server/internal/accounts"
)

const t35RecordDeletePath = "/v1/me/data/sessions"

type t35RecordJourney struct {
	Schema          string            `json:"schema"`
	AccountA        uuid.UUID         `json:"account_a"`
	AccountB        uuid.UUID         `json:"account_b"`
	TargetSessionID uuid.UUID         `json:"target_session_id"`
	ABefore         map[string]string `json:"a_before"`
	AAfter          map[string]string `json:"a_after"`
	BBeforeList     []uuid.UUID       `json:"b_before_list"`
	BAfterList      []uuid.UUID       `json:"b_after_list"`
	Exports         []string          `json:"exports"`
}

type t35RecordRequestObservation struct {
	Account uuid.UUID `json:"account"`
	Method  string    `json:"method"`
	Path    string    `json:"path"`
	Query   string    `json:"query"`
	Status  int       `json:"status"`
}

type t35SelectedRecordObserver struct {
	router   http.Handler
	accounts *accounts.Service
	mu       sync.Mutex
	observed []t35RecordRequestObservation
}

func (o *t35SelectedRecordObserver) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	observe := r.Method == http.MethodGet && r.URL.Path == t35RecordDeletePath ||
		r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, t35RecordDeletePath+"/")
	if !observe {
		o.router.ServeHTTP(w, r)
		return
	}
	writer := &t35RecordStatusWriter{ResponseWriter: w, status: http.StatusOK}
	o.router.ServeHTTP(writer, r)
	token, bearer := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	principal, err := o.accounts.Parse(token)
	account := uuid.Nil
	if bearer && err == nil {
		account = principal.User
	}
	o.mu.Lock()
	o.observed = append(o.observed, t35RecordRequestObservation{
		Account: account, Method: r.Method, Path: r.URL.Path, Query: r.URL.RawQuery, Status: writer.status,
	})
	o.mu.Unlock()
}

func (o *t35SelectedRecordObserver) snapshot() []t35RecordRequestObservation {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]t35RecordRequestObservation(nil), o.observed...)
}

type t35RecordStatusWriter struct {
	http.ResponseWriter
	status int
}

func (w *t35RecordStatusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *t35RecordStatusWriter) Flush() { _ = http.NewResponseController(w.ResponseWriter).Flush() }

func (w *t35RecordStatusWriter) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func TestT35SelectedRecordDeleteJourney(t *testing.T) {
	if os.Getenv("T35_RECORD_DISPOSABLE") != "yes" {
		t.Skip("use app/tool/t35-privacy/record_delete_journey.py to start disposable services")
	}
	t.Log("BEGIN(service.runtime)")
	if os.Getenv("APP_ENV") != "development" || os.Getenv("PAYMENT_MODE") != "disabled" {
		t.Fatal("journey requires development providers and disabled payments")
	}
	pgURL := os.Getenv("DATABASE_URL")
	pg, db := t26LoopbackEndpoint(t, "DATABASE_URL", pgURL, "postgres", "postgresql")
	_, cache := t26LoopbackEndpoint(t, "REDIS_URL", os.Getenv("REDIS_URL"), "redis")
	_, ledger := t26LoopbackEndpoint(t, "LEDGER_URL", os.Getenv("LEDGER_URL"), "redis")
	if db == cache || db == ledger || cache == ledger || pg.User.Username() == "" ||
		pg.Path != "/postgres" || pg.RawQuery != "sslmode=disable&connect_timeout=5" {
		t.Fatal("expected three independent disposable endpoints")
	}
	scratch := t35RecordReceiptDir(t)
	t.Setenv("T35_EXPORT_RECEIPT_DIR", scratch)
	t.Setenv("PGSERVICEFILE", filepath.Join(scratch, "no-pgservice"))
	t.Setenv("PGSERVICE", "")
	t.Setenv("PGPASSWORD", "")
	t.Setenv("PGPASSFILE", filepath.Join(scratch, "no-pgpass"))
	t.Setenv("WLEIS_CONFIG_PATH", t26AssessmentFixturePath)
	// The runner selects only this test in its own process and drops raw logs.
	logging.Disable()
	slog.SetDefault(slog.New(slog.DiscardHandler))
	t26RequirePG17(t, pgURL)
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Minute)
	defer cancel()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal("could not load disposable runtime config")
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal("could not start production runtime with disposable stores")
	}
	t.Cleanup(s.Close)
	if s.Health(ctx) != nil {
		t.Fatal("production runtime health check failed")
	}
	router := s.Router()

	subjectA, subjectB := uuid.NewString(), uuid.NewString()
	ticketA, ticketB := uuid.NewString(), uuid.NewString()
	for ticket, subject := range map[string]string{ticketA: subjectA, ticketB: subjectB} {
		if s.cache.Set(ctx, "dev:ticket:apple:"+ticket, subject, 6*time.Minute).Err() != nil {
			t.Fatal("could not issue a synthetic one-use Apple ticket")
		}
	}

	exportObserver := &t35ExportObserver{router: router, accounts: s.Accounts}
	recordObserver := &t35SelectedRecordObserver{router: exportObserver, accounts: s.Accounts}
	api := httptest.NewUnstartedServer(recordObserver)
	api.Config.ErrorLog = log.New(io.Discard, "", 0)
	api.Start()
	t.Cleanup(api.Close)
	t.Log("PASS(service.runtime)")

	t.Log("BEGIN(page.startup)")
	t35RunSelectedRecordFlutter(t, ctx, api.URL, scratch, ticketA, ticketB)

	t.Log("BEGIN(receive.wire-and-delete)")
	exports := exportObserver.snapshot()
	requests := recordObserver.snapshot()
	journey := t35ReadSelectedRecordJourney(t, scratch)
	if err := t35VerifyRecordWire(requests, exports, journey); err != nil {
		t.Fatal(err)
	}
	aBefore := t35ReadDeliveredZIP(t, scratch, "a-before", journey.AccountA, exports[1])
	aAfter := t35ReadDeliveredZIP(t, scratch, "a-after", journey.AccountA, exports[2])
	bBefore := t35ReadDeliveredZIP(t, scratch, "b-before", journey.AccountB, exports[0])
	bAfter := t35ReadDeliveredZIP(t, scratch, "b-after", journey.AccountB, exports[3])
	t35WriteRecordJSONReceipt(t, filepath.Join(scratch, "wire", "journey.json"), map[string]any{
		"schema":   "t35-selected-record-wire-journey-v1",
		"requests": requests,
		"exports": []map[string]any{
			{"label": "b-before", "account": exports[0].account, "valid": exports[0].valid,
				"bytes": exports[0].size, "sha256": hex.EncodeToString(exports[0].digest[:])},
			{"label": "a-before", "account": exports[1].account, "valid": exports[1].valid,
				"bytes": exports[1].size, "sha256": hex.EncodeToString(exports[1].digest[:])},
			{"label": "a-after", "account": exports[2].account, "valid": exports[2].valid,
				"bytes": exports[2].size, "sha256": hex.EncodeToString(exports[2].digest[:])},
			{"label": "b-after", "account": exports[3].account, "valid": exports[3].valid,
				"bytes": exports[3].size, "sha256": hex.EncodeToString(exports[3].digest[:])},
		},
		"delete": t35RecordDeleteReceipt(t, requests, journey),
	})
	t.Log("PASS(receive.wire-and-delete)")

	t.Log("BEGIN(receive.selected-session-diff)")
	if err := t35VerifySelectedSessionDiff(t, journey, aBefore, aAfter); err != nil {
		t.Fatal(err)
	}
	t.Log("PASS(receive.selected-session-diff)")

	t.Log("BEGIN(receive.account-isolation)")
	if err := t35VerifyPartitionsIdentical(bBefore, bAfter); err != nil {
		t.Fatal(err)
	}
	bRows := t35DecodeRecordTraining(t, bBefore["training.json"], nil)
	if !slices.Equal(t35RecordTrainingIDs(bRows), t35SortedUUIDs(journey.BBeforeList)) ||
		!slices.Equal(t35RecordTrainingIDs(bRows), t35SortedUUIDs(journey.BAfterList)) {
		t.Fatal("account B list or export changed after account A selected deletion")
	}
	t.Log("PASS(receive.account-isolation)")

	t.Log("BEGIN(receive.ownership)")
	ownership := t35VerifyRecordExportOwnership(t, journey, subjectA, subjectB,
		aBefore, aAfter, bBefore, bAfter)
	t35WriteRecordJSONReceipt(t, filepath.Join(scratch, "ownership.json"), ownership)
	t.Log("PASS(receive.ownership)")
}

func t35RecordReceiptDir(t *testing.T) string {
	t.Helper()
	value := os.Getenv("T35_RECORD_EXPORT_RECEIPT_DIR")
	if value == "" {
		t.Fatal("T35_RECORD_EXPORT_RECEIPT_DIR is required")
	}
	directory, err := filepath.Abs(value)
	if err != nil || os.MkdirAll(directory, 0o700) != nil {
		t.Fatal("could not prepare the private selected-record receipt directory")
	}
	return directory
}

func t35RunSelectedRecordFlutter(t *testing.T, ctx context.Context, origin, scratch, ticketA, ticketB string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(ctx, 4*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Getenv("T27_HISTORY_DART"), os.Getenv("T27_HISTORY_FLUTTER_SNAPSHOT"),
		"--no-version-check", "test", "--no-pub", "--reporter", "json", "tool/t35/ui_selected_record_test.dart")
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
		"T35_ORIGIN="+origin,
		"T35_RECORD_DEV_TICKET_A="+ticketA,
		"T35_RECORD_DEV_TICKET_B="+ticketB,
		"T35_RECORD_EXPORT_RECEIPT_DIR="+scratch,
	)
	stdout, err := os.Create(filepath.Join(scratch, "flutter.jsonl"))
	if err != nil {
		t.Fatal("could not open private Flutter receipt stream")
	}
	stderr, err := os.Create(filepath.Join(scratch, "flutter.stderr.log"))
	if err != nil {
		stdout.Close()
		t.Fatal("could not open Flutter stderr receipt")
	}
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	runErr := cmd.Run()
	stdoutCloseErr := stdout.Close()
	stderrCloseErr := stderr.Close()
	if stdoutCloseErr != nil || stderrCloseErr != nil {
		t.Fatal("could not close private Flutter receipt streams")
	}
	receipt, err := os.Open(filepath.Join(scratch, "flutter.jsonl"))
	if err != nil {
		t.Fatal("could not reopen private Flutter receipt stream")
	}
	defer receipt.Close()
	confirmed := t35RequireSelectedRecordFlutterReceipt(t, receipt)
	if runErr != nil || !confirmed {
		stderrBytes, _ := os.ReadFile(filepath.Join(scratch, "flutter.stderr.log"))
		t.Fatalf("Flutter did not complete the exact selected-record journey (%v): %s", runErr, stderrBytes)
	}
}

func t35RequireSelectedRecordFlutterReceipt(t *testing.T, stream io.Reader) bool {
	t.Helper()
	const name = "PrivacyPage selects a second-page session, confirms, refreshes and re-exports (variant: TargetPlatform.iOS)"
	required := []string{
		"BEGIN(page.account-b.before)", "PASS(page.account-b.before)",
		"BEGIN(page.account-a.before)", "PASS(page.account-a.before)",
		"BEGIN(page.account-a.delete)", "PASS(page.account-a.delete)",
		"BEGIN(page.account-a.after)", "PASS(page.account-a.after)",
		"BEGIN(page.account-b.after)", "PASS(page.account-b.after)",
	}
	decoder := json.NewDecoder(stream)
	testID, phase := -1, 0
	testDone, runDone := false, false
	for {
		var event struct {
			Type, Result, Message string
			TestID                int
			Test                  struct {
				ID   int
				Name string
			}
			Hidden, Skipped, Success bool
		}
		if err := decoder.Decode(&event); err != nil {
			return err == io.EOF && phase == len(required) && testDone && runDone
		}
		if runDone {
			return false
		}
		switch {
		case event.Type == "testStart" && event.Test.Name == name:
			if testID != -1 {
				return false
			}
			testID = event.Test.ID
		case event.Type == "print" && testID != -1 && event.TestID == testID && slices.Contains(required, event.Message):
			if testDone || phase == len(required) || event.Message != required[phase] {
				return false
			}
			t.Log(required[phase])
			phase++
		case event.Type == "testDone" && testID != -1 && event.TestID == testID:
			if testDone || event.Hidden || event.Skipped || event.Result != "success" {
				return false
			}
			testDone = true
		case event.Type == "done":
			if !event.Success {
				return false
			}
			runDone = true
		}
	}
}

func t35ReadSelectedRecordJourney(t *testing.T, directory string) t35RecordJourney {
	t.Helper()
	body, err := os.ReadFile(filepath.Join(directory, "journey.json"))
	if err != nil {
		t.Fatal("selected-record journey receipt is missing")
	}
	var journey t35RecordJourney
	if json.Unmarshal(body, &journey) != nil || journey.Schema != "t35-selected-record-journey-v1" ||
		journey.AccountA == uuid.Nil || journey.AccountB == uuid.Nil || journey.AccountA == journey.AccountB ||
		journey.TargetSessionID == uuid.Nil || len(journey.ABefore) != 21 || len(journey.AAfter) != 20 ||
		len(journey.BBeforeList) != 1 || !slices.Equal(journey.BBeforeList, journey.BAfterList) ||
		!slices.Equal(journey.Exports, []string{
			"accepted-b-before.zip", "accepted-a-before.zip", "accepted-a-after.zip", "accepted-b-after.zip",
		}) {
		t.Fatal("selected-record journey receipt does not describe the exact A/B scenario")
	}
	if _, present := journey.ABefore[journey.TargetSessionID.String()]; !present {
		t.Fatal("selected target is absent from the pre-delete account A inventory")
	}
	if _, present := journey.AAfter[journey.TargetSessionID.String()]; present {
		t.Fatal("selected target remains in the post-delete account A inventory")
	}
	for id := range journey.ABefore {
		if id != journey.TargetSessionID.String() {
			if _, present := journey.AAfter[id]; !present {
				t.Fatal("selected deletion removed a non-target account A session")
			}
		}
	}
	return journey
}

func t35VerifyRecordWire(requests []t35RecordRequestObservation, exports []t35ExportObservation, journey t35RecordJourney) error {
	if len(exports) != 4 {
		return errors.New("expected exactly four real account exports")
	}
	expectedOwners := []uuid.UUID{journey.AccountB, journey.AccountA, journey.AccountA, journey.AccountB}
	for i, observation := range exports {
		if !observation.valid || observation.account != expectedOwners[i] || observation.size <= 0 {
			return errors.New("export wire receipt does not match the authenticated A/B order")
		}
	}

	var lists, deletes []t35RecordRequestObservation
	for _, observation := range requests {
		switch observation.Method {
		case http.MethodGet:
			lists = append(lists, observation)
		case http.MethodDelete:
			deletes = append(deletes, observation)
		}
	}
	if len(lists) != 5 || len(deletes) != 1 {
		return errors.New("expected five session list requests and one selected deletion")
	}
	expectedAccounts := []uuid.UUID{journey.AccountB, journey.AccountA, journey.AccountA, journey.AccountA, journey.AccountB}
	for i, observation := range lists {
		query, err := url.ParseQuery(observation.Query)
		if err != nil || observation.Account != expectedAccounts[i] || observation.Path != t35RecordDeletePath ||
			observation.Status != http.StatusOK {
			return fmt.Errorf("session list wire receipt does not match the A/B pagination sequence: %+v", lists)
		}
		switch i {
		case 0, 4:
			if len(query) != 0 {
				return errors.New("account B direct session lists must not carry query parameters")
			}
		case 1, 3:
			if len(query) != 1 || query.Get("limit") != "20" {
				return errors.New("account A first and post-delete pages must request exactly twenty sessions")
			}
		case 2:
			if len(query) != 2 || query.Get("limit") != "20" || query.Get("cursor") == "" {
				return errors.New("the second account A page must request twenty sessions with exactly one cursor")
			}
		}
	}
	deletion := deletes[0]
	if deletion.Account != journey.AccountA || deletion.Path != t35RecordDeletePath+"/"+journey.TargetSessionID.String() ||
		deletion.Query != "" || deletion.Status != http.StatusOK {
		return errors.New("selected deletion wire receipt does not target exactly account A's chosen session")
	}
	return nil
}

func t35RecordDeleteReceipt(t *testing.T, requests []t35RecordRequestObservation, journey t35RecordJourney) map[string]any {
	t.Helper()
	for _, observation := range requests {
		if observation.Method == http.MethodDelete {
			return map[string]any{
				"schema": "t35-selected-record-delete-wire-v1", "account": observation.Account,
				"method": observation.Method, "path": observation.Path, "query": observation.Query,
				"status": observation.Status, "target_session_id": journey.TargetSessionID,
				"exactly_one": true,
			}
		}
	}
	t.Fatal("selected deletion wire receipt is missing")
	return nil
}

func t35DecodeRecordTraining(t *testing.T, body []byte, expected map[string]string) map[uuid.UUID]json.RawMessage {
	t.Helper()
	var rows []json.RawMessage
	if json.Unmarshal(body, &rows) != nil || rows == nil {
		t.Fatal("training partition is not a JSON array")
	}
	training := make(map[uuid.UUID]json.RawMessage, len(rows))
	for _, raw := range rows {
		var row struct {
			SessionID uuid.UUID `json:"session_id"`
			Setup     struct {
				Scenario *string `json:"scenario"`
			} `json:"setup"`
		}
		if json.Unmarshal(raw, &row) != nil || row.SessionID == uuid.Nil {
			t.Fatal("training partition row has no session identifier")
		}
		if _, duplicate := training[row.SessionID]; duplicate {
			t.Fatal("training partition contains a duplicate session identifier")
		}
		if expected != nil {
			scenario, present := expected[row.SessionID.String()]
			if !present || row.Setup.Scenario == nil || *row.Setup.Scenario != scenario {
				t.Fatal("training partition does not match the journey's owned session scenario")
			}
		}
		training[row.SessionID] = append(json.RawMessage(nil), raw...)
	}
	return training
}

func t35RecordTrainingIDs(rows map[uuid.UUID]json.RawMessage) []uuid.UUID {
	ids := make([]uuid.UUID, 0, len(rows))
	for id := range rows {
		ids = append(ids, id)
	}
	slices.SortFunc(ids, func(a, b uuid.UUID) int { return bytes.Compare(a[:], b[:]) })
	return ids
}

func t35SortedUUIDs(ids []uuid.UUID) []uuid.UUID {
	sorted := append([]uuid.UUID(nil), ids...)
	slices.SortFunc(sorted, func(a, b uuid.UUID) int { return bytes.Compare(a[:], b[:]) })
	return sorted
}

func t35VerifySelectedSessionDiff(t *testing.T, journey t35RecordJourney, before, after map[string][]byte) error {
	t.Helper()
	if len(before) != len(after) || len(after) != len(t35ExportModules)+1 {
		return errors.New("before and after exports must retain the complete archive inventory")
	}
	changed := make([]string, 0, 1)
	for name, body := range before {
		other, present := after[name]
		if !present {
			return errors.New("post-delete export omitted a partition")
		}
		if !bytes.Equal(body, other) {
			changed = append(changed, name)
		}
	}
	slices.Sort(changed)
	if !slices.Equal(changed, []string{"training.json"}) {
		return errors.New("selected session deletion changed a partition other than training.json")
	}
	beforeRows := t35DecodeRecordTraining(t, before["training.json"], journey.ABefore)
	afterRows := t35DecodeRecordTraining(t, after["training.json"], journey.AAfter)
	if len(beforeRows) != len(journey.ABefore) || len(afterRows) != len(journey.AAfter) {
		return errors.New("training partition count does not match the journey inventory")
	}
	target := journey.TargetSessionID
	targetBefore, present := beforeRows[target]
	if !present {
		return errors.New("pre-delete training partition omitted the selected session")
	}
	if _, present := afterRows[target]; present {
		return errors.New("post-delete training partition still contains the selected session")
	}
	for id, beforeRow := range beforeRows {
		if id == target {
			continue
		}
		afterRow, present := afterRows[id]
		if !present || !bytes.Equal(beforeRow, afterRow) {
			return errors.New("selected session deletion changed or removed a retained training row")
		}
	}
	for _, body := range after {
		if bytes.Contains(body, []byte(target.String())) {
			return errors.New("post-delete export still contains the selected session identifier")
		}
	}
	targetDigest := sha256.Sum256(targetBefore)
	t35WriteRecordJSONReceipt(t, filepath.Join(t35RecordReceiptDir(t), "diff.selected-session.json"), map[string]any{
		"schema":                                   "t35-selected-session-diff-v1",
		"changed_partitions":                       changed,
		"all_other_partitions_identical":           true,
		"archive_entry_count_before":               len(before),
		"archive_entry_count_after":                len(after),
		"training_rows_before":                     len(beforeRows),
		"training_rows_after":                      len(afterRows),
		"removed_session_id":                       target,
		"removed_session_sha256_before_deletion":   hex.EncodeToString(targetDigest[:]),
		"retained_training_rows_identical":         true,
		"removed_session_absent_from_after_export": true,
	})
	return nil
}

func t35VerifyRecordExportOwnership(t *testing.T, journey t35RecordJourney, subjectA, subjectB string,
	aBefore, aAfter, bBefore, bAfter map[string][]byte) map[string]any {
	t.Helper()
	aBeforeIDs := make(map[string]string, len(journey.ABefore))
	for id, scenario := range journey.ABefore {
		aBeforeIDs[id] = scenario
	}
	aAfterIDs := make(map[string]string, len(journey.AAfter))
	for id, scenario := range journey.AAfter {
		aAfterIDs[id] = scenario
	}
	bBeforeIDs := map[string]string{journey.BBeforeList[0].String(): "T35 合成对练 B-1"}
	aForeignSessions := t35SortedUUIDs(append(t35JourneyMapIDs(journey.ABefore), journey.TargetSessionID))
	bForeignSessions := t35JourneyMapIDs(journey.ABefore)
	if err := t35VerifyRecordArchiveOwner(t, aBefore, journey.AccountA, subjectA, journey.AccountB, subjectB, aBeforeIDs, journey.BBeforeList); err != nil {
		t.Fatal("account A pre-delete export ownership: ", err)
	}
	if err := t35VerifyRecordArchiveOwner(t, aAfter, journey.AccountA, subjectA, journey.AccountB, subjectB, aAfterIDs, journey.BBeforeList); err != nil {
		t.Fatal("account A post-delete export ownership: ", err)
	}
	if err := t35VerifyRecordArchiveOwner(t, bBefore, journey.AccountB, subjectB, journey.AccountA, subjectA, bBeforeIDs, aForeignSessions); err != nil {
		t.Fatal("account B pre-delete export ownership: ", err)
	}
	if err := t35VerifyRecordArchiveOwner(t, bAfter, journey.AccountB, subjectB, journey.AccountA, subjectA, bBeforeIDs, bForeignSessions); err != nil {
		t.Fatal("account B post-delete export ownership: ", err)
	}
	aAfterRows := t35DecodeRecordTraining(t, aAfter["training.json"], journey.AAfter)
	bAfterRows := t35DecodeRecordTraining(t, bAfter["training.json"], nil)
	if len(aAfterRows) != 20 || len(bAfterRows) != 1 ||
		!slices.Equal(t35RecordTrainingIDs(bAfterRows), t35SortedUUIDs(journey.BAfterList)) {
		t.Fatal("owned exports do not contain the exact post-delete training inventories")
	}
	return map[string]any{
		"schema": "t35-selected-record-export-ownership-v1",
		"account_a": map[string]any{
			"user_id": journey.AccountA, "identity_subject": subjectA,
			"sessions_before": len(journey.ABefore), "sessions_after": len(journey.AAfter),
			"only_target_removed": true, "foreign_identity_absent": true,
		},
		"account_b": map[string]any{
			"user_id": journey.AccountB, "identity_subject": subjectB,
			"sessions_before": len(journey.BBeforeList), "sessions_after": len(journey.BAfterList),
			"unchanged": true, "foreign_identity_absent": true,
		},
		"archive_entries_per_export":            len(t35ExportModules) + 1,
		"manifest_and_13_partitions":            true,
		"cross_account_ids_and_sessions_absent": true,
		"wire_export_count":                     4,
		"validated":                             true,
	}
}

func t35JourneyMapIDs(values map[string]string) []uuid.UUID {
	ids := make([]uuid.UUID, 0, len(values))
	for value := range values {
		if id, err := uuid.Parse(value); err == nil {
			ids = append(ids, id)
		}
	}
	return t35SortedUUIDs(ids)
}

func t35VerifyRecordArchiveOwner(t *testing.T, parts map[string][]byte, owner uuid.UUID, subject string,
	foreign uuid.UUID, foreignSubject string, expectedSessions map[string]string, foreignSessions []uuid.UUID) error {
	t.Helper()
	var rows []struct {
		Kind     string    `json:"kind"`
		UserID   uuid.UUID `json:"user_id"`
		Provider string    `json:"provider"`
		Subject  string    `json:"subject"`
	}
	if json.Unmarshal(parts["accounts.json"], &rows) != nil {
		return errors.New("accounts partition is invalid")
	}
	accountsFound, identitiesFound := 0, 0
	for _, row := range rows {
		switch row.Kind {
		case "account":
			accountsFound++
			if row.UserID != owner {
				return errors.New("accounts partition contains a foreign account")
			}
		case "identity":
			identitiesFound++
			if row.Provider != "apple" || row.Subject != subject {
				return errors.New("accounts partition contains a foreign or unexpected identity")
			}
		}
	}
	if accountsFound != 1 || identitiesFound != 1 {
		return errors.New("accounts partition must contain exactly the owner's account and Apple identity")
	}

	training := t35DecodeRecordTraining(t, parts["training.json"], expectedSessions)
	if len(training) != len(expectedSessions) {
		return errors.New("training partition does not contain exactly the owner's sessions")
	}
	for sessionID := range training {
		if slices.Contains(foreignSessions, sessionID) {
			return errors.New("training partition contains a foreign session")
		}
	}
	for _, body := range parts {
		if bytes.Contains(body, []byte(foreign.String())) || bytes.Contains(body, []byte(foreignSubject)) {
			return errors.New("export partition contains another account's identity")
		}
		for _, sessionID := range foreignSessions {
			if bytes.Contains(body, []byte(sessionID.String())) {
				return errors.New("export partition contains another account's session")
			}
		}
	}
	return nil
}

func t35WriteRecordJSONReceipt(t *testing.T, path string, value any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal("could not prepare a selected-record receipt directory")
	}
	body, err := json.MarshalIndent(value, "", "  ")
	if err != nil || os.WriteFile(path, append(body, '\n'), 0o600) != nil {
		t.Fatal("could not write a selected-record JSON receipt")
	}
}
