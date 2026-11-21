package gateway

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime"
	"net/http"
	"strings"
	"time"
)

const maxReply = 4 << 20

type compatible struct{ client *http.Client }

// Never forward the authorization header OR message body to a redirect target.
func noRedirect(rt http.RoundTripper) *http.Client {
	return &http.Client{Transport: rt, Timeout: 60 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}
func builtinAdapters() map[string]adapter {
	rt := http.DefaultTransport.(*http.Transport).Clone()
	rt.Proxy = nil
	return map[string]adapter{"openai_compatible": compatible{noRedirect(rt)}}
}

type completion struct {
	Choices []struct {
		Message, Delta struct {
			Content *string `json:"content"`
		}
		Finish string `json:"finish_reason"`
	}
	Usage *struct {
		Input  *int `json:"prompt_tokens"`
		Output *int `json:"completion_tokens"`
	}
	Error json.RawMessage
}

func (a compatible) chat(ctx context.Context, t target, r Request) (Result, error) {
	body := struct {
		Model    string            `json:"model"`
		Messages []Message         `json:"messages"`
		Stream   bool              `json:"stream,omitempty"`
		Options  map[string]bool   `json:"stream_options,omitempty"`
		Format   map[string]string `json:"response_format,omitempty"`
	}{Model: t.model, Messages: r.Messages, Stream: r.Mode == Stream}
	if body.Stream && r.includeUsage {
		body.Options = map[string]bool{"include_usage": true}
	}
	if r.Mode == JSONObject || r.jsonStream {
		body.Format = map[string]string{"type": "json_object"}
	}
	data, err := json.Marshal(body)
	if err != nil {
		return Result{}, ErrRequest
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(t.endpoint, "/")+"/chat/completions", bytes.NewReader(data))
	if err != nil {
		return Result{}, ErrConfig
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+t.key)
	res, err := a.client.Do(req)
	if err != nil {
		if ctx.Err() != nil {
			return Result{}, ctx.Err()
		}
		return Result{}, ErrProvider
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return Result{}, ErrProvider
	}
	if r.Mode == Stream {
		ct, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
		if ct != "text/event-stream" {
			return Result{}, ErrProvider
		}
		return readStream(res.Body, r.OnDelta)
	}
	raw, err := io.ReadAll(io.LimitReader(res.Body, maxReply+1))
	var out completion
	if err != nil || len(raw) > maxReply || json.Unmarshal(raw, &out) != nil {
		return Result{}, ErrProvider
	}
	result := out.usageResult()
	if len(out.Error) != 0 || len(out.Choices) != 1 {
		return result, ErrProvider
	}
	choice := out.Choices[0]
	if choice.Finish != "stop" || choice.Message.Content == nil {
		return result, ErrProvider
	}
	text := *choice.Message.Content
	if r.Mode == JSONObject {
		obj := bytes.TrimSpace([]byte(text))
		if len(obj) == 0 || obj[0] != '{' || !json.Valid(obj) {
			return result, ErrProvider
		}
		result.Object = obj
	} else {
		result.Text = text
	}
	return result, nil
}

func (c completion) usageResult() Result {
	if c.Usage == nil || c.Usage.Input == nil || c.Usage.Output == nil || *c.Usage.Input < 0 || *c.Usage.Output < 0 {
		return Result{}
	}
	return Result{InputTokens: *c.Usage.Input, OutputTokens: *c.Usage.Output, UsageKnown: true}
}

// Dispatch SSE events on blank lines, never treating EOF as a successful finish.
func readStream(body io.Reader, emit func(string) error) (Result, error) {
	scanner := bufio.NewScanner(io.LimitReader(body, maxReply+1))
	scanner.Buffer(make([]byte, 4096), maxReply)
	var event []string
	var result Result
	stopped := false
	for scanner.Scan() {
		line := scanner.Text()
		if line != "" {
			v, ok := strings.CutPrefix(line, "data:")
			if ok {
				event = append(event, strings.TrimPrefix(v, " "))
			}
			continue
		}
		if len(event) == 0 {
			continue
		}
		data := strings.Join(event, "\n")
		event = nil
		if data == "[DONE]" {
			if stopped {
				return result, nil
			}
			return result, ErrProvider
		}
		var chunk completion
		if json.Unmarshal([]byte(data), &chunk) != nil || len(chunk.Error) != 0 {
			return result, ErrProvider
		}
		if chunk.Usage != nil {
			result = chunk.usageResult()
		}
		if stopped && chunk.Usage != nil && chunk.Choices != nil && len(chunk.Choices) == 0 {
			continue
		}
		if stopped || len(chunk.Choices) != 1 {
			return result, ErrProvider
		}
		choice := chunk.Choices[0]
		if choice.Finish != "" && choice.Finish != "stop" {
			return result, ErrProvider
		}
		if p := choice.Delta.Content; p != nil && *p != "" {
			if err := emit(*p); err != nil {
				return result, err
			}
		}
		stopped = choice.Finish == "stop"
	}
	return result, ErrProvider
}
