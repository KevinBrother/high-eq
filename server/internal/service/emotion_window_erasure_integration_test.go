//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/privacy"
)

const windowEndpoint = "/v1/signal-windows"

func windowDeletePath(channel, at string) string {
	return windowEndpoint + "?" + url.Values{"channel": {channel}, "starts_at": {at}}.Encode()
}

type windowHTTPResult struct {
	status int
	body   []byte
	err    error
}

func windowHTTPRequest(ctx context.Context, server *httptest.Server, method, path, token string, body []byte) windowHTTPResult {
	req, err := http.NewRequestWithContext(ctx, method, server.URL+path, bytes.NewReader(body))
	if err != nil {
		return windowHTTPResult{err: err}
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := server.Client().Do(req)
	if err != nil {
		return windowHTTPResult{err: err}
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	return windowHTTPResult{status: res.StatusCode, body: raw, err: err}
}

func checkWindowHTTP(t *testing.T, result windowHTTPResult, status int, code string) {
	t.Helper()
	if result.err != nil || result.status != status {
		t.Fatalf("window HTTP = %d %s, error=%v, want %d", result.status, result.body, result.err, status)
	}
	if code != "" {
		var out app.Error
		if err := json.Unmarshal(result.body, &out); err != nil || out.Code != code {
			t.Fatalf("window HTTP error = %s, want code %s", result.body, code)
		}
		if status == http.StatusServiceUnavailable && !out.Retryable {
			t.Fatalf("pending window response must permit retry: %s", result.body)
		}
	}
}

// Run with disposable PostgreSQL and two independent Redis instances. The
// trigger forces a failure after the durable intent and ledger write.
func TestExactWindowDeletionHTTP(t *testing.T) {
	f := setupSignals(t)
	server := httptest.NewServer(f.s.Router())
	defer server.Close()
	a, b := f.user(), f.user()
	for _, u := range []app.Tokens{a, b} {
		f.member(u)
		f.consents(u.UserId)
	}
	ctx, cancel := context.WithTimeout(f.ctx, 30*time.Second)
	defer cancel()
	call := func(method, path, token string, body []byte, status int, code string) {
		t.Helper()
		checkWindowHTTP(t, windowHTTPRequest(ctx, server, method, path, token, body), status, code)
	}
	at := time.Now().UTC().Truncate(30 * time.Second).Add(-time.Minute)
	wireTime := at.Format(time.RFC3339)
	health, err := json.Marshal(synthetic(at, "health", false))
	f.must(err)
	voice, err := json.Marshal(synthetic(at, "voice", false))
	f.must(err)
	lossy := strings.TrimSuffix(wireTime, "Z") + ".0000000001Z"
	sameInstant := at.In(time.FixedZone("", 8*3600)).Format(time.RFC3339)
	deleteHealth := windowDeletePath("health", sameInstant)
	deleteVoice := windowDeletePath("voice", wireTime)

	call("POST", windowEndpoint, a.AccessToken, bytes.ReplaceAll(health, []byte(wireTime), []byte(lossy)), 400, "invalid_argument")
	call("POST", windowEndpoint, a.AccessToken, health, 200, "")
	call("DELETE", deleteHealth, b.AccessToken, nil, 404, "not_found")
	call("POST", windowEndpoint, a.AccessToken, voice, 200, "")
	call("POST", windowEndpoint, b.AccessToken, health, 200, "")
	call("DELETE", windowDeletePath("health", lossy), a.AccessToken, nil, 400, "invalid_argument")
	call("DELETE", windowDeletePath("health", wireTime)+"&starts_at=%ZZ", a.AccessToken, nil, 400, "invalid_argument")

	var root uuid.UUID
	f.must(f.s.db.QueryRow(ctx, `select purge_id from signal_windows where user_id=$1 and channel='health' and starts_at=$2`, a.UserId, at).Scan(&root))
	f.exec(`create function t35_window_reject_delete() returns trigger language plpgsql as $$
		begin
			if old.purge_id::text = TG_ARGV[0] then raise exception 'synthetic window cleanup failure'; end if;
			return old;
		end $$`)
	dropTrigger := func() {
		f.exec(`drop trigger if exists t35_window_reject_delete on signal_windows`)
	}
	t.Cleanup(func() {
		dropTrigger()
		f.exec(`drop function t35_window_reject_delete()`)
	})
	f.exec(`create trigger t35_window_reject_delete before delete on signal_windows
		for each row execute function t35_window_reject_delete('` + root.String() + `')`)
	call("DELETE", deleteHealth, a.AccessToken, nil, 500, "internal_error")
	var pending bool
	f.must(f.s.db.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1)`, root).Scan(&pending))
	if !pending {
		t.Fatal("cleanup failure lost the exact window's pending intent")
	}
	ledgerKey := "deleted:" + root.String()
	value, err := f.s.registryRedis.Get(ctx, ledgerKey).Result()
	f.must(err)
	deadline, err := f.s.registryRedis.PExpireTime(ctx, ledgerKey).Result()
	f.must(err)
	if value != "" || deadline.Milliseconds() < at.Add(privacy.SignalWindowRetention).UnixMilli() {
		t.Fatalf("ledger root should be empty and cover the upload deadline; expiry=%v", deadline)
	}
	call("DELETE", deleteVoice, a.AccessToken, nil, 503, "service_unavailable")
	call("POST", windowEndpoint, a.AccessToken, health, 503, "service_unavailable")
	dropTrigger()
	call("DELETE", deleteHealth, a.AccessToken, nil, 200, "")
	call("DELETE", deleteHealth, a.AccessToken, nil, 404, "not_found")

	call("POST", windowEndpoint, a.AccessToken, health, 409, "conflict")
	call("POST", windowEndpoint, a.AccessToken, bytes.ReplaceAll(health, []byte(wireTime), []byte(sameInstant)), 409, "conflict")
	changed, err := json.Marshal(synthetic(at, "health", true))
	f.must(err)
	call("POST", windowEndpoint, a.AccessToken, changed, 409, "conflict")
	call("POST", windowEndpoint, a.AccessToken, voice, 200, "")
	call("POST", windowEndpoint, b.AccessToken, health, 200, "")
	call("POST", windowEndpoint, a.AccessToken, mustWindowJSON(t, at.Add(-180*24*time.Hour), "health"), 400, "invalid_argument")

	// A pre-fix snapshot may contain the same logical window under an earlier
	// random root. Its ciphertext uses that root's AAD as a real snapshot would.
	restored := uuid.New()
	enc, err := f.s.Fields.Seal(health, []byte("window/"+a.UserId.String()+"/"+restored.String()))
	f.must(err)
	f.exec(`insert into signal_windows(user_id,channel,starts_at,purge_id,stats_enc) values($1,'health',$2,$3,$4)`, a.UserId, at, restored, enc)
	f.must(f.s.Data.Resume(ctx))
	var healthA, voiceA, healthB, remainsPending bool
	f.must(f.s.db.QueryRow(ctx, `select
		exists(select from signal_windows where user_id=$1 and channel='health' and starts_at=$3),
		exists(select from signal_windows where user_id=$1 and channel='voice' and starts_at=$3),
		exists(select from signal_windows where user_id=$2 and channel='health' and starts_at=$3),
		exists(select from pending_erasure where root_id=$4 or root_id=$5)`,
		a.UserId, b.UserId, at, root, restored).Scan(&healthA, &voiceA, &healthB, &remainsPending))
	if healthA || !voiceA || !healthB || remainsPending {
		t.Fatalf("after recovery: A health=%t, A voice=%t, B health=%t, pending=%t", healthA, voiceA, healthB, remainsPending)
	}
	if got := f.export(a.UserId); bytes.Contains(got, []byte(`"channel":"health"`)) || !bytes.Contains(got, []byte(`"channel":"voice"`)) {
		t.Fatalf("incorrect export after replay and recovery: %s", got)
	}
	call("POST", windowEndpoint, a.AccessToken, health, 409, "conflict")
}

func mustWindowJSON(t *testing.T, at time.Time, channel string) []byte {
	t.Helper()
	body, err := json.Marshal(synthetic(at, channel, false))
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestExactWindowDeletionRechecksAuthorityUnderLock(t *testing.T) {
	fixture := setupSignals(t)
	server := httptest.NewServer(fixture.s.Router())
	defer server.Close()
	for _, invalidate := range []string{"freeze", "outgoing session revoked"} {
		t.Run(invalidate, func(t *testing.T) {
			f := signalsFor(t, fixture.s, fixture.ctx)
			ctx, cancel := context.WithTimeout(f.ctx, 15*time.Second)
			defer cancel()
			a := f.user()
			f.member(a)
			f.consents(a.UserId)
			at := time.Now().UTC().Truncate(30 * time.Second).Add(-time.Minute)
			path := windowDeletePath("voice", at.Format(time.RFC3339))
			checkWindowHTTP(t, windowHTTPRequest(ctx, server, "POST", windowEndpoint, a.AccessToken, mustWindowJSON(t, at, "voice")), 200, "")
			p, err := f.s.Accounts.Parse(a.AccessToken)
			f.must(err)
			tx, err := f.s.db.Begin(ctx)
			f.must(err)
			defer tx.Rollback(context.Background())
			var pid int
			f.must(tx.QueryRow(ctx, `select pg_backend_pid() from users where id=$1 for update`, a.UserId).Scan(&pid))
			var root uuid.UUID
			f.must(tx.QueryRow(ctx, `select purge_id from signal_windows where user_id=$1 and channel='voice' and starts_at=$2`, a.UserId, at).Scan(&root))

			done := make(chan windowHTTPResult, 1)
			go func() { done <- windowHTTPRequest(ctx, server, "DELETE", path, a.AccessToken, nil) }()
			waitForWindowDeleteLock(t, ctx, f.s.db, pid)
			// The account change wins the lock after a root was visible. The
			// old request must neither register an intent nor touch the window.
			if invalidate == "freeze" {
				_, err = tx.Exec(ctx, `update users set closure_requested_at=clock_timestamp() where id=$1`, a.UserId)
			} else {
				_, err = tx.Exec(ctx, `delete from auth_sessions where user_id=$1 and id=$2`, a.UserId, p.Session)
			}
			f.must(err)
			f.must(tx.Commit(ctx))
			checkWindowHTTP(t, <-done, 401, "unauthenticated")
			var survives, pending bool
			f.must(f.s.db.QueryRow(ctx, `select exists(select from signal_windows where purge_id=$1), exists(select from pending_erasure where root_id=$1)`,
				root).Scan(&survives, &pending))
			if !survives || pending {
				t.Fatalf("invalidated request changed window state: survives=%t, pending=%t", survives, pending)
			}
			if n, err := f.s.registryRedis.Exists(ctx, "deleted:"+root.String()).Result(); err != nil || n != 0 {
				t.Fatalf("invalidated request wrote a deletion record: %d, %v", n, err)
			}
		})
	}
}

func TestExactWindowDeletionRechecksAuthorityAfterJournal(t *testing.T) {
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	fixture := setupSignalsWithConfig(t, cfg)
	for _, tc := range []struct {
		name, update string
	}{
		{"frozen account", `update users set closure_requested_at=clock_timestamp() where id=$1`},
		{"revoked session", `delete from auth_sessions where id=$1`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := signalsFor(t, fixture.s, fixture.ctx)
			ctx, cancel := context.WithTimeout(f.ctx, 15*time.Second)
			defer cancel()
			a := f.user()
			f.member(a)
			f.consents(a.UserId)
			at := time.Now().UTC().Truncate(30 * time.Second).Add(-time.Minute)
			f.call("POST", "signal-windows", a.AccessToken, synthetic(at, "health", false), 200, nil)
			var root uuid.UUID
			f.must(f.s.db.QueryRow(ctx, `select purge_id from signal_windows where user_id=$1 and channel='health' and starts_at=$2`,
				a.UserId, at).Scan(&root))
			p, err := f.s.Accounts.Parse(a.AccessToken)
			f.must(err)
			subject := a.UserId
			if tc.name == "revoked session" {
				subject = p.Session
			}

			// The router's coordinator alone uses this pool. The second
			// acquisition is after journal commit and before online cleanup.
			pool := f.s.db.Config()
			acquisitions := 0
			pool.PrepareConn = func(ctx context.Context, conn *pgx.Conn) (bool, error) {
				acquisitions++
				if acquisitions != 2 {
					return true, nil
				}
				return true, pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
					var pending bool
					if err := tx.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1) from users where id=$2 for update`,
						root, a.UserId).Scan(&pending); err != nil {
						return err
					}
					if !pending {
						return errors.New("test hook ran before the window intent committed")
					}
					_, err := tx.Exec(ctx, tc.update, subject)
					return err
				})
			}
			db, err := pgxpool.NewWithConfig(ctx, pool)
			f.must(err)
			defer db.Close()
			registry, err := privacy.NewRegistry([]string{"emotion"}, emotion.Hooks(f.s.Fields))
			f.must(err)
			online := &Runtime{
				Accounts: f.s.Accounts,
				Emotion:  f.s.Emotion,
				Data:     privacy.NewCoordinator(db, f.s.ledger, registry, privacy.WithWindowReplayKey(cfg.authMaster)),
			}
			server := httptest.NewServer(online.Router())
			defer server.Close()
			path := windowDeletePath("health", at.Format(time.RFC3339))
			checkWindowHTTP(t, windowHTTPRequest(ctx, server, "DELETE", path, a.AccessToken, nil), 401, "unauthenticated")
			var present, pending bool
			readState := func() {
				f.must(f.s.db.QueryRow(ctx, `select exists(select from signal_windows where purge_id=$1),
					exists(select from pending_erasure where root_id=$1)`, root).Scan(&present, &pending))
			}
			readState()
			if !present || !pending {
				t.Fatalf("online cleanup after authority change: row=%t pending=%t", present, pending)
			}
			f.must(f.s.Data.RetryPending(ctx))
			readState()
			if present || pending {
				t.Fatalf("maintenance did not converge: row=%t pending=%t", present, pending)
			}
		})
	}
}

