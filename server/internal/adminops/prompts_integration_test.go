//go:build integration

package adminops_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"net/url"
	"os"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/prompts"
	"high-eq/server/migrations"
)

// Exercise the generated admin routes, guard, transactional audit, database constraints and
// exactly the reader installed by Catalog.NewRouter. Only the model configuration is synthetic.
func TestPromptLifecycle(t *testing.T) {
	ctx := context.Background()
	dsn := os.Getenv("DATABASE_URL")
	if e := migrations.Up(ctx, dsn); e != nil {
		t.Fatal(e)
	}
	db, e := pgxpool.New(ctx, dsn)
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	r := gin.New()
	adminops.Register(r, db)
	var token string
	request := func(method, path string, body any, want int, out any) {
		t.Helper()
		raw, e := json.Marshal(body)
		if e != nil {
			t.Fatal(e)
		}
		req := httptest.NewRequest(method, "/admin/v1/"+path, bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("%s %s: status %d want %d", method, path, w.Code, want)
		}
		if out != nil {
			if e = json.Unmarshal(w.Body.Bytes(), out); e != nil {
				t.Fatal(e)
			}
		}
	}
	request("GET", "prompt-versions", nil, 401, nil)
	login := uuid.NewString()
	const pw = "fixture-password-only"
	actor, e := adminops.Provision(ctx, db, login, pw, "operator")
	if e != nil {
		t.Fatal(e)
	}
	var auth admin.AdminSession
	request("POST", "auth/login", admin.AdminLoginJSONBody{Login: login, Password: pw}, 200, &auth)
	token = auth.AccessToken
	const task = admin.TaskReplySuggestion
	create := func(task admin.Task, src string) admin.PromptVersion {
		t.Helper()
		var v admin.PromptVersion
		request("POST", "prompt-versions", admin.CreatePromptVersionJSONBody{Task: task, Template: src}, 200, &v)
		return v
	}
	request("POST", "prompt-versions", admin.CreatePromptVersionJSONBody{Task: task, Template: "{{oops"}, 400, nil)
	a := create(task, "test-A {{x}}")
	b := create(task, "test-B {{x}}")
	foreign := create(admin.TaskClassification, "fixture")
	if b.Version != a.Version+1 || a.Id == b.Id {
		t.Fatal("not a new consecutive version")
	}
	var page struct {
		Items []admin.PromptVersion
		Next  string `json:"next_cursor"`
	}
	request("GET", "prompt-versions?limit=1&task="+string(task), nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != b.Id || page.Next == "" {
		t.Fatal("bad first page")
	}
	request("GET", "prompt-versions?limit=1&task="+string(task)+"&cursor="+url.QueryEscape(page.Next), nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != a.Id {
		t.Fatal("bad second page")
	}
	model, user := uuid.New(), uuid.New()
	if _, e = db.Exec(ctx, `insert into model_configs(id,name,endpoint,api_key_enc) values($1,'fixture','test','x')`, model); e != nil {
		t.Fatal(e)
	}
	release := admin.PromptRelease{Task: task, ModelId: model, PrimaryVersionId: a.Id}
	check := func(id uuid.UUID, text string) {
		t.Helper()
		got, s, e := prompts.Resolve(ctx, db, string(task), model, user, map[string]string{"x": "PRIVATE-FIXTURE"})
		if e != nil || got != id || s != text {
			t.Fatal("published snapshot differs", e)
		}
	}
	if _, _, e := prompts.Resolve(ctx, db, string(task), model, user, nil); !errors.Is(e, prompts.ErrNotFound) {
		t.Fatal("draft was live")
	}
	request("PUT", "prompt-releases", release, 200, nil)
	check(a.Id, "test-A PRIVATE-FIXTURE")
	release.ExperimentPercent = 100
	request("PUT", "prompt-releases", release, 400, nil)
	release.ExperimentVersionId = &foreign.Id
	request("PUT", "prompt-releases", release, 404, nil)
	check(a.Id, "test-A PRIVATE-FIXTURE")
	release.ExperimentVersionId = &b.Id
	request("PUT", "prompt-releases", release, 200, nil)
	check(b.Id, "test-B PRIVATE-FIXTURE")
	release.ExperimentPercent = 0
	release.ExperimentVersionId = nil
	request("PUT", "prompt-releases", release, 200, nil)
	check(a.Id, "test-A PRIVATE-FIXTURE")
	if _, _, e := prompts.Resolve(ctx, db, string(task), model, user, nil); !errors.Is(e, prompts.ErrVariable) {
		t.Fatal("missing variable accepted")
	}
	var relPage struct {
		Items []admin.PromptRelease
		Next  *string `json:"next_cursor"`
	}
	found := false
	path := "prompt-releases?limit=1"
	for {
		request("GET", path, nil, 200, &relPage)
		for _, v := range relPage.Items {
			if v.ModelId == model && v.Task == task && v.PrimaryVersionId == a.Id && v.ExperimentVersionId == nil {
				found = true
			}
		}
		if found || relPage.Next == nil {
			break
		}
		path = "prompt-releases?limit=1&cursor=" + url.QueryEscape(*relPage.Next)
	}
	if !found {
		t.Fatal("release not listed")
	}
	for _, sql := range []string{`update prompt_versions set template='mutated' where id=$1`, `delete from prompt_versions where id=$1`} {
		if _, e = db.Exec(ctx, sql, foreign.Id); e == nil {
			t.Fatal("draft was mutable")
		}
	}
	var ok, failed int
	var leak bool
	if e = db.QueryRow(ctx, `select count(*) filter(where result='ok'),count(*) filter(where result='failed'),coalesce(bool_or(target like '%PRIVATE%' or target like '%{{%'),false) from admin_audit_logs where actor_id=$1 and action in ('createPromptVersion','setPromptRelease')`, actor).Scan(&ok, &failed, &leak); e != nil || ok != 6 || failed != 3 || leak {
		t.Fatal("incorrect audit", ok, failed, leak, e)
	}
}
