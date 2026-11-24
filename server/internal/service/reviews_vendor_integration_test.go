//go:build integration || t24live

package service

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/prompts"
	"high-eq/server/internal/scoring"
)

const reviewScore = `{"safety_flag":false,"mode":"express","nvc":{"observation":{"score":15,"reason":"合成引文：我先说完"},"feeling":{"score":0,"reason":"未表达"},"need":{"score":0,"reason":"未说明"},"request":{"score":5,"reason":"没有给对方选择"},"total":20},"emotion":{"read_others":{"level":2,"reason":"没确认"},"self_management":{"level":3,"reason":"语气平稳"},"relationship":{"level":2,"reason":"可能引起误会"}},"better_version":"我想先核对时间，可以吗？","why_better":"说出需要","target_turn":1}`
const repairFixture = `{"repair_phrase":"刚才我打断了你，你愿意说完吗？"}`

type reviewUpstream struct {
	mode                         atomic.Int32
	analyses, scores             atomic.Int32
	entered, resume              chan struct{}
	outputEntered, releaseOutput chan struct{}
}

func (f *reviewUpstream) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var v struct {
			Model    string
			Stream   bool
			Messages []gateway.Message
		}
		if json.NewDecoder(r.Body).Decode(&v) != nil || len(v.Messages) != 2 {
			t.Error("invalid synthetic upstream call")
			w.WriteHeader(400)
			return
		}
		if !v.Stream {
			verdict := `{"verdict":"allow"}`
			if v.Messages[1].Content == reviewScore {
				switch f.mode.Load() {
				case 5:
					verdict = `{"verdict":"unknown"}`
				case 6:
					select {
					case f.outputEntered <- struct{}{}:
					default:
					}
					select {
					case <-f.releaseOutput:
					case <-r.Context().Done():
						return
					}
				}
			}
			if f.mode.Load() == 1 {
				verdict = `{"verdict":"crisis"}`
			}
			if f.mode.Load() == 2 && strings.Contains(v.Messages[1].Content, "full_review") {
				verdict = `{"verdict":"unknown"}`
			}
			fmt.Fprintf(w, `{"choices":[{"message":{"content":%q},"finish_reason":"stop"}]}`, verdict)
			return
		}
		var out string
		switch {
		case strings.Contains(v.Messages[0].Content, "full_review"):
			f.scores.Add(1)
			var m struct{ Turns []scoring.Turn }
			if json.Unmarshal([]byte(v.Messages[1].Content), &m) != nil || len(m.Turns) != 1 || m.Turns[0].Text != "我先说完" {
				t.Error("T12 received more than the reported action")
			}
			out = reviewScore
			if f.mode.Load() == 3 {
				out = `{"safety_flag":true}`
			}
			if f.mode.Load() == 4 {
				out = `{"partial":true}`
			}
		default:
			if f.analyses.Add(1) == 1 {
				close(f.entered)
				select {
				case <-f.resume:
				case <-r.Context().Done():
					return
				}
			}
			out = repairFixture
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n", out)
	})
}

// Only the TLS fixture socket is dialable. Production T09/T10 transport, moderation,
// SSE adapter, T11 versions and ai_calls are used, without any real vendor route.
func reviewRuntime(t *testing.T, f *reviewUpstream) *Runtime {
	t.Helper()
	return reviewRuntimeWithVendor(t, f.handler(t), nil)
}

func reviewRuntimeWithVendor(t *testing.T, handler http.Handler, extraPrompts map[admin.Task]uuid.UUID) *Runtime {
	t.Helper()
	s, _, _ := reviewRuntimeWithRestartableVendor(t, handler, extraPrompts)
	return s
}

func reviewRuntimeWithRestartableVendor(t *testing.T, handler http.Handler, extraPrompts map[admin.Task]uuid.UUID) (*Runtime, func() *Runtime, func()) {
	t.Helper()
	ctx := t.Context()
	vendor := httptest.NewTLSServer(handler)
	t.Cleanup(vendor.Close)
	roots := x509.NewCertPool()
	roots.AddCert(vendor.Certificate())
	transport := http.DefaultTransport.(*http.Transport).Clone()
	t.Cleanup(transport.CloseIdleConnections)
	transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	transport.DialContext = func(c context.Context, n, a string) (net.Conn, error) {
		if a != vendor.Listener.Addr().String() {
			return nil, errors.New("only synthetic endpoint is permitted")
		}
		return (&net.Dialer{}).DialContext(c, n, a)
	}
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	startRuntime := func() (*Runtime, func()) {
		t.Helper()
		old := http.DefaultTransport
		http.DefaultTransport = transport
		defer func() { http.DefaultTransport = old }()
		startCtx, cancel := context.WithTimeout(ctx, 20*time.Second)
		defer cancel()
		s, err := Start(startCtx, cfg)
		if err != nil {
			t.Fatal(err)
		}
		stop := sync.OnceFunc(s.Close)
		t.Cleanup(stop)
		return s, stop
	}
	s, stop := startRuntime()
	// No upserts over a pre-existing gateway route, even in a test DB.
	e = pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		ids := [3]uuid.UUID{uuid.New(), uuid.New(), uuid.New()}
		for i, id := range ids {
			kind := gateway.Model
			if i == 2 {
				kind = gateway.Moderation
			}
			_, e := tx.Exec(ctx, `insert into provider_admissions values($1,'t23',$2,'*',$3,'synthetic',ARRAY['model','messages.role','messages.content','stream','response_format.type'],'CN','CN',false,0,'discard','fixture')`, id.String(), vendor.URL, kind)
			if e != nil {
				return e
			}
			e = s.catalog.SaveTx(ctx, tx, gateway.Config{ID: id, Name: "fixture", Provider: "t23", Endpoint: vendor.URL, ModelName: "synthetic", AdmissionRef: id.String(), Protocol: "openai_compatible", Kind: kind, Enabled: true}, []byte("synthetic-key"))
			if e != nil {
				return e
			}
			if _, e = tx.Exec(ctx, `update model_configs set input_cny_per_million=0,output_cny_per_million=0 where id=$1`, id); e != nil {
				return e
			}
		}
		sv, e := prompts.Create(ctx, tx, admin.CreatePromptVersionJSONBody{Task: admin.TaskScoring, Template: scoring.Seed()})
		if e != nil {
			return e
		}
		versions := map[admin.Task]uuid.UUID{admin.TaskScoring: sv.Id, admin.TaskReviewAnalysis: uuid.MustParse("70df17a3-4acd-40ef-80e8-13f2b9579423")}
		for task, prompt := range extraPrompts {
			versions[task] = prompt
		}
		for task, prompt := range versions {
			if _, e = tx.Exec(ctx, `insert into model_routes(task,primary_model,fallback_model,moderation_model) values($1,$2,$3,$4)`, task, ids[0], ids[1], ids[2]); e != nil {
				return e
			}
			for _, id := range ids[:2] {
				if e = prompts.Publish(ctx, tx, admin.PromptRelease{Task: task, PrimaryVersionId: prompt, ModelId: id}); e != nil {
					return e
				}
			}
		}
		return nil
	})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		conn, err := pgx.Connect(ctx, cfg.DatabaseURL)
		if err != nil {
			t.Error(err)
			return
		}
		defer conn.Close(ctx)
		_, err = conn.Exec(ctx, `delete from model_routes where primary_model in(select id from model_configs where provider='t23' and endpoint=$1)`, vendor.URL)
		if err != nil {
			t.Error(err)
		}
	})
	start := func() *Runtime {
		t.Helper()
		runtime, _ := startRuntime()
		return runtime
	}
	return s, start, stop
}
