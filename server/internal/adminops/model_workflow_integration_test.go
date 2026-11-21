//go:build integration

package adminops_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/adminops"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/privacy"
	"high-eq/server/migrations"
)

// Run only via the disposable runtime suite. Trust one ephemeral TLS certificate
// and refuse to dial anywhere except its loopback port. No environment field key.
func TestModelWorkflow(t *testing.T) {
	ctx := context.Background()
	must := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	dsn := os.Getenv("DATABASE_URL")
	must(migrations.Up(ctx, dsn))
	db, e := pgxpool.New(ctx, dsn)
	must(e)
	defer db.Close()
	rc := func(name string) *redis.Client {
		opts, e := redis.ParseURL(os.Getenv(name))
		must(e)
		c := redis.NewClient(opts)
		t.Cleanup(func() { c.Close() })
		return c
	}
	cache := rc("REDIS_URL")
	ledger, e := privacy.BindLedger(ctx, db, rc("LEDGER_URL"), 45)
	must(e)
	var calls atomic.Int64
	upstream := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		var b struct {
			Model    string
			Stream   bool
			Messages []gateway.Message
		}
		if json.NewDecoder(r.Body).Decode(&b) != nil || r.URL.Path != "/chat/completions" || r.Header.Get("Authorization") != "Bearer synthetic-key-1234" {
			t.Error("invalid synthetic wire request")
			w.WriteHeader(400)
			return
		}
		if b.Stream {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", b.Model)
			return
		}
		if b.Model != "review" && (len(b.Messages) != 1 || b.Messages[0].Content != "synthetic connectivity check") {
			t.Error("probe was not synthetic")
		}
		fmt.Fprint(w, `{"choices":[{"message":{"content":"{\"verdict\":\"allow\"}"},"finish_reason":"stop"}]}`)
	}))
	defer upstream.Close()
	transport := upstream.Client().Transport.(*http.Transport).Clone()
	u, _ := url.Parse(upstream.URL)
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		if address != u.Host {
			return nil, errors.New("nonfixture destination")
		}
		return (&net.Dialer{}).DialContext(ctx, network, address)
	}
	orig := http.DefaultTransport
	http.DefaultTransport = transport
	defer func() { http.DefaultTransport = orig }()
	key := make([]byte, 32)
	_, e = rand.Read(key)
	must(e)
	fields, e := fieldcrypt.New(1, map[uint32][]byte{1: key})
	must(e)
	catalog, e := gateway.Start(ctx, db, cache, fields)
	must(e)
	defer catalog.Close()
	consumer, e := gateway.Start(ctx, db, cache, fields)
	must(e)
	defer consumer.Close()
	business, e := consumer.NewRouter(privacy.NewCoordinator(db, ledger, nil), func(context.Context, gateway.Scope, gateway.Terminal) error {
		return errors.New("unexpected safety stop")
	})
	must(e)
	r := gin.New()
	adminops.Register(r, db, catalog)
	type M = map[string]any
	call := func(method, path, token string, body M, want int) M {
		t.Helper()
		var raw []byte
		if body != nil {
			raw, e = json.Marshal(body)
			must(e)
		}
		req := httptest.NewRequest(method, "/admin/v1/"+path, bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != want {
			t.Fatalf("%s %s: got %d want %d", method, path, w.Code, want)
		}
		if strings.Contains(w.Body.String(), "synthetic-key-") {
			t.Fatal("secret in response")
		}
		var v M
		must(json.Unmarshal(w.Body.Bytes(), &v))
		return v
	}
	login := func(role string) (string, uuid.UUID) {
		name := uuid.NewString()
		id, e := adminops.Provision(ctx, db, name, "synthetic-password", role)
		must(e)
		return call("POST", "auth/login", "", M{"login": name, "password": "synthetic-password"}, 200)["access_token"].(string), id
	}
	root, actor := login("super_admin")
	op, _ := login("operator")
	call("POST", "admissions", op, nil, 403)
	call("GET", "models", "", nil, 401)
	admission := func(kind string, days int) string {
		v := M{"kind": kind, "provider": "fixture", "endpoint": upstream.URL, "model_scope": "*", "purpose": "synthetic", "sent_fields": []string{"model", "messages.role", "messages.content", "stream", "response_format.type"}, "processing_country": "CN", "storage_country": "CN", "cross_border": true, "max_retention_days": days, "deletion_method": "auto", "terms_evidence": "private-fixture-evidence"}
		call("POST", "admissions", root, v, 409)
		v["cross_border"] = false
		return call("POST", "admissions", root, v, 200)["ref"].(string)
	}
	a := admission("model", 0)
	m := admission("moderation", 0)
	weak := admission("model", 2)
	model := func(kind, name, ref string) string {
		v := M{"name": name, "kind": kind, "provider": "fixture", "endpoint": upstream.URL, "model_name": name, "api_key": "synthetic-key-1234", "admission_ref": ref, "enabled": true, "input_cny_per_million": 1, "output_cny_per_million": 2}
		out := call("POST", "models", root, v, 200)
		if out["key_last_four"] != "1234" {
			t.Fatal("missing key suffix")
		}
		return out["id"].(string)
	}
	p := model("model", "one", a)
	b := model("model", "two", a)
	mod := model("moderation", "review", m)
	w := model("model", "weak", weak)
	page := call("GET", "models?limit=1", root, nil, 200)
	if len(page["items"].([]any)) != 1 || page["next_cursor"] == nil {
		t.Fatal("missing model pagination")
	}
	rotated := call("PATCH", "models/"+p, root, M{"api_key": "synthetic-key-5678"}, 200)
	if rotated["key_last_four"] != "5678" {
		t.Fatal("rotation did not update suffix")
	}
	kept := call("PATCH", "models/"+p, root, M{"input_cny_per_million": 3}, 200)
	if kept["key_last_four"] != "5678" || kept["input_cny_per_million"] != float64(3) {
		t.Fatal("partial model edit lost tariff/key")
	}
	call("PATCH", "models/"+p, root, M{"api_key": "synthetic-key-1234", "enabled": false}, 200)
	call("POST", "models/"+p+"/test", root, nil, 404)
	call("PATCH", "models/"+p, root, M{"enabled": true}, 200)
	call("PATCH", "models/"+p, root, M{"endpoint": "https://wrong.invalid", "api_key": "synthetic-key-1234"}, 409)
	call("POST", "models/"+p+"/test", root, M{"text": "private-fixture"}, 400)
	if calls.Load() != 0 {
		t.Fatal("rejected probe dispatched")
	}
	call("POST", "models/"+p+"/test", root, nil, 200)
	if calls.Load() != 1 {
		t.Fatal("probe missing")
	}
	route := M{"primary_model": p, "fallback_model": w, "moderation_model": mod, "canary_model": nil, "canary_percent": 0}
	path := "routes/classification"
	call("PUT", path, root, route, 409)
	route["fallback_model"] = b
	route["canary_model"] = w
	route["canary_percent"] = 50
	call("PUT", path, root, route, 409)
	route["canary_percent"] = 0
	route["canary_model"] = nil
	call("PUT", path, root, route, 200)
	call("PATCH", "models/"+p, root, M{"enabled": false}, 409)
	// If the independent prompt module is installed, provision synthetic releases
	// for these two models. The production route still performs all of its checks.
	var releases bool
	must(db.QueryRow(ctx, `select to_regclass('prompt_releases') is not null`).Scan(&releases))
	if releases {
		var version uuid.UUID
		must(db.QueryRow(ctx, `insert into prompt_versions(task,version,template) select 'classification',coalesce(max(version),0)+1,'synthetic fixture' from prompt_versions where task='classification' returning id`).Scan(&version))
		for _, id := range []string{p, b} {
			_, e = db.Exec(ctx, `insert into prompt_releases(task,model_id,primary_version_id,experiment_percent) values('classification',$1,$2,0)`, id, version)
			must(e)
		}
	}
	user := uuid.New()
	_, e = db.Exec(ctx, `insert into users(id,age_confirmed_at) values($1,now())`, user)
	must(e)
	invoke := func(want string) {
		out, e := business.Run(ctx, gateway.Call{Scope: gateway.Scope{User: user, Operation: uuid.New()}, Task: gateway.Classification, Mode: gateway.Text, Messages: []gateway.Message{{Role: "user", Content: "synthetic business input"}}})
		must(e)
		if out.Result.Text != want {
			t.Fatalf("business route: want %s", want)
		}
	}
	invoke("one")
	route["primary_model"], route["fallback_model"] = b, p
	// Fail only the success audit; the route and its revision must roll back.
	_, e = db.Exec(ctx, `alter table admin_audit_logs add constraint t14_fault check(not(actor_id='`+actor.String()+`' and action='setRoute' and result='ok')) not valid`)
	must(e)
	defer db.Exec(ctx, `alter table admin_audit_logs drop constraint if exists t14_fault`)
	call("PUT", path, root, route, 500)
	invoke("one")
	_, e = db.Exec(ctx, `alter table admin_audit_logs drop constraint t14_fault`)
	must(e)
	call("PUT", path, root, route, 200)
	invoke("two")
	call("DELETE", "admissions/"+a, root, nil, 200)
	count := calls.Load()
	call("POST", "models/"+p+"/test", root, nil, 404)
	if calls.Load() != count {
		t.Fatal("revoked probe dispatched")
	}
	routes := call("GET", "routes", root, nil, 200)
	if len(routes["items"].([]any)) != 0 {
		t.Fatal("revoked route remains")
	}
	var leaked bool
	must(db.QueryRow(ctx, `select exists(select from admin_audit_logs where row_to_json(admin_audit_logs)::text like '%private-fixture%' or row_to_json(admin_audit_logs)::text like '%synthetic-key%')`).Scan(&leaked))
	if leaked {
		t.Fatal("sensitive audit metadata")
	}
	var successes, failures int
	must(db.QueryRow(ctx, `select count(*)filter(where result='ok'),count(*)filter(where result='failed') from admin_audit_logs where actor_id=$1 and action='setRoute'`, actor).Scan(&successes, &failures))
	if successes != 2 || failures != 3 {
		t.Fatalf("route audit %d ok, %d failed", successes, failures)
	}
}
