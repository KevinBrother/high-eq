//go:build integration

package adminops_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/adminops"
	"high-eq/server/migrations"
)

func TestAdminBoundary(t *testing.T) {
	ctx := context.Background()
	dsn := os.Getenv("DATABASE_URL")
	if err := migrations.Up(ctx, dsn); err != nil {
		t.Fatal(err)
	}
	db, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	adminops.Register(r, db)
	request := func(method, path, token, body string, want int) map[string]any {
		t.Helper()
		w := httptest.NewRecorder()
		req := httptest.NewRequest(method, "/admin/v1/"+path, strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+token)
		r.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("%s %s: got %d want %d", method, path, w.Code, want)
		}
		var out map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	const pass = "fixture-password-only"
	login := func(name, password string, code int) map[string]any {
		return request("POST", "auth/login", "", `{"login":"`+name+`","password":"`+password+`"}`, code)
	}
	op, root := uuid.NewString(), uuid.NewString()
	actor, err := adminops.Provision(ctx, db, op, pass, "operator")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = adminops.Provision(ctx, db, root, pass, "super_admin"); err != nil {
		t.Fatal(err)
	}
	login(op, "wrong-password", 401)
	login("unknown-identifier", pass, 401)
	res := login(op, pass, 200)
	if res["role"] != "operator" {
		t.Fatal("wrong role")
	}
	o := res["access_token"].(string)
	s := login(root, pass, 200)["access_token"].(string)
	request("GET", "audit-logs", "ordinary-app-token", "", 401)
	request("GET", "audit-logs", o, "", 403)
	request("PATCH", "models/private-note", o, `{"role":"super_admin"}`, 403)
	request("PUT", "routes/private-note", o, "", 403)
	request("POST", "auth/login", "", `{"login":"`+op+`","password":"`+pass+`","role":"super_admin"}`, 400)
	var start, end time.Time
	if err = db.QueryRow(ctx, "select clock_timestamp()").Scan(&start); err != nil {
		t.Fatal(err)
	}
	id := uuid.NewString()
	request("PATCH", "models/"+id+"?q=private-note", o, `{"api_key":"private-key","text":"private-note"}`, 403)
	if err = db.QueryRow(ctx, "select clock_timestamp()").Scan(&end); err != nil {
		t.Fatal(err)
	}
	for _, route := range []struct{ method, path string }{{"POST", "models"}, {"POST", "models/" + id + "/test"}, {"PUT", "routes/role_play"}} {
		request(route.method, route.path, o, "", 403)
	}
	request("PATCH", "models/"+id, s, "", 501)
	filter := url.Values{"actor_id": {actor.String()}, "from": {start.Format(time.RFC3339Nano)}, "until": {end.Format(time.RFC3339Nano)}}
	rows := request("GET", "audit-logs?"+filter.Encode(), s, "", 200)["items"].([]any)
	if len(rows) != 1 {
		t.Fatalf("filter returned %d", len(rows))
	}
	row := rows[0].(map[string]any)
	if row["result"] != "denied" || row["action"] != "updateModel" || row["target"] != id {
		t.Fatal("wrong audit metadata")
	}
	filter.Set("until", row["occurred_at"].(string))
	if len(request("GET", "audit-logs?"+filter.Encode(), s, "", 200)["items"].([]any)) != 0 {
		t.Fatal("upper bound included")
	}
	page := request("GET", "audit-logs?limit=1&actor_id="+actor.String(), s, "", 200)
	next := request("GET", "audit-logs?actor_id="+actor.String()+"&limit=1&cursor="+url.QueryEscape(page["next_cursor"].(string)), s, "", 200)
	if page["items"].([]any)[0].(map[string]any)["id"] == next["items"].([]any)[0].(map[string]any)["id"] {
		t.Fatal("page duplicated")
	}
	request("GET", "audit-logs?limit=101", s, "", 400)
	request("GET", "audit-logs?cursor=nope", s, "", 400)
	request("POST", "auth/logout", o, "", 200)
	request("POST", "models", o, "", 401)
	var okWrites, deniedLogins int
	if e := db.QueryRow(ctx, `select count(*) filter(where action in ('adminLogin','adminLogout') and result='ok'),count(*) filter(where action='adminLogin' and result='denied') from admin_audit_logs where actor_id=$1`, actor).Scan(&okWrites, &deniedLogins); e != nil || okWrites != 2 || deniedLogins != 1 {
		t.Fatalf("actor audit: %d successes, %d login refusals; %v", okWrites, deniedLogins, e)
	}
	if _, err = db.Exec(ctx, "update admin_sessions set expires_at=now() where admin_id=(select id from admin_accounts where login=$1)", root); err != nil {
		t.Fatal(err)
	}
	request("GET", "audit-logs", s, "", 401)
	// The test-only constraint rejects ONLY this actor's successful login audit.
	// Database-side failure must not leave a usable session or a success response.
	if _, err = db.Exec(ctx, "alter table admin_audit_logs add constraint t13_fault check(not (actor_id='"+actor.String()+"' and action='adminLogin' and result='ok')) not valid"); err != nil {
		t.Fatal(err)
	}
	func() {
		defer func() {
			if _, e := db.Exec(ctx, "alter table admin_audit_logs drop constraint t13_fault"); e != nil {
				t.Error(e)
			}
		}()
		login(op, pass, 500)
		var count int
		if e := db.QueryRow(ctx, "select count(*) from admin_sessions where admin_id=$1", actor).Scan(&count); e != nil || count != 0 {
			t.Fatal("audit failure did not roll back session issuance")
		}
	}()
	var logs []byte
	if err = db.QueryRow(ctx, "select json_agg(a) from admin_audit_logs a").Scan(&logs); err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{pass, o, s, "private-key", "private-note", "wrong-password", "unknown-identifier", op, root} {
		if bytes.Contains(logs, []byte(secret)) {
			t.Fatal("audit leaked input")
		}
	}
}
