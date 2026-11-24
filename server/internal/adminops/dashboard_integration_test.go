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
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/migrations"
)

// Real admin auth/handler, PG rows and encrypted numeric projections. No vendor
// credentials, production accounts, source text, or dashboard fixture endpoint.
func TestDashboardInventory(t *testing.T) {
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
	verifyDashboard(t, db)
}
func verifyDashboard(t *testing.T, db *pgxpool.Pool) {
	ctx := context.Background()
	must := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	exec := func(sql string, args ...any) { t.Helper(); _, e := db.Exec(ctx, sql, args...); must(e) }
	fields, e := fieldcrypt.New(1, map[uint32][]byte{1: bytes.Repeat([]byte{4}, 32)})
	must(e)
	r := gin.New()
	adminops.RegisterDashboard(r, db, nil, fields)
	var token string
	req := func(method, path string, body any, status int, out any) {
		t.Helper()
		b, e := json.Marshal(body)
		must(e)
		h := httptest.NewRequest(method, "/admin/v1/"+path, bytes.NewReader(b))
		h.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, h)
		if w.Code != status {
			t.Fatalf("%s: status %d want %d", strings.Split(path, "?")[0], w.Code, status)
		}
		if bytes.Contains(w.Body.Bytes(), []byte("PRIVATE")) {
			t.Fatal("private material in response")
		}
		if out != nil {
			must(json.Unmarshal(w.Body.Bytes(), out))
		}
	}
	req("GET", "metrics", nil, 401, nil)
	login := uuid.NewString()
	const password = "synthetic-dashboard-only"
	_, e = adminops.Provision(ctx, db, login, password, "operator")
	must(e)
	var auth admin.AdminSession
	req("POST", "auth/login", admin.AdminLoginJSONBody{Login: login, Password: password}, 200, &auth)
	token = auth.AccessToken
	req("GET", "models", nil, 403, nil)
	model, user := uuid.New(), uuid.New()
	exec(`insert into model_configs(id,name,endpoint,api_key_enc) values($1,'fixture','PRIVATE','PRIVATE')`, model)
	defer func() {
		exec(`delete from users where id=$1`, user)
		exec(`delete from prompt_releases where model_id=$1`, model)
		exec(`delete from model_configs where id=$1`, model)
	}()
	var inventory struct {
		Items []map[string]any
		Next  *string `json:"next_cursor"`
	}
	path := "prompt-models?limit=100"
	found := false
	for {
		req("GET", path, nil, 200, &inventory)
		for _, m := range inventory.Items {
			if len(m) != 3 || m["name"] == nil || m["enabled"] == nil {
				t.Fatal("unexpected model projection")
			}
			found = found || m["id"] == model.String()
		}
		if inventory.Next == nil {
			break
		}
		path = "prompt-models?cursor=" + url.QueryEscape(*inventory.Next)
	}
	if !found {
		t.Fatal("model without a release not discoverable")
	}
	var v, other admin.PromptVersion
	for _, ptr := range []*admin.PromptVersion{&v, &other} {
		req("POST", "prompt-versions", admin.CreatePromptVersionJSONBody{Task: admin.TaskScoring, Template: "synthetic {{assessment}}"}, 200, ptr)
	}
	exec(`insert into users(id,age_confirmed_at) values($1,now())`, user)
	sources := []uuid.UUID{uuid.New(), uuid.New(), uuid.New(), uuid.New()}
	acts := []uuid.UUID{}
	for i, id := range sources {
		a := uuid.New()
		acts = append(acts, a)
		exec(`insert into activities(id,user_id,kind,source_id) values($1,$2,'practice',$3)`, a, user, id)
		exec(`insert into scores(id,activity_id,activity_kind,detail_enc) values($1,$2,'practice','PRIVATE')`, id, a)
		if i < 3 {
			total := []int{0, 74, 74}[i]
			raw, _ := json.Marshal(map[string]int{"total": total})
			enc, e := fields.Seal(raw, []byte("growth_scores.nvc_enc/"+id.String()))
			must(e)
			exec(`insert into growth_scores values($1,'practice',$2,'PRIVATE')`, id, enc)
		}
	}
	now := time.Now().UTC().Truncate(time.Second)
	from := now.Add(-time.Hour)
	insert := func(version any, source int, outcome string, cost any, ts time.Time) {
		var activity any
		if source >= 0 {
			activity = acts[source]
		}
		call := uuid.New()
		must(pgx.BeginFunc(ctx, db, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `insert into ai_calls(id,user_id,activity_id,model_id,prompt_version_id,task,outcome,latency_ms,cost_cny,started_at) values($1,$2,$3,$4,$5,'scoring',$6,50,$7,$8)`, call, user, activity, model, version, outcome, cost, ts)
			if err != nil || source < 0 {
				return err
			}
			return gateway.LinkScoreTx(ctx, tx, user, call, acts[source], sources[source])
		}))
	}
	for _, index := range []int{0, 1, 1, 2, 3} {
		insert(v.Id, index, "ok", "0.125", from)
	}
	insert(v.Id, -1, "failed", nil, from)
	insert(other.Id, -1, "failed", nil, from)
	insert(nil, -1, "ok", 0, from)
	insert(v.Id, -1, "failed", nil, now)
	// Historical traffic must not be attributed to today's release.
	req("PUT", "prompt-releases", admin.PromptRelease{Task: admin.TaskScoring, ModelId: model, PrimaryVersionId: other.Id}, 200, nil)
	q := url.Values{"model_id": {model.String()}, "task": {"scoring"}, "from": {from.Format(time.RFC3339)}, "until": {now.Format(time.RFC3339)}, "limit": {"1"}}
	type group struct {
		Calls, Failures int
		Unpriced        int        `json:"unpriced_calls"`
		Version         *uuid.UUID `json:"prompt_version_id"`
		Cost            float64    `json:"cost_cny"`
		Mean            float64    `json:"mean_latency_ms"`
		Rate            float64    `json:"failure_rate"`
		Missing         int        `json:"missing_score_values"`
		Bins            []struct {
			Total int `json:"nvc_total"`
			Count int
		} `json:"score_distribution"`
	}
	var page struct {
		Items []group
		Next  *string `json:"next_cursor"`
	}
	groups := 0
	count := 0
	for {
		req("GET", "metrics?"+q.Encode(), nil, 200, &page)
		if len(page.Items) != 1 {
			t.Fatal("page size")
		}
		count += page.Items[0].Calls
		groups++
		if page.Next == nil {
			break
		}
		if groups > 3 {
			t.Fatal("non advancing cursor")
		}
		q.Set("cursor", *page.Next)
	}
	var reference int
	must(db.QueryRow(ctx, `select count(*) from ai_calls where model_id=$1 and started_at >= $2 and started_at < $3`, model, from, now).Scan(&reference))
	if groups != 3 || count != reference || count != 8 {
		t.Fatal("grouped totals disagree", groups, count, reference)
	}
	q.Del("cursor")
	q.Set("prompt_version_id", v.Id.String())
	req("GET", "metrics?"+q.Encode(), nil, 200, &page)
	if len(page.Items) != 1 {
		t.Fatal("missing version group")
	}
	g := page.Items[0]
	if g.Version == nil || *g.Version != v.Id || g.Calls != 6 || g.Failures != 1 || g.Rate != 1.0/6 || g.Mean != 50 || g.Unpriced != 1 || g.Cost != 0.625 || g.Missing != 1 || len(g.Bins) != 2 || g.Bins[0].Total != 0 || g.Bins[0].Count != 1 || g.Bins[1].Total != 74 || g.Bins[1].Count != 2 {
		t.Fatal("incorrect version distribution or cost", g)
	}
	exec(`delete from activities where id=$1`, acts[1])
	req("GET", "metrics?"+q.Encode(), nil, 200, &page)
	if g := page.Items[0]; g.Calls != 4 || g.Bins[1].Count != 1 || g.Cost != 0.375 {
		t.Fatal("stale counts after deletion")
	}
	// Authentication failure opening numeric ciphertext fails closed, never a zero bin.
	exec(`update growth_scores set nvc_enc='invalid' where score_id=$1`, sources[0])
	req("GET", "metrics?"+q.Encode(), nil, 500, nil)
	q.Set("cursor", "not-a-key")
	req("GET", "metrics?"+q.Encode(), nil, 400, nil)
}
