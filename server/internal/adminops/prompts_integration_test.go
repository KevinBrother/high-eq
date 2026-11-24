//go:build integration

package adminops_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
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
	postRaw := func(token string, raw []byte) *http.Response {
		t.Helper()
		req := httptest.NewRequest(http.MethodPost, "/admin/v1/prompt-versions", bytes.NewReader(raw))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		return w.Result()
	}
	rejectRaw := func(token string, raw []byte, want int) {
		t.Helper()
		resp := postRaw(token, raw)
		defer resp.Body.Close()
		response, err := io.ReadAll(resp.Body)
		if err != nil {
			t.Fatal(err)
		}
		if resp.StatusCode != want {
			t.Fatalf("status=%d want %d: %s", resp.StatusCode, want, response)
		}
		if bytes.Contains(response, []byte("合成")) {
			t.Fatalf("response echoed template text: %s", response)
		}
	}
	request("GET", "prompt-versions", nil, 401, nil)
	loginOperator := func() (uuid.UUID, string) {
		t.Helper()
		login := uuid.NewString()
		const pw = "fixture-password-only"
		actor, err := adminops.Provision(ctx, db, login, pw, "operator")
		if err != nil {
			t.Fatal(err)
		}
		var auth admin.AdminSession
		request("POST", "auth/login", admin.AdminLoginJSONBody{Login: login, Password: pw}, 200, &auth)
		return actor, auth.AccessToken
	}
	actor, token := loginOperator()

	const task = admin.TaskReplySuggestion
	create := func(task admin.Task, src string) admin.PromptVersion {
		t.Helper()
		var v admin.PromptVersion
		request("POST", "prompt-versions", admin.CreatePromptVersionJSONBody{Task: task, Template: src}, 200, &v)
		return v
	}
	request("POST", "prompt-versions", admin.CreatePromptVersionJSONBody{Task: task, Template: "{{oops"}, 400, nil)
	var roleVersions int
	if e = db.QueryRow(ctx, `select count(*) from prompt_versions where task='role_play'`).Scan(&roleVersions); e != nil {
		t.Fatal(e)
	}
	request("POST", "prompt-versions", admin.CreatePromptVersionJSONBody{Task: admin.TaskRolePlay, Template: "{{profile}}"}, 400, nil)
	var afterInvalid int
	if e = db.QueryRow(ctx, `select count(*) from prompt_versions where task='role_play'`).Scan(&afterInvalid); e != nil || afterInvalid != roleVersions {
		t.Fatal("invalid variable changed role-play versions", roleVersions, afterInvalid, e)
	}
	a := create(task, "test-A")
	b := create(task, "test-B")
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
	check := func(task admin.Task, id uuid.UUID, text string, vars map[string]string) {
		t.Helper()
		got, s, e := prompts.Resolve(ctx, db, string(task), model, user, vars)
		if e != nil || got != id || s != text {
			t.Fatal("published snapshot differs", e)
		}
	}
	if _, _, e := prompts.Resolve(ctx, db, string(task), model, user, nil); !errors.Is(e, prompts.ErrNotFound) {
		t.Fatal("draft was live")
	}
	request("PUT", "prompt-releases", release, 200, nil)
	check(task, a.Id, "test-A", nil)
	release.ExperimentPercent = 100
	request("PUT", "prompt-releases", release, 400, nil)
	release.ExperimentVersionId = &foreign.Id
	request("PUT", "prompt-releases", release, 404, nil)
	check(task, a.Id, "test-A", nil)
	release.ExperimentVersionId = &b.Id
	request("PUT", "prompt-releases", release, 200, nil)
	check(task, b.Id, "test-B", nil)
	release.ExperimentPercent = 0
	release.ExperimentVersionId = nil
	request("PUT", "prompt-releases", release, 200, nil)
	check(task, a.Id, "test-A", nil)

	const official = "请围绕 {{scene}} 展开练习。"
	role := create(admin.TaskRolePlay, official)
	roleRelease := admin.PromptRelease{Task: admin.TaskRolePlay, ModelId: model, PrimaryVersionId: role.Id}
	request("PUT", "prompt-releases", roleRelease, 200, nil)
	if _, _, e := prompts.Resolve(ctx, db, string(admin.TaskRolePlay), model, user, nil); !errors.Is(e, prompts.ErrVariable) {
		t.Fatal("missing variable accepted")
	}
	check(admin.TaskRolePlay, role.Id, "请围绕 合成场景 展开练习。", map[string]string{"scene": "合成场景"})

	// A direct SQL insert models an invalid historical version. Publishing it must
	// fail before moving the live pointer, and the current version must remain resolvable.
	var invalidRole admin.PromptVersion
	e = db.QueryRow(ctx, `insert into prompt_versions(task,version,template)
		select 'role_play',coalesce(max(version),0)+1,'{{profile}}' from prompt_versions where task='role_play'
		returning id,task,version,template,created_at`).Scan(&invalidRole.Id, &invalidRole.Task, &invalidRole.Version, &invalidRole.Template, &invalidRole.CreatedAt)
	if e != nil {
		t.Fatal(e)
	}
	invalidRelease := admin.PromptRelease{Task: admin.TaskRolePlay, ModelId: model, PrimaryVersionId: invalidRole.Id}
	request("PUT", "prompt-releases", invalidRelease, 400, nil)
	check(admin.TaskRolePlay, role.Id, "请围绕 回滚后场景 展开练习。", map[string]string{"scene": "回滚后场景"})
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
	if e = db.QueryRow(ctx, `select count(*) filter(where result='ok'),count(*) filter(where result='failed'),coalesce(bool_or(target like '%PRIVATE%' or target like '%{{%'),false) from admin_audit_logs where actor_id=$1 and action in ('createPromptVersion','setPromptRelease')`, actor).Scan(&ok, &failed, &leak); e != nil || ok != 8 || failed != 5 || leak {
		t.Fatal("incorrect audit", ok, failed, leak, e)
	}

	// Keep UTF-8 fixture writes out of the lifecycle actor's totals and paging.
	utf8Actor, utf8Token := loginOperator()
	expectCreateAudit := func(actor uuid.UUID, result string, write func()) {
		t.Helper()
		counts := func() (total, matching int) {
			t.Helper()
			err := db.QueryRow(ctx, `select count(*), count(*) filter (where result=$2 and target='prompts')
				from admin_audit_logs where actor_id=$1 and action='createPromptVersion'`, actor, result).Scan(&total, &matching)
			if err != nil {
				t.Fatal(err)
			}
			return total, matching
		}
		before, matchedBefore := counts()
		write()
		after, matchedAfter := counts()
		if after-before != 1 || matchedAfter-matchedBefore != 1 {
			t.Fatalf("createPromptVersion audit for actor=%s result=%s target=prompts: total delta=%d matching delta=%d want 1/1",
				actor, result, after-before, matchedAfter-matchedBefore)
		}
	}
	promptCount := func() int {
		t.Helper()
		var count int
		if err := db.QueryRow(ctx, `select count(*) from prompt_versions where task=$1`, task).Scan(&count); err != nil {
			t.Fatal(err)
		}
		return count
	}
	promptCountBefore := promptCount()
	invalidVersion := append([]byte(`{"task":"reply_suggestion","template":"合成`), 0xff)
	invalidVersion = append(invalidVersion, []byte(`"}`)...)
	expectCreateAudit(uuid.Nil, "denied", func() { rejectRaw("", invalidVersion, 401) })
	expectCreateAudit(utf8Actor, "failed", func() { rejectRaw(utf8Token, invalidVersion, 400) })
	if after := promptCount(); after != promptCountBefore {
		t.Fatalf("invalid encoding wrote prompt versions: before=%d after=%d", promptCountBefore, after)
	}
	validTemplate := "合法多字节模板 �"
	validVersion := []byte(`{"task":"reply_suggestion","template":"` + validTemplate + `"}`)
	expectCreateAudit(utf8Actor, "ok", func() {
		resp := postRaw(utf8Token, validVersion)
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			response, _ := io.ReadAll(resp.Body)
			t.Fatalf("valid UTF-8 status=%d want 200: %s", resp.StatusCode, response)
		}
		var stored admin.PromptVersion
		if err := json.NewDecoder(resp.Body).Decode(&stored); err != nil {
			t.Fatal(err)
		}
		if stored.Task != task || stored.Template != validTemplate {
			t.Fatalf("stored prompt=%+v want task=%s template=%q", stored, task, validTemplate)
		}
	})
	if after := promptCount(); after != promptCountBefore+1 {
		t.Fatalf("valid encoding wrote %d prompt versions, want 1", after-promptCountBefore)
	}
}
