//go:build integration && t14flutter

package service

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
)

// T14 acceptance, real wire: an already-provisioned synthetic super admin
// changes a route's primary model in the shipped Flutter /models page; that page
// talks HTTP to the unchanged service process. The same synthetic app user then
// performs two normal App API calls, and the synthetic upstream observes the
// configured model switch. No provider, browser, simulator or real credential.
func TestT14AdminPageNextAppCall(t *testing.T) {
	if os.Getenv("T14_DISPOSABLE") != "yes" {
		t.Skip("requires T14_DISPOSABLE=yes for disposable loopback PG17 and two Redis instances")
	}
	ctx := t.Context()

	const (
		modelOne  = "t14-one"
		modelTwo  = "t14-two"
		modelBack = "t14-standby"
		review    = "t14-review"
	)
	var wireMu sync.Mutex
	var wire []string
	vendor := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Model    string
			Stream   bool
			Messages []struct{ Role, Content string }
		}
		if r.URL.Path != "/chat/completions" || json.NewDecoder(r.Body).Decode(&in) != nil {
			t.Error("invalid synthetic upstream request")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		wireMu.Lock()
		wire = append(wire, in.Model)
		wireMu.Unlock()
		content := `{"possible_feeling":"担心进度","possible_need":"想了解时间","suggestions":[{"style":"直接","text":"可以说明安排","reason":"给出明确时间"},{"style":"确认","text":"要不要先看计划","reason":"提供选择"}]}`
		if in.Model == review {
			content = `{"verdict":"allow"}`
		}
		// Routed generation always asks for SSE, even for JSON tasks.
		if in.Stream {
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", content)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"choices":[{"message":{"content":%q},"finish_reason":"stop"}]}`, content)
	}))
	defer vendor.Close()
	upstream, err := url.Parse(vendor.URL)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(vendor.Certificate())
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		if address != upstream.Host {
			return nil, errors.New("nonfixture destination")
		}
		return (&net.Dialer{}).DialContext(ctx, network, address)
	}
	old := http.DefaultTransport
	http.DefaultTransport = transport
	t.Cleanup(func() {
		http.DefaultTransport = old
		transport.CloseIdleConnections()
	})

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal("could not load the disposable runtime configuration")
	}
	s, err := Start(ctx, cfg)
	if err != nil {
		t.Fatal("could not start the disposable runtime")
	}
	defer s.Close()

	admission := func(ref string, kind gateway.Kind) {
		t.Helper()
		_, err := s.db.Exec(ctx, `insert into provider_admissions values($1,'t14',$2,'*',$3,'synthetic',ARRAY['model','messages.role','messages.content','stream','response_format.type'],'CN','CN',false,0,'discard','fixture')`, ref, vendor.URL, kind)
		if err != nil {
			t.Fatal("could not seed the synthetic admission")
		}
	}
	model := func(name string, kind gateway.Kind, ref string) uuid.UUID {
		t.Helper()
		id := uuid.New()
		if err := s.catalog.Save(ctx, gateway.Config{ID: id, Name: name, Provider: "t14", Endpoint: vendor.URL, ModelName: name, AdmissionRef: ref, Protocol: "openai_compatible", Kind: kind, Enabled: true}, []byte("synthetic-key-1234")); err != nil {
			t.Fatal("could not seed the synthetic model")
		}
		if _, err := s.db.Exec(ctx, `update model_configs set input_cny_per_million=0,output_cny_per_million=0 where id=$1`, id); err != nil {
			t.Fatal("could not seed the synthetic tariff")
		}
		return id
	}
	oneRef, reviewRef := uuid.NewString(), uuid.NewString()
	admission(oneRef, gateway.Model)
	admission(reviewRef, gateway.Moderation)
	one, two, back := model(modelOne, gateway.Model, oneRef), model(modelTwo, gateway.Model, oneRef), model(modelBack, gateway.Model, oneRef)
	mod := model(review, gateway.Moderation, reviewRef)
	if _, err := s.db.Exec(ctx, `insert into model_routes(task,primary_model,fallback_model,moderation_model) values('reply_suggestion',$1,$2,$3)`, one, back, mod); err != nil {
		t.Fatal("could not seed the initial synthetic route")
	}
	var promptID uuid.UUID
	if err := s.db.QueryRow(ctx, `insert into prompt_versions(task,version,template) select 'reply_suggestion',coalesce(max(version),0)+1,'synthetic reply fixture' from prompt_versions where task='reply_suggestion' returning id`).Scan(&promptID); err != nil {
		t.Fatal("could not seed the synthetic prompt")
	}
	for _, id := range []uuid.UUID{one, two, back} {
		if _, err := s.db.Exec(ctx, `insert into prompt_releases(task,model_id,primary_version_id,experiment_percent) values('reply_suggestion',$1,$2,0)`, id, promptID); err != nil {
			t.Fatal("could not seed the synthetic prompt release")
		}
	}
	var slots int
	if err := s.db.QueryRow(ctx, `select count(*) from model_routes r cross join gateway_revision v
		cross join lateral (values ('primary',r.primary_model),('backup',r.fallback_model),('canary',r.canary_model),('moderator',r.moderation_model)) slots(slot,id)
		join model_configs m on m.id=slots.id and m.enabled
			and m.input_cny_per_million is not null and m.output_cny_per_million is not null
		join provider_admissions a on a.ref=m.active_ref
		where r.task='reply_suggestion' and m.kind=case when slots.slot='moderator' then 'moderation' else 'model' end`).Scan(&slots); err != nil || slots != 3 {
		t.Fatalf("synthetic route is not dispatchable (slots=%d)", slots)
	}

	api := httptest.NewServer(s.Router())
	defer api.Close()
	client := api.Client()
	call := func(method, path, token string, body any, want int, out any) {
		t.Helper()
		var raw []byte
		if body != nil {
			raw, err = json.Marshal(body)
			if err != nil {
				t.Fatal(err)
			}
		}
		req, err := http.NewRequest(method, api.URL+path, bytes.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		resp, err := client.Do(req)
		if err != nil {
			t.Fatalf("%s %s: synthetic request failed", method, path)
		}
		defer resp.Body.Close()
		if resp.StatusCode != want {
			t.Fatalf("%s %s: got %d want %d", method, path, resp.StatusCode, want)
		}
		if out != nil {
			if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
				t.Fatalf("%s %s: invalid synthetic response", method, path)
			}
		}
	}
	post := func(path, token string, body any, want int, out any) {
		call("POST", path, token, body, want, out)
	}

	login := uuid.NewString()
	const password = "fixture-password-only"
	adminID, err := adminops.Provision(ctx, s.db, login, password, "super_admin")
	if err != nil {
		t.Fatal("could not provision the synthetic super admin")
	}
	var session struct {
		AccessToken string `json:"access_token"`
	}
	post("/admin/v1/auth/login", "", map[string]any{"login": login, "password": password}, 200, &session)

	ticket := uuid.NewString()
	if err := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err(); err != nil {
		t.Fatal("could not issue the synthetic app login proof")
	}
	var user app.Tokens
	post("/v1/auth/login", "", map[string]any{
		"credential":    map[string]string{"provider": "apple", "proof": ticket},
		"age_confirmed": true,
		"terms_version": "2026-11",
		"privacy_version": "2026-11",
	}, 200, &user)
	call("PUT", "/v1/me/consents/"+accounts.ReplyChatImportPurpose, user.AccessToken, map[string]any{
		"version": accounts.ReplyChatImportVersion,
		"granted": true,
	}, 200, nil)
	decision := replyFixtureDecision(t, s, user, accounts.ReplyChatImportPurpose, accounts.ReplyChatImportVersion)

	reply := func(chat string) {
		t.Helper()
		raw, err := json.Marshal(map[string]any{
			"request_id":       uuid.New(),
			"chat_text":        chat,
			"reply_consent_id": *decision,
		})
		if err != nil {
			t.Fatal(err)
		}
		req, err := http.NewRequest("POST", api.URL+"/v1/replies", bytes.NewReader(raw))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Authorization", "Bearer "+user.AccessToken)
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			t.Fatal("synthetic App call failed")
		}
		defer resp.Body.Close()
		if resp.StatusCode != 200 {
			var problem struct {
				Code string `json:"code"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&problem)
			wireMu.Lock()
			dispatches := len(wire)
			wireMu.Unlock()
			t.Fatalf("synthetic App call: app_status=%d code=%s upstream_dispatches=%d", resp.StatusCode, problem.Code, dispatches)
		}
	}
	business := func() []string {
		wireMu.Lock()
		defer wireMu.Unlock()
		var out []string
		for _, name := range wire {
			if name != review {
				out = append(out, name)
			}
		}
		return out
	}

	const chat = "甲乙丙丁戊己庚辛壬癸"
	reply(chat)
	if got := business(); len(got) != 1 || got[0] != modelOne {
		t.Fatalf("first App call did not use the configured primary model")
	}

	flutter, err := exec.LookPath("flutter")
	if err != nil {
		t.Fatal("Flutter SDK is required on PATH")
	}
	adminDir, err := filepath.Abs(filepath.Join("..", "..", "..", "admin"))
	if err != nil {
		t.Fatal("could not resolve the admin workspace")
	}
	pageTest := filepath.Join("tool", "t14", "models_next_call_live_test.dart")
	if info, err := os.Stat(filepath.Join(adminDir, pageTest)); err != nil || !info.Mode().IsRegular() {
		t.Fatal("T14 Flutter page check is missing")
	}
	runCtx, cancel := context.WithTimeout(ctx, 6*time.Minute)
	defer cancel()
	receipt := filepath.Join(t.TempDir(), "route-saved")
	cmd := exec.CommandContext(runCtx, flutter, "test", "--no-pub", "-r", "expanded", pageTest)
	cmd.Dir = adminDir
	cmd.Env = append(os.Environ(),
		"T14_ADMIN_ORIGIN="+api.URL,
		"T14_ADMIN_TOKEN="+session.AccessToken,
		"T14_PRIMARY_MODEL_ID="+one.String(),
		"T14_NEXT_MODEL_ID="+two.String(),
		"T14_NEXT_MODEL_NAME="+modelTwo,
		"T14_NEXT_MODEL_LABEL="+modelTwo+" · "+modelTwo,
		"T14_SAVE_RECEIPT="+receipt,
	)
	var output bytes.Buffer
	cmd.Stdout, cmd.Stderr = &output, &output
	if err := cmd.Run(); err != nil {
		t.Fatalf("T14 Flutter /models page stopped the flow (exit=%v): %s", err, t14Redact(output.String(), session.AccessToken, api.URL, ticket))
	}
	receiptData, err := os.ReadFile(receipt)
	if err != nil || strings.TrimSpace(string(receiptData)) != "model="+two.String() {
		t.Fatalf("T14 Flutter /models page finished without saving the route")
	}

	var primary uuid.UUID
	if err := s.db.QueryRow(ctx, `select primary_model from model_routes where task='reply_suggestion'`).Scan(&primary); err != nil || primary != two {
		t.Fatal("the admin page did not persist the next primary model")
	}
	var saved, failed int
	if err := s.db.QueryRow(ctx, `select count(*) filter (where result='ok'), count(*) filter (where result<>'ok')
        from admin_audit_logs where actor_id=$1 and action='setRoute' and target='reply_suggestion'`, adminID).Scan(&saved, &failed); err != nil {
		t.Fatal("could not read the synthetic route audit")
	}
	if saved != 1 || failed != 0 {
		t.Fatalf("route save audit: ok=%d other=%d, want one successful save", saved, failed)
	}

	reply(chat)
	businessModels := business()
	if len(businessModels) != 2 || businessModels[0] != modelOne || businessModels[1] != modelTwo {
		t.Fatalf("next App call did not follow the page change: %d business dispatches", len(businessModels))
	}
	t.Logf("T14 page->next call: page_saves=1 audit_ok=1 business_models=%s", strings.Join(businessModels, ","))
}

// t14Redact keeps a bounded diagnostic tail without fixture secrets, tokens,
// loopback origins or full request/response payloads.
func t14Redact(output, token, origin, ticket string) string {
	output = strings.ReplaceAll(output, token, "[redacted]")
	output = strings.ReplaceAll(output, ticket, "[redacted]")
	output = strings.ReplaceAll(output, origin, "[redacted]")
	if len(output) > 4000 {
		output = output[len(output)-4000:]
	}
	return output
}
