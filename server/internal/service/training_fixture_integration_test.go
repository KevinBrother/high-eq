//go:build integration || t20live

package service

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/adminops"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/prompts"
	"high-eq/server/internal/scoring"
	"high-eq/server/internal/training"
)

// Socket-to-socket fixture: actual Gin, auth, T06, T09/T10/T11/T12 and DBs.
// No fake Runner. The only scripted components are the two remote providers.
type upstreamCase struct {
	mode          string
	hold          <-chan struct{}
	reviewHold    <-chan struct{}
	reviewStarted chan struct{}
}
type practiceWireFailureReporter func(t *testing.T, stage string, err error)

type practiceWire struct {
	t                   *testing.T
	reportFailure       practiceWireFailureReporter
	s                   *Runtime
	api                 *httptest.Server
	ctx                 context.Context
	mode                atomic.Pointer[upstreamCase]
	generations, grades atomic.Int32
	primaryModel        uuid.UUID
	fallbackModel       uuid.UUID
	promptVersions      map[admin.Task]uuid.UUID
	captureMu           sync.Mutex
	lastSystem          string
	lastUser            string
}

func (h *practiceWire) must(e error) {
	h.t.Helper()
	h.mustAt("operation", e)
}
func (h *practiceWire) mustAt(stage string, err error) {
	h.t.Helper()
	if err == nil {
		return
	}
	if h.reportFailure != nil {
		h.reportFailure(h.t, stage, err)
		return
	}
	h.t.Fatal(err)
}
func (h *practiceWire) exec(q string, a ...any) {
	h.t.Helper()
	_, e := h.s.db.Exec(h.ctx, q, a...)
	h.must(e)
}
func (h *practiceWire) number(q string, a ...any) int {
	h.t.Helper()
	var n int
	h.must(h.s.db.QueryRow(h.ctx, q, a...).Scan(&n))
	return n
}
func (h *practiceWire) set(mode string) { h.mode.Store(&upstreamCase{mode: mode}) }
func (h *practiceWire) hold() func() {
	ch := make(chan struct{})
	h.mode.Store(&upstreamCase{hold: ch})
	return func() { close(ch) }
}
func (h *practiceWire) holdReview() (<-chan struct{}, func()) {
	started, release := make(chan struct{}, 1), make(chan struct{})
	h.mode.Store(&upstreamCase{reviewStarted: started, reviewHold: release})
	return started, func() { close(release) }
}
func (h *practiceWire) vendor(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Model    string
		Messages []gateway.Message
		Format   map[string]string `json:"response_format"`
	}
	if json.NewDecoder(r.Body).Decode(&req) != nil || len(req.Messages) < 2 || r.URL.Path != "/chat/completions" {
		http.Error(w, "fixture mismatch", 400)
		return
	}
	c := h.mode.Load()
	last := req.Messages[len(req.Messages)-1].Content
	if req.Model == "moderator" {
		if c.reviewStarted != nil {
			select {
			case c.reviewStarted <- struct{}{}:
			default:
			}
		}
		if c.reviewHold != nil {
			select {
			case <-c.reviewHold:
			case <-r.Context().Done():
				return
			case <-time.After(8 * time.Second):
				return
			}
		}
		verdict := "allow"
		if c.mode == "preoutage" {
			http.Error(w, "fixture", 503)
			return
		}
		if last == "合成甲。合成乙。" || strings.HasPrefix(last, `{"safety_flag"`) {
			switch c.mode {
			case "safety":
				verdict = "crisis"
			case "outage":
				http.Error(w, "fixture", 503)
				return
			}
		}
		b, _ := json.Marshal(map[string]string{"verdict": verdict})
		json.NewEncoder(w).Encode(map[string]any{"choices": []any{map[string]any{"message": map[string]string{"content": string(b)}, "finish_reason": "stop"}}})
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	chunk := func(s, finish string) {
		b, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"delta": map[string]string{"content": s}, "finish_reason": finish}}})
		fmt.Fprintf(w, "data: %s\n\n", b)
		w.(http.Flusher).Flush()
	}
	if req.Format != nil {
		h.grades.Add(1)
		var material struct {
			Turns []struct {
				Role     string
				UserTurn int `json:"user_turn"`
			}
		}
		if json.Unmarshal([]byte(last), &material) != nil || len(material.Turns) == 0 {
			h.t.Error("missing source turns")
			return
		}
		n := 0
		for i, m := range material.Turns {
			if i%2 == 0 {
				n++
				if m.Role != "user" || m.UserTurn != n {
					h.t.Error("user order")
				}
			} else if m.Role != "assistant" || m.UserTurn != 0 {
				h.t.Error("assistant counted")
			}
		}
		score := `{"safety_flag":false,"mode":"express","nvc":{"observation":{"score":25,"reason":"合成"},"feeling":{"score":25,"reason":"合成"},"need":{"score":25,"reason":"合成"},"request":{"score":25,"reason":"合成"},"total":100},"emotion":{"read_others":{"level":3,"reason":"合成"},"self_management":{"level":3,"reason":"合成"},"relationship":{"level":3,"reason":"合成"}},"better_version":"周一聊吗？","why_better":"明确时间","target_turn":` + fmt.Sprint(n) + `}`
		if strings.Contains(req.Messages[0].Content, "指定类型：single_skill；唯一目标项：observation") {
			score = `{"target_item":"observation","score":15,"reason":"合成观察"}`
		}
		if c.mode == "first_score" && strings.Contains(score, `"nvc"`) {
			score = strings.ReplaceAll(score, `"score":25`, `"score":15`)
			score = strings.Replace(score, `"total":100`, `"total":60`, 1)
		}
		if c.mode == "second_score" && strings.Contains(score, `"target_item"`) {
			score = strings.Replace(score, `"score":15`, `"score":25`, 1)
		}
		if c.mode == "schema" {
			score = `{"bad":true}`
		}
		chunk(score, "stop")
	} else {
		h.generations.Add(1)
		h.captureMu.Lock()
		h.lastSystem = req.Messages[0].Content
		h.lastUser = req.Messages[1].Content
		h.captureMu.Unlock()
		chunk("合成甲。", "")
		if c.hold != nil {
			select {
			case <-c.hold:
			case <-r.Context().Done():
				return
			case <-time.After(8 * time.Second):
				return
			}
		}
		if c.mode == "partial" {
			return
		}
		chunk("合成乙。", "stop")
	}
	if c.mode == "cap" {
		fmt.Fprint(w, `data: {"choices":[],"usage":{"prompt_tokens":14990,"completion_tokens":10}}`+"\n\n")
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}
func newPracticeWire(t *testing.T) *practiceWire {
	t.Helper()
	return newPracticeWireWithContext(t, context.Background())
}