func TestExactWindowDeletionAfterAccountSwitch(t *testing.T) {
	fixture := newDeletionHTTPFixture(t)
	f := signalsFor(t, fixture.Runtime, fixture.ctx)
	subject := uuid.NewString()
	a, b := f.user(), fixture.register(t, subject)
	f.member(a)
	f.consents(a.UserId)
	at := time.Now().UTC().Truncate(30 * time.Second).Add(-time.Minute)
	f.call("POST", "signal-windows", a.AccessToken, synthetic(at, "health", false), 200, nil)
	path := windowDeletePath("health", at.Format(time.RFC3339))

	server := httptest.NewServer(f.s.Router())
	defer server.Close()
	switchBody, err := json.Marshal(map[string]any{"credential": fixture.proof(t, subject)})
	f.must(err)
	result := windowHTTPRequest(f.ctx, server, "POST", "/v1/auth/switch", a.AccessToken, switchBody)
	checkWindowHTTP(t, result, 200, "")
	var switched app.Tokens
	f.must(json.Unmarshal(result.body, &switched))
	if switched.UserId != b.UserId {
		t.Fatalf("wrong switch target: %v", switched.UserId)
	}
	checkWindowHTTP(t, windowHTTPRequest(f.ctx, server, "DELETE", path, switched.AccessToken, nil), 404, "not_found")
	// Switching can keep the outgoing session valid for other clients.
	// Explicitly retire that session before retrying its in-flight request.
	logout, err := json.Marshal(map[string]string{"refresh_token": a.RefreshToken})
	f.must(err)
	checkWindowHTTP(t, windowHTTPRequest(f.ctx, server, "POST", "/v1/auth/logout", a.AccessToken, logout), 200, "")
	checkWindowHTTP(t, windowHTTPRequest(f.ctx, server, "DELETE", path, a.AccessToken, nil), 401, "unauthenticated")
	var present bool
	f.must(f.s.db.QueryRow(f.ctx, `select exists(select from signal_windows where user_id=$1 and channel='health' and starts_at=$2)`,
		a.UserId, at).Scan(&present))
	if !present {
		t.Fatal("account switch allowed deletion of the previous account's window")
	}
}

func waitForWindowDeleteLock(t *testing.T, ctx context.Context, db *pgxpool.Pool, pid int) {
	t.Helper()
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	for {
		var waiting bool
		if err := db.QueryRow(ctx, `select exists(select from pg_stat_activity where $1=any(pg_blocking_pids(pid)))`, pid).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal("window DELETE did not wait for the account lock")
		case <-tick.C:
		}
	}
}
