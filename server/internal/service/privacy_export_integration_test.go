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

	request := func(method, path, bearer string, body any) *httptest.ResponseRecorder {
		t.Helper()
		var raw []byte
		if body != nil {
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
		w := request(method, path, bearer, body)
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
	w = expect("POST", "/v1/marks", a.AccessToken, map[string]any{
		"request_id": markRequest,
		"contact_id": contact.Id,
		"scene":      markScene,
	}, 200)
	var mark app.Mark
	if err := json.Unmarshal(w.Body.Bytes(), &mark); err != nil {
		t.Fatal(err)
	}
	if mark.ContactId == nil || *mark.ContactId != contact.Id || mark.Scene == nil || *mark.Scene != markScene {
		t.Fatalf("manual mark did not preserve object and scene: %+v", mark)
	}
	t.Run("selected_record_delete_stays_unimplemented", func(t *testing.T) {
		path := "/v1/me/data/manual_marks/" + mark.Id.String()
		w := request("DELETE", path, "", nil)
		if w.Code != 401 {
			t.Fatalf("anonymous DELETE %s: got %d, want 401: %s", path, w.Code, w.Body)
		}
		w = request("DELETE", path, a.AccessToken, nil)
		if w.Code != 501 {
			t.Fatalf("authenticated DELETE %s: got %d, want 501: %s", path, w.Code, w.Body)
		}
		var response struct {
			Code      string `json:"code"`
			Retryable *bool  `json:"retryable"`
		}
		t35Decode(t, w.Body.Bytes(), &response)
		if response.Code != "not_implemented" || response.Retryable == nil || *response.Retryable {
			t.Fatalf("deferred deletion response: %s", w.Body)
		}
	})
	// The owner's mark must still be present in the subsequent export.
	expect("PUT", "/v1/me/consents/manual_mark", b.AccessToken, map[string]any{"version": "v1", "granted": true}, 200)
	foreignMarkRequest := uuid.New()
	w = expect("POST", "/v1/marks", b.AccessToken, map[string]any{"request_id": foreignMarkRequest}, 200)
	var foreignMark app.Mark
	t35Decode(t, w.Body.Bytes(), &foreignMark)

	export := func(token string) map[string][]byte {
		t.Helper()
		w := expect("GET", "/v1/me/export", token, nil, 200)
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
	manualMarks := func(files map[string][]byte) []app.Mark {
		t.Helper()
		var marks []app.Mark
		if err := json.Unmarshal(files["manual_marks.json"], &marks); err != nil {
			t.Fatal(err)
		}
		return marks
	}

	files := export(a.AccessToken)
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
	marks := manualMarks(files)
	if len(marks) != 1 || marks[0].Id != mark.Id || !marks[0].MarkedAt.Equal(mark.MarkedAt) || marks[0].ContactId == nil || *marks[0].ContactId != contact.Id || marks[0].Scene == nil || *marks[0].Scene != markScene {
		t.Fatalf("manual mark export = %+v, want time/object/scene from %+v", marks, mark)
	}
	t35Exclude(t, files["manual_marks.json"], foreignMark.Id.String(), markRequest.String(),
		foreignMarkRequest.String(), `"request_id":`, `"input_mac":`)
	if other := manualMarks(export(b.AccessToken)); len(other) != 1 || other[0].Id != foreignMark.Id {
		t.Fatal("the other account did not get exactly its own mark")
	}

	// An existing pending intent must hide the archive before any bytes are sent.
	if _, err := s.db.Exec(ctx, `insert into pending_erasure(root_id) values($1)`, mark.Id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := s.db.Exec(ctx, `delete from pending_erasure where root_id=$1`, mark.Id); err != nil {
			t.Error(err)
		}
	}()
	blocked := expect("GET", "/v1/me/export", a.AccessToken, nil, 503)
	assertNoArchive(blocked)
	t35Exclude(t, blocked.Body.Bytes(), a.UserId.String(), mark.Id.String())
	var barrier struct {
		Code      string `json:"code"`
		Retryable bool   `json:"retryable"`
	}
	t35Decode(t, blocked.Body.Bytes(), &barrier)
	if barrier.Code != "service_unavailable" || !barrier.Retryable {
		t.Fatalf("export barrier response: %s", blocked.Body)
	}
	export(b.AccessToken)
	expect("DELETE", "/v1/marks/"+mark.Id.String(), a.AccessToken, nil, 200)
	if marks = manualMarks(export(a.AccessToken)); len(marks) != 0 {
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
	export(recovery.AccessToken)
}
