//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http/httptest"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
)

// TestPrivacyRightsHTTP exercises the generated account routes through the real
// runtime composition. It uses only synthetic identities and temporary service
// dependencies supplied by the integration test environment.
func TestPrivacyRightsHTTP(t *testing.T) {
	ctx := context.Background()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	router := s.Router()

	request := func(t *testing.T, method, path, bearer string, body any) *httptest.ResponseRecorder {
		t.Helper()
		var raw []byte
		if body != nil {
			var err error
			raw, err = json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
		}
		r := httptest.NewRequest(method, path, bytes.NewReader(raw))
		r.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			r.Header.Set("Authorization", "Bearer "+bearer)
		}
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w
	}
	expect := func(method, path, bearer string, body any, status int) *httptest.ResponseRecorder {
		t.Helper()
		w := request(t, method, path, bearer, body)
		if w.Code != status {
			t.Fatalf("%s %s: got %d, want %d: %s", method, path, w.Code, status, w.Body.String())
		}
		return w
	}
	assertNoArchive := func(w *httptest.ResponseRecorder) {
		t.Helper()
		if w.Header().Get("Content-Type") != "application/json; charset=utf-8" || w.Header().Get("Content-Disposition") != "" {
			t.Fatal("rejected export did not return JSON headers")
		}
		body := w.Body.Bytes()
		if bytes.HasPrefix(body, []byte("PK\x03\x04")) || bytes.Contains(body, []byte("manifest.json")) {
			t.Fatalf("unauthorized response exposed archive data: %q", body)
		}
		if _, err := zip.NewReader(bytes.NewReader(body), int64(len(body))); err == nil {
			t.Fatal("unauthorized response exposed a readable ZIP")
		}
	}
	proof := func(provider, subject string) map[string]any {
		t.Helper()
		ticket := uuid.NewString()
		if err := s.cache.Set(ctx, "dev:ticket:"+provider+":"+ticket, subject, time.Minute).Err(); err != nil {
			t.Fatal(err)
		}
		return map[string]any{"provider": provider, "proof": ticket}
	}
	login := func(credential map[string]any, register bool, status int) app.Tokens {
		t.Helper()
		body := map[string]any{"credential": credential}
		if register {
			body["age_confirmed"] = true
			body["privacy_version"] = "2026-11"
			body["terms_version"] = "2026-11"
		}
		w := expect("POST", "/v1/auth/login", "", body, status)
		if status != 200 {
			return app.Tokens{}
		}
		var out app.Tokens
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}

	unauthorized := expect("GET", "/v1/me/export", "", nil, 401)
	assertNoArchive(unauthorized)
	var unauthorizedBody struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(unauthorized.Body.Bytes(), &unauthorizedBody); err != nil || unauthorizedBody.Code != "unauthenticated" {
		t.Fatalf("unauthorized export was not a JSON error: %s", unauthorized.Body.String())
	}

	appleSubject, wechatSubject := uuid.NewString(), uuid.NewString()
	a := login(proof("apple", appleSubject), true, 200)
	b := login(proof("wechat", wechatSubject), true, 200)
	if a.UserId == b.UserId {
		t.Fatal("synthetic identities merged")
	}

	// The generated gate checks the session before dispatch, but the business
	// handler must independently reject a session revoked after that route gate.
	revoked := a
	expect("POST", "/v1/auth/logout", revoked.AccessToken, map[string]any{
		"refresh_token": revoked.RefreshToken,
	}, 200)
	principal, err := s.Accounts.Parse(revoked.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	business := appAPI{accounts: s.Accounts, data: s.Data}
	invokeWithoutGate := func(method, path string, handler func(*gin.Context)) *httptest.ResponseRecorder {
		t.Helper()
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest(method, path, nil)
		c.Set("principal", principal)
		handler(c)
		return w
	}
	if w := invokeWithoutGate("GET", "/v1/me/export", business.ExportData); w.Code != 401 {
		t.Fatalf("revoked export handler: got %d, want 401: %s", w.Code, w.Body.String())
	} else {
		assertNoArchive(w)
	}
	a = login(proof("apple", appleSubject), false, 200)
	const ownerTimezone = "Pacific/Auckland"
	expect("PATCH", "/v1/me", a.AccessToken, app.UpdateMeInput{Timezone: ownerTimezone}, 200)

	// Exercise the real T32A contact and manual-mark endpoints so the privacy
	// export is checked against encrypted source rows, not a synthetic module.
	expect("PUT", "/v1/me/consents/contacts", a.AccessToken, map[string]any{"version": "v1", "granted": true}, 200)
	w := expect("POST", "/v1/contacts", a.AccessToken, map[string]any{
		"nickname": "T35 合成对象",
		"scene":    "partner",
	}, 200)
	var contact app.Contact
	if err := json.Unmarshal(w.Body.Bytes(), &contact); err != nil {
		t.Fatal(err)
	}
	expect("PUT", "/v1/me/consents/manual_mark", a.AccessToken, map[string]any{"version": "v1", "granted": true}, 200)
	markRequest := uuid.MustParse("35000000-0000-4000-8000-000000000001")
	markScene := "partner"
	siblingRequest := uuid.New()
	owner, err := s.Accounts.Parse(a.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	var mark app.Mark
	// Space the two marks using the service's clock input so the HTTP create
	// does not coalesce them into one mark within the one-minute interval.
	if err := s.Accounts.WithSession(ctx, owner, false, func(tx pgx.Tx) error {
		var err error
		mark, err = s.Marks.Create(ctx, tx, a.UserId, app.CreateMarkInput{
			RequestId: markRequest, ContactId: &contact.Id, Scene: &markScene,
		}, time.Now().Add(-2*time.Minute))
		return err
	}); err != nil {
		t.Fatal(err)
	}
	w = expect("POST", "/v1/marks", a.AccessToken, map[string]any{
		"request_id": siblingRequest,
		"contact_id": contact.Id,
		"scene":      markScene,
	}, 200)
	var sibling app.Mark
	if err := json.Unmarshal(w.Body.Bytes(), &sibling); err != nil {
		t.Fatal(err)
	}
	for _, m := range []app.Mark{mark, sibling} {
		if m.ContactId == nil || *m.ContactId != contact.Id || m.Scene == nil || *m.Scene != markScene {
			t.Fatalf("manual mark did not preserve object and scene: %+v", m)
		}
	}
	expect("PUT", "/v1/me/consents/manual_mark", b.AccessToken, map[string]any{"version": "v1", "granted": true}, 200)
	foreignMarkRequest := uuid.New()
	w = expect("POST", "/v1/marks", b.AccessToken, map[string]any{"request_id": foreignMarkRequest}, 200)
	var foreignMark app.Mark
	t35Decode(t, w.Body.Bytes(), &foreignMark)
	if mark.Id == uuid.Nil || sibling.Id == uuid.Nil || foreignMark.Id == uuid.Nil ||
		mark.Id == sibling.Id || mark.Id == foreignMark.Id || sibling.Id == foreignMark.Id {
		t.Fatal("expected three distinct public mark IDs")
	}

	export := func(t *testing.T, token string) map[string][]byte {
		t.Helper()
		w := request(t, "GET", "/v1/me/export", token, nil)
		if w.Code != 200 {
			t.Fatalf("GET /v1/me/export: got %d, want 200: %s", w.Code, w.Body)
		}
		if got := w.Header().Get("Content-Type"); got != "application/zip" {
			t.Fatalf("export content type = %q", got)
		}
		if got := w.Header().Get("Content-Disposition"); got != `attachment; filename="high-eq-export.zip"` {
			t.Fatalf("export attachment = %q", got)
		}
		z, err := zip.NewReader(bytes.NewReader(w.Body.Bytes()), int64(w.Body.Len()))
		if err != nil {
			t.Fatal(err)
		}
		if len(z.File) == 0 || z.File[0].Name != "manifest.json" {
			t.Fatalf("manifest is not first: %+v", z.File)
		}
		files := make(map[string][]byte, len(z.File))
		for _, f := range z.File {
			rc, err := f.Open()
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				t.Fatal(err)
			}
			if _, duplicate := files[f.Name]; duplicate {
				t.Fatalf("duplicate ZIP entry: %s", f.Name)
			}
			files[f.Name] = body
		}
		var inventory struct {
			Files []string `json:"files"`
		}
		if err := json.Unmarshal(files["manifest.json"], &inventory); err != nil {
			t.Fatal(err)
		}
		var names []string
		for _, f := range z.File {
			names = append(names, f.Name)
		}
		if !slices.Equal(names, inventory.Files) {
			t.Fatalf("ZIP entries = %v; manifest = %v", names, inventory.Files)
		}
		return files
	}
	manualMarks := func(t *testing.T, files map[string][]byte) []app.Mark {
		t.Helper()
		var marks []app.Mark
		if err := json.Unmarshal(files["manual_marks.json"], &marks); err != nil {
			t.Fatal(err)
		}
		return marks
	}

	files := export(t, a.AccessToken)
	var manifest struct {
		Modules []string `json:"modules"`
		Files   []string `json:"files"`
	}
	if err := json.Unmarshal(files["manifest.json"], &manifest); err != nil {
		t.Fatal(err)
	}
	// Coverage is a set requirement; the manifest must describe the real ZIP order.
	wantModules := []string{
		"accounts", "ai_calls", "assessments", "chat_imports", "emotion", "growth",
		"manual_marks", "membership", "payments", "profiles", "replies", "reviews", "training",
	}
	gotModules := slices.Clone(manifest.Modules)
	slices.Sort(gotModules)
	if !slices.Equal(gotModules, wantModules) {
		t.Fatalf("registered modules = %v, want %v", gotModules, wantModules)
	}
	wantFiles := []string{"manifest.json"}
	for _, name := range manifest.Modules {
		wantFiles = append(wantFiles, name+".json")
	}
	if !reflect.DeepEqual(manifest.Files, wantFiles) {
		t.Fatalf("manifest files = %v, want %v", manifest.Files, wantFiles)
	}
	var exported bytes.Buffer
	for name, body := range files {
		exported.WriteString(name)
		exported.Write(body)
	}
	payload := exported.Bytes()
	var accountRows []struct {
		Kind      string     `json:"kind"`
		User      uuid.UUID  `json:"user_id"`
		Timezone  string     `json:"timezone"`
		Created   time.Time  `json:"created_at"`
		Age       time.Time  `json:"age_confirmed_at"`
		Closure   *time.Time `json:"closure_requested_at"`
		Purchase  uuid.UUID  `json:"app_account_token"`
		Provider  string     `json:"provider"`
		Subject   string     `json:"subject"`
		Purpose   string     `json:"purpose"`
		Version   string     `json:"version"`
		Granted   time.Time  `json:"granted_at"`
		Withdrawn *time.Time `json:"withdrawn_at"`
	}
	t35Decode(t, files["accounts.json"], &accountRows)
	var purchase uuid.UUID
	if err := s.db.QueryRow(ctx, "select app_account_token from users where id=$1", a.UserId).Scan(&purchase); err != nil {
		t.Fatal(err)
	}
	var account, identity, consent bool
	for _, row := range accountRows {
		switch row.Kind {
		case "account":
			account = row.User == a.UserId && row.Timezone == ownerTimezone && row.Purchase == purchase &&
				!row.Created.IsZero() && !row.Age.IsZero() && row.Closure == nil
		case "identity":
			identity = row.Provider == "apple" && row.Subject == appleSubject
		case "consent":
			consent = consent || row.Purpose == "manual_mark" && row.Version == "v1" &&
				!row.Granted.IsZero() && row.Withdrawn == nil
		}
	}
	if !account || !identity || !consent || !bytes.Contains(files["accounts.json"], []byte(`"closure_requested_at":null`)) {
		t.Fatalf("accounts.json missing account, login identity or grant: %t/%t/%t", account, identity, consent)
	}
	for _, want := range []string{a.UserId.String(), appleSubject, `"kind":"account"`, `"kind":"consent"`, `"purpose":"privacy"`} {
		if !bytes.Contains(payload, []byte(want)) {
			t.Fatalf("A export missing %q", want)
		}
	}
	for _, secret := range []string{b.UserId.String(), wechatSubject, a.AccessToken, a.RefreshToken, "refresh_hash", `"subject_hmac":`, `"subject_enc":`} {
		if bytes.Contains(payload, []byte(secret)) {
			t.Fatalf("A export leaked %q", secret)
		}
	}
	marks := manualMarks(t, files)
	if len(marks) != 2 || marks[0].Id != sibling.Id ||
		marks[1].Id != mark.Id || !marks[1].MarkedAt.Equal(mark.MarkedAt) ||
		marks[1].ContactId == nil || *marks[1].ContactId != contact.Id ||
		marks[1].Scene == nil || *marks[1].Scene != markScene {
		t.Fatalf("manual mark export = %+v, want time/object/scene from %+v", marks, mark)
	}
	t35Exclude(t, files["manual_marks.json"], foreignMark.Id.String(), markRequest.String(),
		siblingRequest.String(), foreignMarkRequest.String(), `"request_id":`, `"input_mac":`)
	if other := manualMarks(t, export(t, b.AccessToken)); len(other) != 1 || other[0].Id != foreignMark.Id {
		t.Fatal("the other account did not get exactly its own mark")
	}

	if !t.Run("selected_record_delete_removes_only_the_listed_owned_mark", func(t *testing.T) {
		const listPath = "/v1/me/data/manual_marks"
		call := func(method, path, token string, status int) []byte {
			t.Helper()
			w := request(t, method, path, token, nil)
			if w.Code != status {
				t.Fatalf("%s %s: got %d, want %d: %s", method, path, w.Code, status, w.Body)
			}
			return w.Body.Bytes()
		}
		assertMarks := func(token string, want ...app.Mark) []wireRecordLocator {
			t.Helper()
			body := call("GET", listPath, token, 200)
			var page wireRecordLocatorPage
			decoder := json.NewDecoder(bytes.NewReader(body))
			decoder.DisallowUnknownFields()
			if err := decoder.Decode(&page); err != nil {
				t.Fatalf("decode mark locators: %v: %s", err, body)
			}
			t35Exclude(t, body, contact.Id.String(), markScene, markRequest.String(),
				siblingRequest.String(), foreignMarkRequest.String(), `"channel":`)
			archive := export(t, token)
			got := manualMarks(t, archive)
			if page.NextCursor != nil || len(page.Items) != len(want) || len(got) != len(want) {
				t.Fatalf("got %d locators and %d exported marks, want %d of each (cursor %v)", len(page.Items), len(got), len(want), page.NextCursor)
			}
			for i, expected := range want {
				item, exported := page.Items[i], got[i]
				if item.Kind != "manual_marks" || item.Id == nil || *item.Id != expected.Id ||
					item.Label != "手动标记" || item.RecordedAt == nil || !item.RecordedAt.Equal(expected.MarkedAt) {
					t.Fatalf("locator %d does not match mark %s: %+v", i, expected.Id, item)
				}
				if exported.Id != expected.Id || !exported.MarkedAt.Equal(expected.MarkedAt) ||
					!reflect.DeepEqual(exported.ContactId, expected.ContactId) || !reflect.DeepEqual(exported.Scene, expected.Scene) {
					t.Fatalf("exported mark %d = %+v, want %+v", i, exported, expected)
				}
			}
			for _, part := range archive {
				t35Exclude(t, part, markRequest.String(), siblingRequest.String(), foreignMarkRequest.String(), `"input_mac":`)
				for _, candidate := range []app.Mark{mark, sibling, foreignMark} {
					if !slices.ContainsFunc(want, func(m app.Mark) bool { return m.Id == candidate.Id }) {
						t35Exclude(t, part, candidate.Id.String())
					}
				}
			}
			return page.Items
		}
		assertErasure := func(userID, markID uuid.UUID, erased bool) {
			t.Helper()
			var source, alias bool
			if err := s.db.QueryRow(ctx, `select
				exists(select 1 from manual_marks where user_id=$1 and id=$2),
				exists(select 1 from mark_requests where user_id=$1 and mark_id=$2)`,
				userID, markID).Scan(&source, &alias); err != nil {
				t.Fatal(err)
			}
			key := "deleted:" + markID.String()
			ttl, err := s.registryRedis.PTTL(ctx, key).Result()
			if err != nil {
				t.Fatal(err)
			}
			registered, err := s.registryRedis.Exists(ctx, key).Result()
			if err != nil {
				t.Fatal(err)
			}
			wantPresent := !erased
			if source != wantPresent || alias != wantPresent ||
				(erased && (registered != 1 || ttl <= 0)) || (!erased && registered != 0) {
				t.Fatalf("mark %s: erased=%t, source=%t, alias=%t, ledger keys=%d, ttl=%v", markID, erased, source, alias, registered, ttl)
			}
		}

		locators := assertMarks(a.AccessToken, sibling, mark)
		assertMarks(b.AccessToken, foreignMark)
		// Select the older row so deleting the first result cannot satisfy the test.
		selected := *locators[1].Id
		path := listPath + "/" + selected.String()
		call("GET", listPath, "", 401)
		call("DELETE", path, "", 401)
		call("DELETE", path, revoked.AccessToken, 401)
		w := invokeWithoutGate("DELETE", path, func(c *gin.Context) {
			business.DeleteSource(c, app.DeleteSourceParamsKindManualMarks, selected)
		})
		if w.Code != 401 {
			t.Fatalf("revoked delete handler: got %d, want 401: %s", w.Code, w.Body)
		}
		missing := call("DELETE", listPath+"/"+uuid.NewString(), a.AccessToken, 404)
		var problem struct {
			Code      string `json:"code"`
			Retryable *bool  `json:"retryable"`
		}
		t35Decode(t, missing, &problem)
		if problem.Code != "not_found" || problem.Retryable == nil || *problem.Retryable {
			t.Fatalf("unknown mark response: %s", missing)
		}
		for _, body := range [][]byte{
			call("DELETE", path, b.AccessToken, 404),
			call("DELETE", listPath+"/"+foreignMark.Id.String(), a.AccessToken, 404),
			call("DELETE", "/v1/me/data/contacts/"+selected.String(), a.AccessToken, 404),
		} {
			if !bytes.Equal(body, missing) {
				t.Fatalf("foreign or wrong-kind mark differs from an unknown ID: %s vs %s", body, missing)
			}
		}
		assertMarks(a.AccessToken, sibling, mark)
		assertMarks(b.AccessToken, foreignMark)
		assertErasure(a.UserId, mark.Id, false)
		assertErasure(a.UserId, sibling.Id, false)
		assertErasure(b.UserId, foreignMark.Id, false)

		var receipt app.Ack
		t35Decode(t, call("DELETE", path, a.AccessToken, 200), &receipt)
		if !receipt.Ok {
			t.Fatal("selected deletion did not acknowledge success")
		}
		call("DELETE", path, a.AccessToken, 404)
		if w := request(t, "POST", "/v1/marks", a.AccessToken, map[string]any{"request_id": markRequest}); w.Code != 409 {
			t.Fatalf("deleted mark request replay: got %d, want 409: %s", w.Code, w.Body)
		}
		assertMarks(a.AccessToken, sibling)
		assertMarks(b.AccessToken, foreignMark)
		assertErasure(a.UserId, mark.Id, true)
		assertErasure(a.UserId, sibling.Id, false)
		assertErasure(b.UserId, foreignMark.Id, false)
	}) {
		return
	}

	// An existing pending intent must hide the archive before any bytes are sent.
	if _, err := s.db.Exec(ctx, `insert into pending_erasure(root_id) values($1)`, sibling.Id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := s.db.Exec(ctx, `delete from pending_erasure where root_id=$1`, sibling.Id); err != nil {
			t.Error(err)
		}
	}()
	blocked := expect("GET", "/v1/me/export", a.AccessToken, nil, 503)
	assertNoArchive(blocked)
	t35Exclude(t, blocked.Body.Bytes(), a.UserId.String(), mark.Id.String(), sibling.Id.String())
	var barrier struct {
		Code      string `json:"code"`
		Retryable bool   `json:"retryable"`
	}
	t35Decode(t, blocked.Body.Bytes(), &barrier)
	if barrier.Code != "service_unavailable" || !barrier.Retryable {
		t.Fatalf("export barrier response: %s", blocked.Body)
	}
	export(t, b.AccessToken)
	expect("DELETE", "/v1/marks/"+sibling.Id.String(), a.AccessToken, nil, 200)
	if marks = manualMarks(t, export(t, a.AccessToken)); len(marks) != 0 {
		t.Fatal("deleted manual mark remained exportable")
	}

	expect("POST", "/v1/me/closure", a.AccessToken, map[string]any{"proof": proof("apple", appleSubject)}, 200)
	assertNoArchive(expect("GET", "/v1/me/export", a.AccessToken, nil, 401))
	recovery := login(proof("apple", appleSubject), false, 200)
	frozen := expect("GET", "/v1/me/export", recovery.AccessToken, nil, 401)
	assertNoArchive(frozen)
	principal, err = s.Accounts.Parse(recovery.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if w := invokeWithoutGate("GET", "/v1/me/export", business.ExportData); w.Code != 401 {
		t.Fatalf("frozen export handler: got %d, want 401: %s", w.Code, w.Body)
	} else {
		assertNoArchive(w)
	}
	expect("DELETE", "/v1/me/closure", recovery.AccessToken, nil, 200)
	export(t, recovery.AccessToken)
}
