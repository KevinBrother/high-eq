//go:build integration && d13flutter

package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/replies"
)

const d13ReplyHostLimit = 240 * time.Second

const (
	d13ProfileStartedMarker = "profile-started"
	d13ProfileReleaseMarker = "profile-release"
	d13ContactDraft         = "合成关系人片段：对方说周三再确认计划。"
)

var (
	d13SensitiveAssignment   = regexp.MustCompile(`(?i)((?:d13_reply_ticket|d13_reply_origin|origin)\s*=\s*)\S+`)
	d13SensitiveBearer       = regexp.MustCompile(`(?i)(authorization\s*:\s*bearer\s+)\S+`)
	d13SensitiveJSONField    = regexp.MustCompile(`(?i)("(?:request_id|chat_text|ticket|access_token|refresh_token|proof)"\s*:\s*)"[^"]*"`)
	d13SensitiveURL          = regexp.MustCompile(`https?://[^\s"']+`)
	d13UUIDPattern           = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`)
	d13FlutterFirstException = regexp.MustCompile(`(?m)^D13_FLUTTER_FIRST_EXCEPTION stage=[a-z_/]+ api_status=([1-5][0-9]{2}|other)$`)
)

type d13ReplyStageBudgets struct {
	start      time.Duration
	fixture    time.Duration
	chatImport time.Duration
	flutter    time.Duration
	ledger     time.Duration
}

func defaultD13ReplyStageBudgets() d13ReplyStageBudgets {
	return d13ReplyStageBudgets{
		start:      30 * time.Second,
		fixture:    10 * time.Second,
		chatImport: 20 * time.Second,
		flutter:    140 * time.Second,
		ledger:     20 * time.Second,
	}
}

func (b d13ReplyStageBudgets) total() time.Duration {
	return b.start + b.fixture + b.chatImport + b.flutter + b.ledger
}

func (b d13ReplyStageBudgets) validate(hostLimit time.Duration) error {
	for name, value := range map[string]time.Duration{
		"start":       b.start,
		"fixture":     b.fixture,
		"chat_import": b.chatImport,
		"flutter":     b.flutter,
		"ledger":      b.ledger,
	} {
		if value <= 0 {
			return fmt.Errorf("D13 reply %s stage budget must be positive", name)
		}
	}
	const finishReserve = 20 * time.Second
	if total := b.total(); total+finishReserve > hostLimit {
		return fmt.Errorf("D13 reply stages use %s plus %s finish reserve, beyond the %s host limit", total, finishReserve, hostLimit)
	}
	return nil
}

// TestD13ReplyFlutter owns the ephemeral HTTP listener. The operator supplies
// empty disposable stores on explicit numeric loopback ports. Every stage has
// its own deadline so a stuck child process or database witness leaves a named
// stage instead of only the parent test name.
func TestD13ReplyFlutter(t *testing.T) {
	budgets := defaultD13ReplyStageBudgets()
	if err := budgets.validate(d13ReplyHostLimit); err != nil {
		t.Fatal(err)
	}
	pg := d13ReplyFixturePort(t, "D13_REPLY_PG_PORT")
	cache := d13ReplyFixturePort(t, "D13_REPLY_CACHE_PORT")
	ledger := d13ReplyFixturePort(t, "D13_REPLY_LEDGER_PORT")
	if cache == ledger {
		t.Fatal("the cache and ledger require separate disposable Redis instances")
	}
	key := bytes.Repeat([]byte{0x42}, 32)
	fields, err := fieldcrypt.New(1, map[uint32][]byte{1: key})
	if err != nil {
		t.Fatal(err)
	}
	databaseURL := "postgres://synthetic:synthetic@127.0.0.1:" + pg + "/postgres?sslmode=disable"
	hostCtx, cancelHost := context.WithTimeout(t.Context(), d13ReplyHostLimit)
	defer cancelHost()

	var s *Runtime
	if err := d13RunStage(hostCtx, t, "start", budgets.start, func(ctx context.Context) error {
		s, err = Start(ctx, Config{
			DatabaseURL:          databaseURL,
			DatabasePoolMaxConns: 4,
			Cache:                &redis.Options{Addr: net.JoinHostPort("127.0.0.1", cache)},
			Ledger:               &redis.Options{Addr: net.JoinHostPort("127.0.0.1", ledger)},
			Environment:          "development",
			BackupDays:           30,
			Fields:               fields,
			authMaster:           key,
		})
		return err
	}); err != nil {
		t.Fatalf("D13 start stage failed: %v", err)
	}
	defer s.Close()

	fixtureDir := t.TempDir()
	ticket := uuid.NewString()
	switchTicket := uuid.NewString()
	if err := d13RunStage(hostCtx, t, "fixture", budgets.fixture, func(ctx context.Context) error {
		for _, fixtureTicket := range []string{ticket, switchTicket} {
			if err := s.cache.Set(ctx, "dev:ticket:apple:"+fixtureTicket, uuid.NewString(), 4*time.Minute).Err(); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatalf("D13 fixture stage failed: %v", err)
	}

	var api *httptest.Server
	var replyDispatches, profileDispatches atomic.Int32
	if err := d13RunStage(hostCtx, t, "chat_import", budgets.chatImport, func(context.Context) error {
		// Use the real service's authorization closure at synthetic dispatch time.
		// The first two reply calls settle as moderation outages; the third is approved.
		s.Replies = replies.New(s.Accounts, s.Membership, s.Data, s.Fields, s.db, s.Bus, key, func(stop gateway.Stop) (replies.Runner, error) {
			return syntheticRun(func(ctx context.Context, req gateway.Call) (gateway.Reply, error) {
				if err := req.Authorize(ctx, nil, func(context.Context, pgx.Tx) error { return nil }); err != nil {
					return gateway.Reply{}, err
				}
				switch replyDispatches.Add(1) {
				case 1, 2:
					term := gateway.Terminal{}
					return gateway.Reply{Terminal: &term}, stop(ctx, req.Scope, term)
				case 3:
					const approved = `{"possible_feeling":"可能担心进度","possible_need":"想确认时间","suggestions":[{"style":"直接","text":"我周三发计划。","reason":"明确时间。"},{"style":"确认","text":"你希望先看计划吗？","reason":"给出选择。"}]}`
					return gateway.Reply{CallID: uuid.New(), Result: gateway.Result{Object: []byte(approved)}}, nil
				default:
					return gateway.Reply{}, errors.New("unexpected extra reply dispatch")
				}
			}), nil
		})
		s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			if call.Task != gateway.ProfileInference || call.Mode != gateway.JSONObject || call.Emit != nil || len(call.Messages) != 1 || call.Messages[0].Content != d13ContactDraft {
				return gateway.Reply{}, errors.New("unexpected profile inference dispatch")
			}
			dispatch := profileDispatches.Add(1)
			if dispatch > 2 {
				return gateway.Reply{}, errors.New("unexpected extra profile dispatch")
			}
			if dispatch == 1 {
				if err := os.WriteFile(filepath.Join(fixtureDir, d13ProfileStartedMarker), []byte("started"), 0o600); err != nil {
					return gateway.Reply{}, fmt.Errorf("write profile start marker: %w", err)
				}
				if err := d13WaitForFixtureMarker(ctx, fixtureDir, d13ProfileReleaseMarker); err != nil {
					return gateway.Reply{}, err
				}
			}
			guardErr := authorizeProfileDispatch(ctx, call, func(context.Context, pgx.Tx) error { return nil })
			if guardErr != nil {
				return gateway.Reply{}, guardErr
			}
			return gateway.Reply{Result: gateway.Result{Object: []byte(`{"choices":[1,1,1,1,1,1,0]}`)}}, nil
		})
		api = httptest.NewServer(s.Router())
		return nil
	}); err != nil {
		t.Fatalf("D13 chat_import stage failed: %v", err)
	}
	defer api.Close()

	if err := d13RunStage(hostCtx, t, "flutter", budgets.flutter, func(ctx context.Context) error {
		output := &d13TailBuffer{limit: 64 << 10}
		flutter := exec.CommandContext(ctx, "flutter", "test", "--no-pub", "-r", "expanded", "tool/d13/reply_consent_live_test.dart")
		flutter.WaitDelay = 5 * time.Second
		flutter.Dir = filepath.Join("..", "..", "..", "app")
		flutter.Env = append(flutter.Environ(),
			"D13_REPLY_ORIGIN="+api.URL,
			"D13_REPLY_TICKET="+ticket,
			"D13_REPLY_SWITCH_TICKET="+switchTicket,
			"D13_REPLY_FIXTURE_DIR="+fixtureDir,
		)
		flutter.Stdout, flutter.Stderr = output, output
		err := flutter.Run()
		tail := output.String()
		if first := d13FlutterFirstException.FindString(tail); first != "" {
			t.Log(first)
		}
		if err != nil {
			return fmt.Errorf("Flutter against Go service: %w; output tail: %s", err, d13FlutterFailureDetail(tail, 4096, api.URL, ticket, switchTicket))
		}
		return nil
	}); err != nil {
		t.Fatalf("D13 Flutter stage failed: %v", err)
	}
	if got := replyDispatches.Load(); got != 3 {
		t.Fatalf("authorized reply dispatches = %d, want 3", got)
	}
	if got := profileDispatches.Load(); got != 2 {
		t.Fatalf("authorized profile dispatches = %d, want 2", got)
	}
	if err := d13RunStage(hostCtx, t, "ledger", budgets.ledger, func(ctx context.Context) error {
		return verifyD13ReplyLedger(ctx, t, databaseURL)
	}); err != nil {
		t.Fatalf("D13 ledger stage failed: %v", err)
	}
}

func d13ReplyFixturePort(t *testing.T, name string) string {
	t.Helper()
	port, err := strconv.ParseUint(os.Getenv(name), 10, 16)
	if err != nil || port == 0 {
		t.Fatalf("%s must be the explicit port of a disposable loopback fixture", name)
	}
	return strconv.FormatUint(port, 10)
}

func TestD13ReplyStageBudgetsStayInsideHostLimit(t *testing.T) {
	if err := defaultD13ReplyStageBudgets().validate(d13ReplyHostLimit); err != nil {
		t.Fatal(err)
	}
}

func TestD13ReplyStageDeadlineKeepsChildDetail(t *testing.T) {
	err := d13RunStage(context.Background(), t, "flutter", 20*time.Millisecond, func(ctx context.Context) error {
		<-ctx.Done()
		return fmt.Errorf("Flutter against Go service: %w; output tail: D13_FLUTTER_STAGE stage=reply_stale_key result=start", ctx.Err())
	})
	if err == nil {
		t.Fatal("stage deadline unexpectedly returned no error")
	}
	for _, want := range []string{"exceeded", "D13_FLUTTER_STAGE stage=reply_stale_key result=start"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("stage deadline error %q does not contain %q", err, want)
		}
	}
}

func TestD13FlutterFailureTailIsBoundedAndRedacted(t *testing.T) {
	const origin = "http://127.0.0.1:41234"
	const ticket = "11111111-2222-4333-8444-555555555555"
	const requestID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	output := "safe-before\n" +
		"D13_REPLY_TICKET=" + ticket + "\n" +
		"origin=" + origin + "\n" +
		"Authorization: Bearer synthetic-secret-token\n" +
		`{"request_id":"` + requestID + `","chat_text":"synth private text"}` + "\n" +
		"safe-after\n"

	got := d13FlutterFailureDetail(output, 96, origin, ticket)
	if strings.Contains(got, ticket) || strings.Contains(got, origin) ||
		strings.Contains(got, requestID) || strings.Contains(got, "synthetic-secret-token") ||
		strings.Contains(got, "synth private text") {
		t.Fatalf("failure detail leaked fixture data: %q", got)
	}
	if len(got) > 96 {
		t.Fatalf("failure detail length = %d, want at most 96", len(got))
	}
	if !strings.Contains(got, "safe-after") {
		t.Fatalf("failure detail did not retain the useful tail: %q", got)
	}
}

func d13RunStage(parent context.Context, t *testing.T, name string, budget time.Duration, run func(context.Context) error) error {
	t.Helper()
	ctx, cancel := context.WithTimeout(parent, budget)
	defer cancel()

	started := time.Now()
	err := run(ctx)
	result := "pass"
	if err != nil {
		result = "fail"
	}
	t.Logf("D13_REPLY_STAGE stage=%s result=%s duration_ms=%d", name, result, time.Since(started).Milliseconds())

	switch {
	case err == nil:
		return nil
	case errors.Is(parent.Err(), context.Canceled):
		return fmt.Errorf("D13 reply %s stage canceled before completion: %w", name, err)
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return fmt.Errorf("D13 reply %s stage exceeded %s: %w", name, budget, err)
	default:
		return fmt.Errorf("D13 reply %s stage: %w", name, err)
	}
}

// d13TailBuffer retains only the most recent bytes written by a child process.
// Flutter writes stdout and stderr from different goroutines, so writes are locked.
type d13TailBuffer struct {
	mu    sync.Mutex
	limit int
	tail  []byte
}

func (b *d13TailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	written := len(p)
	if b.limit <= 0 {
		return written, nil
	}
	if len(p) >= b.limit {
		b.tail = append(b.tail[:0], p[len(p)-b.limit:]...)
		return written, nil
	}
	if overflow := len(b.tail) + len(p) - b.limit; overflow > 0 {
		b.tail = append(b.tail[:0], b.tail[overflow:]...)
	}
	b.tail = append(b.tail, p...)
	return written, nil
}

func (b *d13TailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.tail)
}

func d13FlutterFailureDetail(output string, maxBytes int, origin string, tickets ...string) string {
	if maxBytes <= 0 {
		return ""
	}

	// Remove fixture identifiers and common secret-bearing shapes before taking
	// a tail. The child may echo request payloads or headers on failure.
	for _, ticket := range tickets {
		output = strings.ReplaceAll(output, ticket, "[redacted]")
	}
	output = strings.ReplaceAll(output, origin, "[redacted]")
	output = d13SensitiveBearer.ReplaceAllString(output, `${1}[redacted]`)
	output = d13SensitiveAssignment.ReplaceAllString(output, `${1}[redacted]`)
	output = d13SensitiveJSONField.ReplaceAllString(output, `${1}"[redacted]"`)
	output = d13UUIDPattern.ReplaceAllString(output, "[redacted]")
	output = d13SensitiveURL.ReplaceAllString(output, "[redacted]")

	if len(output) > maxBytes {
		output = output[len(output)-maxBytes:]
	}
	// A byte tail can begin in the middle of a UTF-8 sequence. Drop only the
	// incomplete prefix so logs stay valid without replacing useful content.
	for len(output) > 0 && !utf8.ValidString(output) {
		_, size := utf8.DecodeRuneInString(output)
		output = output[size:]
	}
	return output
}

func d13WaitForFixtureMarker(ctx context.Context, dir, name string) error {
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	path := filepath.Join(dir, name)
	for {
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect D13 fixture marker %s: %w", name, err)
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for D13 fixture marker %s: %w", name, ctx.Err())
		case <-ticker.C:
		}
	}
}
