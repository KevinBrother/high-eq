package gateway

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
)

type localTransport func(*http.Request) (*http.Response, error)

func (f localTransport) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

// Exercise the real JSON/SSE encoder and decoder without opening a listening socket.
func TestRoutedJSONWireAndPrivateStats(t *testing.T) {
	p, b, m := endpoint{id: uuid.New()}, endpoint{id: uuid.New()}, endpoint{id: uuid.New()}
	scope := Scope{User: uuid.New(), Operation: uuid.New(), PromptVersion: uuid.New()}
	attempts := 0
	reviews := 0
	a := compatible{noRedirect(localTransport(func(req *http.Request) (*http.Response, error) {
		var body struct {
			Model   string
			Stream  bool
			Options map[string]bool   `json:"stream_options"`
			Format  map[string]string `json:"response_format"`
		}
		defer req.Body.Close()
		if err := json.NewDecoder(req.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		if body.Model == m.id.String() {
			reviews++
			if body.Stream || body.Options != nil {
				t.Fatal("incorrect moderation wire mode")
			}
			fmt.Fprint(w, `{"choices":[{"message":{"content":"{\"verdict\":\"allow\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1}}`)
		} else {
			attempts++
			if !body.Stream || body.Format["type"] != "json_object" || !body.Options["include_usage"] {
				t.Fatal("incorrect generation wire mode")
			}
			if body.Model == p.id.String() {
				w.WriteHeader(503)
				fmt.Fprint(w, "private upstream error")
			} else {
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"{\\\"ok\\\":true}\"},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}\n\ndata: [DONE]\n\n")
			}
		}
		return w.Result(), nil
	}))}
	r := Router{first: time.Second, total: time.Second, review: time.Second, load: func(context.Context, Call) (plan, error) { return plan{primary: p, backup: b, moderator: m}, nil }, dispatch: func(ctx context.Context, _ uuid.UUID, e endpoint, k Kind, r Request) (Result, error) {
		r.includeUsage = k == Model
		return a.chat(ctx, target{"https://synthetic.invalid", e.id.String(), "test-only"}, r)
	}, stop: func(context.Context, Scope, Terminal) error { t.Fatal("unexpected stop"); return nil }}
	records := 0
	r.record = func(_ context.Context, c Call, s attemptStat) error {
		records++
		if c.Messages != nil || c.Emit != nil || s.usage.Text != "" || len(s.usage.Object) > 0 || c.Operation != scope.Operation {
			t.Fatal("unsafe statistics")
		}
		if s.model.id != m.id && c.PromptVersion != scope.PromptVersion {
			t.Fatal("version lost")
		}
		if s.model.id == b.id && (s.outcome != "ok" || !s.usage.UsageKnown || s.usage.InputTokens != 4 || s.usage.OutputTokens != 2) {
			t.Fatal("lost usage")
		}
		return nil
	}
	out, err := r.Run(context.Background(), Call{Scope: scope, Task: Classification, Mode: JSONObject, Messages: []Message{{"user", "合成私密输入"}}})
	if err != nil || string(out.Result.Object) != `{"ok":true}` || out.CallID == uuid.Nil || attempts != 2 || reviews != 2 || records != 4 {
		t.Fatalf("attempts=%d reviews=%d records=%d err=%v", attempts, reviews, records, err)
	}
}

// A provider can bill a malformed verdict. Keep its usage, never the verdict body.
func TestRejectedReviewRetainsReportedUsage(t *testing.T) {
	a := compatible{noRedirect(localTransport(func(req *http.Request) (*http.Response, error) {
		defer req.Body.Close()
		w := httptest.NewRecorder()
		fmt.Fprint(w, `{"choices":[{"message":{"content":"invalid fixture"},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":2}}`)
		return w.Result(), nil
	}))}
	res, err := a.chat(context.Background(), target{"https://synthetic.invalid", "review", "fixture"}, Request{Mode: JSONObject, Messages: []Message{{"user", "合成输入"}}})
	if err != ErrProvider || !res.UsageKnown || res.InputTokens != 9 || res.OutputTokens != 2 || len(res.Object) != 0 || res.Text != "" {
		t.Fatal("failed review lost reported usage or retained rejected content")
	}
}