func newPracticeWireWithContext(t *testing.T, ctx context.Context) *practiceWire {
	t.Helper()
	return newPracticeWireWithContextAndFailureReporter(t, ctx, nil)
}

func newPracticeWireWithFailureReporter(t *testing.T, report practiceWireFailureReporter) *practiceWire {
	t.Helper()
	return newPracticeWireWithContextAndFailureReporter(t, context.Background(), report)
}

func newPracticeWireWithContextAndFailureReporter(t *testing.T, ctx context.Context, report practiceWireFailureReporter) *practiceWire {
	t.Helper()
	if os.Getenv("T19_DISPOSABLE") != "yes" && os.Getenv("T20_DISPOSABLE") != "yes" {
		t.Skip("run server/tests/t19-wire.sh in disposable compose project")
	}
	h := &practiceWire{t: t, ctx: ctx, reportFailure: report}
	h.set("")
	provider := h.startServer("listen_provider", http.HandlerFunc(h.vendor), true)
	t.Cleanup(provider.Close)
	old := http.DefaultTransport
	rt := old.(*http.Transport).Clone()
	roots := x509.NewCertPool()
	roots.AddCert(provider.Certificate())
	rt.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	http.DefaultTransport = rt
	t.Cleanup(func() { http.DefaultTransport = old; rt.CloseIdleConnections() })
	cfg, e := LoadConfig()
	h.mustAt("load_config", e)
	h.s, e = Start(h.ctx, cfg)
	h.mustAt("start_runtime", e)
	t.Cleanup(h.s.Close)
	var routes int
	h.mustAt("check_model_routes", h.s.db.QueryRow(h.ctx, `select count(*) from model_routes`).Scan(&routes))
	if routes != 0 {
		t.Fatal("requires empty disposable catalog")
	}
	execSetup := func(stage, query string, args ...any) {
		t.Helper()
		_, err := h.s.db.Exec(h.ctx, query, args...)
		h.mustAt(stage, err)
	}
	mk := func(kind gateway.Kind, name string) uuid.UUID {
		id := uuid.New()
		ref := id.String()
		execSetup("seed_provider_admission", `insert into provider_admissions(ref,provider,endpoint,model_scope,kind,purpose,sent_fields,processing_country,storage_country,cross_border,max_retention_days,deletion_method,terms_evidence) values($1,'t19',$2,'*',$3,'synthetic',ARRAY['model','messages.role','messages.content','stream','response_format.type','stream_options.include_usage'],'CN','CN',false,0,'fixture','fixture only')`, ref, provider.URL, kind)
		h.mustAt("seed_model", h.s.catalog.Save(h.ctx, gateway.Config{ID: id, Name: name, Provider: "t19", Endpoint: provider.URL, ModelName: name, AdmissionRef: ref, Protocol: "openai_compatible", Enabled: true, Kind: kind}, []byte("synthetic")))
		execSetup("seed_model_cost", `update model_configs set input_cny_per_million=0,output_cny_per_million=0 where id=$1`, id)
		return id
	}
	m, b, mod := mk(gateway.Model, "primary"), mk(gateway.Model, "fallback"), mk(gateway.Moderation, "moderator")
	// Release the fixture's global task routes before closing its runtime.
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, err := h.s.db.Exec(ctx, `delete from model_routes
			where task in ('role_play', 'scoring')
			  and primary_model=$1 and fallback_model=$2 and moderation_model=$3`, m, b, mod)
		if err != nil {
			t.Errorf("clean up practice model routes: %v", err)
		}
	})
	h.primaryModel = m
	h.fallbackModel = b
	h.promptVersions = make(map[admin.Task]uuid.UUID)
	for _, task := range []admin.Task{"role_play", "scoring"} {
		execSetup("seed_model_route", `insert into model_routes(task,primary_model,fallback_model,moderation_model)values($1,$2,$3,$4)`, task, m, b, mod)
		h.mustAt("seed_"+string(task)+"_prompt", pgx.BeginFunc(h.ctx, h.s.db, func(tx pgx.Tx) error {
			var v admin.PromptVersion
			if task == "role_play" {
				var seed string
				if e := tx.QueryRow(h.ctx, `select id,template from prompt_versions where task='role_play' and id='19000000-1000-4000-8000-000000000001'`).Scan(&v.Id, &seed); e != nil {
					return e
				}
				if seed != training.Seed() {
					return fmt.Errorf("seed diverged")
				}
			} else {
				var e error
				v, e = prompts.Create(h.ctx, tx, admin.CreatePromptVersionJSONBody{Task: task, Template: scoring.Seed()})
				if e != nil {
					return e
				}
			}
			h.promptVersions[task] = v.Id
			for _, id := range []uuid.UUID{m, b} {
				if e := prompts.Publish(h.ctx, tx, admin.PromptRelease{Task: task, ModelId: id, PrimaryVersionId: v.Id}); e != nil {
					return e
				}
			}
			return nil
		}))
	}
	h.api = h.startServer("listen_api", h.s.Router(), false)
	t.Cleanup(h.api.Close)
	return h
}

