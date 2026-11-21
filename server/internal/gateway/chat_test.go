package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestCompatibleChat(t *testing.T) {
	for _, mode := range []Mode{Text, Stream, JSONObject} {
		t.Run(string(mode), func(t *testing.T) {
			s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != "POST" || r.URL.Path != "/v1/chat/completions" || r.Header.Get("Authorization") != "Bearer fake-only" {
					t.Error("unexpected request")
				}
				var body map[string]any
				if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
					t.Error(err)
				}
				want := map[string]any{"model": "fixture", "messages": []any{map[string]any{"role": "user", "content": "虚构"}}}
				if mode == JSONObject {
					want["response_format"] = map[string]any{"type": "json_object"}
				}
				if mode == Stream {
					want["stream"] = true
				}
				if !reflect.DeepEqual(want, body) {
					t.Error("unexpected wire fields")
				}
				switch mode {
				case Text:
					fmt.Fprint(w, `{"choices":[{"message":{"content":"好"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":1}}`)
				case JSONObject:
					fmt.Fprint(w, `{"choices":[{"message":{"content":"{\"ok\":true}"},"finish_reason":"stop"}]}`)
				case Stream:
					w.Header().Set("Content-Type", "text/event-stream")
					for _, chunk := range []string{`{"choices":[{"delta":{"role":"assistant"}}]}`, `{"choices":[{"delta":{"content":"你"}}]}`, `{"choices":[{"delta":{"content":"好"},"finish_reason":"stop"}]}`, `{"choices":[],"usage":{"prompt_tokens":6,"completion_tokens":2}}`, `[DONE]`} {
						fmt.Fprintf(w, "data: %s\n\n", chunk)
						w.(http.Flusher).Flush()
					}
				}
			}))
			defer s.Close()
			a := compatible{client: noRedirect(s.Client().Transport)}
			var chunks []string
			req := Request{Mode: mode, Messages: []Message{{Role: "user", Content: "虚构"}}}
			if mode == Stream {
				req.OnDelta = func(s string) error { chunks = append(chunks, s); return nil }
			}
			out, err := a.chat(context.Background(), target{s.URL + "/v1", "fixture", "fake-only"}, req)
			if err != nil {
				t.Fatal(err)
			}
			switch mode {
			case Text:
				if out.Text != "好" || out.InputTokens != 4 || out.OutputTokens != 1 {
					t.Fatal("bad text or usage")
				}
			case JSONObject:
				if string(out.Object) != `{"ok":true}` {
					t.Fatal("bad object")
				}
			case Stream:
				if !reflect.DeepEqual(chunks, []string{"你", "好"}) || out.Text != "" || out.InputTokens != 6 || out.OutputTokens != 2 {
					t.Fatal("bad stream")
				}
			}
		})
	}
}
func TestCompatibleFailsClosed(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mode   Mode
		status int
		body   string
	}{
		{"upstream", Text, 400, "private-body"}, {"invalid JSON object", JSONObject, 200, `{"choices":[{"message":{"content":"[]"},"finish_reason":"stop"}]}`}, {"cut stream", Stream, 200, "data: {\"choices\":[{\"delta\":{\"content\":\"part\"}}]}\n\n"}, {"stream error", Stream, 200, "data: {\"error\":{\"message\":\"private-body\"}}\n\ndata: [DONE]\n\n"}, {"truncated text", Text, 200, `{"choices":[{"message":{"content":"part"},"finish_reason":"length"}]}`}} {
		t.Run(tc.name, func(t *testing.T) {
			s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if tc.mode == Stream {
					w.Header().Set("Content-Type", "text/event-stream")
				}
				w.WriteHeader(tc.status)
				io.WriteString(w, tc.body)
			}))
			defer s.Close()
			a := compatible{noRedirect(s.Client().Transport)}
			_, err := a.chat(context.Background(), target{s.URL, "fixture", "fake-only"}, Request{Mode: tc.mode, Messages: []Message{{"user", "private-input"}}, OnDelta: func(string) error { return nil }})
			if !errors.Is(err, ErrProvider) || strings.Contains(err.Error(), "private") {
				t.Fatalf("expected sanitized provider error")
			}
		})
	}
}
func TestNeverFollowRedirects(t *testing.T) {
	other := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Error("redirect contacted") }))
	defer other.Close()
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, other.URL, 307) }))
	defer s.Close()
	_, err := (compatible{noRedirect(s.Client().Transport)}).chat(context.Background(), target{s.URL, "fixture", "fake-only"}, Request{Mode: Text, Messages: []Message{{"user", "虚构"}}})
	if !errors.Is(err, ErrProvider) {
		t.Fatal("redirect not rejected")
	}
}

// The server deliberately never finishes: delivery must not wait for the full body,
// and stopping the consumer must close the upstream request.
func TestStreamBackpressureAndStop(t *testing.T) {
	closed := make(chan struct{})
	s := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(closed)
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n")
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stop := errors.New("stop consumer")
	a := compatible{noRedirect(s.Client().Transport)}
	_, err := a.chat(ctx, target{s.URL, "fixture", "fake-only"}, Request{Mode: Stream, Messages: []Message{{"user", "虚构"}}, OnDelta: func(delta string) error {
		if delta != "first" {
			t.Fatal("unexpected first chunk")
		}
		return stop
	}})
	if !errors.Is(err, stop) {
		t.Fatal("consumer was not able to stop live stream")
	}
	select {
	case <-closed:
	case <-ctx.Done():
		t.Fatal("upstream not canceled")
	}
}

func TestInvalidRequestNeverResolves(t *testing.T) {
	c := (&Catalog{}).ForTasks(Model, func(context.Context, string) (uuid.UUID, error) {
		t.Fatal("invalid request reached routing")
		return uuid.Nil, nil
	})
	for _, r := range []Request{{Mode: Text}, {Mode: Stream, Messages: []Message{{"user", "test"}}}, {Mode: JSONObject, Messages: []Message{{"tool", "test"}}}, {Mode: "unknown", Messages: []Message{{"user", "test"}}}} {
		if _, err := c.Chat(context.Background(), "scoring", r); !errors.Is(err, ErrRequest) {
			t.Fatal("invalid request accepted")
		}
	}
}