func (h *practiceWire) startServer(stage string, handler http.Handler, tls bool) *httptest.Server {
	h.t.Helper()
	// httptest's constructors panic with the raw bind error. Report it at the
	// fixture boundary while keeping httptest's IPv4 and IPv6 loopback choices.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		listener, err = net.Listen("tcp6", "[::1]:0")
	}
	h.mustAt(stage, err)
	server := &httptest.Server{Listener: listener, Config: &http.Server{Handler: handler}}
	if tls {
		server.StartTLS()
	} else {
		server.Start()
	}
	return server
}
func (h *practiceWire) open(tok, method, path string, in any, status int) *http.Response {
	h.t.Helper()
	resp, e := h.request(tok, method, path, in)
	h.must(e)
	if resp.StatusCode != status {
		resp.Body.Close()
		h.t.Fatalf("%s %s: got %d want %d", method, path, resp.StatusCode, status)
	}
	return resp
}
func (h *practiceWire) request(tok, method, path string, in any) (*http.Response, error) {
	b, _ := json.Marshal(in)
	req, e := http.NewRequestWithContext(h.ctx, method, h.api.URL+"/v1/"+path, bytes.NewReader(b))
	if e != nil {
		return nil, e
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	return (&http.Client{Timeout: 20 * time.Second}).Do(req)
}

func (h *practiceWire) adminRequest(tok, method, path string, in any) (*http.Response, error) {
	b, _ := json.Marshal(in)
	base := h.api.URL + "/admin/v1/"
	for strings.HasPrefix(path, "/") {
		path = strings.TrimPrefix(path, "/")
	}
	req, e := http.NewRequest(method, base+path, bytes.NewReader(b))
	if e != nil {
		return nil, e
	}
	if tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	return (&http.Client{Timeout: 20 * time.Second}).Do(req)
}

func (h *practiceWire) admin(tok, method, path string, in any, status int, out any) {
	h.t.Helper()
	r, e := h.adminRequest(tok, method, path, in)
	h.must(e)
	defer r.Body.Close()
	if r.StatusCode != status {
		raw, _ := io.ReadAll(r.Body)
		h.t.Fatalf("%s %s: got %d want %d: %s", method, path, r.StatusCode, status, raw)
	}
	if out != nil {
		h.must(json.NewDecoder(r.Body).Decode(out))
	}
}

func (h *practiceWire) adminLogin() string {
	h.t.Helper()
	login := uuid.NewString()
	const password = "fixture-password-only"
	_, e := adminops.Provision(h.ctx, h.s.db, login, password, "operator")
	h.must(e)
	var auth admin.AdminSession
	h.admin("", "POST", "auth/login", admin.AdminLoginJSONBody{Login: login, Password: password}, 200, &auth)
	return auth.AccessToken
}
func (h *practiceWire) json(tok, method, path string, in any, status int, out any) {
	h.t.Helper()
	r := h.open(tok, method, path, in, status)
	defer r.Body.Close()
	if out != nil {
		h.must(json.NewDecoder(r.Body).Decode(out))
	}
}
func (h *practiceWire) user() app.Tokens {
	ticket := uuid.NewString()
	h.must(h.s.cache.Set(h.ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err())
	var u app.Tokens
	h.json("", "POST", "auth/login", map[string]any{"credential": map[string]string{"provider": "apple", "proof": ticket}, "age_confirmed": true, "terms_version": "2026-11", "privacy_version": "2026-11"}, 200, &u)
	h.json(u.AccessToken, "PUT", "me/consents/practice", map[string]any{"version": "v1", "granted": true}, 200, nil)
	return u
}
func (h *practiceWire) assessmentUser() app.Tokens {
	u := h.user()
	h.json(u.AccessToken, "PUT", "me/consents/assessment", map[string]any{"version": "v1", "granted": true}, 200, nil)
	return u
}
func (h *practiceWire) logout(u app.Tokens) {
	h.json(u.AccessToken, "POST", "auth/logout", map[string]string{"refresh_token": u.RefreshToken}, 200, nil)
}
func (h *practiceWire) create(u app.Tokens, level int) string {
	id := uuid.NewString()
	in := map[string]any{"request_id": id}
	if level == 0 {
		in["scene"] = "work"
		in["scenario"] = "合成会议"
	} else {
		in["level_id"] = fmt.Sprintf("19000000-0000-4000-8000-%012d", level)
	}
	var v training.Session
	h.json(u.AccessToken, "POST", "sessions", in, 200, &v)
	if v.ID.String() != id {
		h.t.Fatal("request id")
	}
	h.json(u.AccessToken, "POST", "sessions", in, 200, &v)
	return "sessions/" + id
}
func (h *practiceWire) createLevel(u app.Tokens, level uuid.UUID) string {
	id := uuid.NewString()
	in := map[string]any{"request_id": id, "level_id": level}
	var v training.Session
	h.json(u.AccessToken, "POST", "sessions", in, 200, &v)
	if v.ID.String() != id {
		h.t.Fatal("request id")
	}
	h.json(u.AccessToken, "POST", "sessions", in, 200, &v)
	return "sessions/" + id
}
func (h *practiceWire) history(u app.Tokens, path string) training.Session {
	var v training.Session
	h.json(u.AccessToken, "GET", path, nil, 200, &v)
	return v
}
func body(k string) map[string]string {
	return map[string]string{"client_message_id": k, "text": "这是合成练习"}
}
func (h *practiceWire) stream(u app.Tokens, path, k string) *http.Response {
	r := h.open(u.AccessToken, "POST", path+"/messages", body(k), 200)
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "text/event-stream") {
		h.t.Fatal("not SSE")
	}
	return r
}
func (h *practiceWire) frames(u app.Tokens, path, k string, names ...string) {
	h.t.Helper()
	h.framesWithMessage(u, path, body(k), names...)
}

func (h *practiceWire) framesWithMessage(u app.Tokens, path string, message map[string]string, names ...string) {
	h.t.Helper()
	r := h.open(u.AccessToken, "POST", path+"/messages", message, 200)
	defer r.Body.Close()
	if !strings.HasPrefix(r.Header.Get("Content-Type"), "text/event-stream") {
		h.t.Fatal("not SSE")
	}
	sc := bufio.NewScanner(r.Body)
	i := 0
	for sc.Scan() {
		line := sc.Text()
		if line == "" {
			continue
		}
		if i >= len(names) || line != "event: "+names[i] || !sc.Scan() {
			h.t.Fatal("unexpected SSE event sequence", i, line)
		}
		var v map[string]any
		if !strings.HasPrefix(sc.Text(), "data: ") || json.Unmarshal([]byte(strings.TrimPrefix(sc.Text(), "data: ")), &v) != nil {
			h.t.Fatal("invalid SSE payload")
		}
		switch names[i] {
		case "safety":
			if v["safety"] != true || v["message"] != gateway.HelpMessage {
				h.t.Fatal("unsafe crisis frame")
			}
		case "moderation_unavailable":
			if v["retryable"] != true || v["message"] != gateway.UnavailableMessage {
				h.t.Fatal("wrong outage frame")
			}
		default:
			if v["client_message_id"] != message["client_message_id"] {
				h.t.Fatal("wrong client id")
			}
		}
		i++
	}
	h.must(sc.Err())
	if i != len(names) {
		h.t.Fatalf("got %d events want %d", i, len(names))
	}
}
func (h *practiceWire) send(u app.Tokens, path string) {
	h.frames(u, path, uuid.NewString(), "fragment", "fragment", "reply_saved")
}
func first(h *practiceWire, r *http.Response) {
	h.t.Helper()
	rd := bufio.NewReader(r.Body)
	line, e := rd.ReadString('\n')
	h.must(e)
	if line != "event: fragment\n" {
		h.t.Fatal("missing first fragment")
	}
	for i := 0; i < 2; i++ {
		_, e = rd.ReadString('\n')
		h.must(e)
	}
}
