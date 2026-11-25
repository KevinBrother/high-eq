package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"os"
	osExec "os/exec"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/training"
)

type chatImportRow struct {
	Activity, Source uuid.UUID
	ReceivedAt       time.Time
	Expired          bool
}

type chatImportAccount struct {
	Tokens app.Tokens
	Rows   [2]chatImportRow
}

type chatImportFixture [2]chatImportAccount

const safeScenario = "synthetic approved practice setup"

func (r chatImportRow) original() []byte {
	return []byte("synthetic chat original " + r.Activity.String())
}

func seedChatImports() *chatImportFixture {
	enter(stageChatImportSeed)
	f := new(chatImportFixture)
	now := time.Now().UTC().Truncate(time.Microsecond)
	for i := range f {
		account := &f[i]
		var err error
		account.Tokens, err = login(uuid.NewString(), false)
		must(err)
		p, err := auth.Parse(account.Tokens.AccessToken)
		must(err)
		_, err = auth.Consent(ctx, p, "practice", "t34", true)
		must(err)
		for j, age := range [2]time.Duration{25 * time.Hour, time.Hour} {
			row := &account.Rows[j]
			scene, scenario := "work", safeScenario
			session, err := practice.Create(ctx, p, training.Input{
				ID: uuid.New(), Scene: &scene, Scenario: &scenario,
			})
			must(err)
			row.Activity, row.ReceivedAt, row.Expired = session.ID, now.Add(-age), j == 0
			must(db.QueryRow(ctx, `update activities set state='active' where id=$1 returning source_id`,
				row.Activity).Scan(&row.Source))
			exec(`insert into chat_imports(activity_id,received_at,original_enc) values($1,$2,$3)`,
				row.Activity, row.ReceivedAt, row.original())
		}
	}
	f.checkStored(true)
	return f
}

// Check the exact snapshot rows and ownership. During retries the absence of
// one expired row cannot hide a missing fresh row or a missing activity root.
func (f chatImportFixture) expiredRows() int {
	require(f[0].Tokens.UserId != uuid.Nil && f[1].Tokens.UserId != uuid.Nil)
	require(f[0].Tokens.UserId != f[1].Tokens.UserId)
	var expired int
	for _, account := range f {
		for j, row := range account.Rows {
			require(row.Activity != uuid.Nil && row.Source != uuid.Nil && row.Expired == (j == 0))
			require(row.Expired == !row.ReceivedAt.After(time.Now().Add(-24*time.Hour)))
			var source uuid.UUID
			var state string
			var original []byte
			var received *time.Time
			must(db.QueryRow(ctx, `
select a.source_id, a.state, c.received_at, c.original_enc
from activities a join practice_work w on w.activity_id=a.id
left join chat_imports c on c.activity_id=a.id where a.id=$1 and a.user_id=$2`,
				row.Activity, account.Tokens.UserId).Scan(&source, &state, &received, &original))
			require(source == row.Source && state == "active")
			if row.Expired && received == nil {
				continue
			}
			require(received != nil && received.Equal(row.ReceivedAt) && bytes.Equal(original, row.original()))
			if row.Expired {
				expired++
			}
		}
	}
	return expired
}

func (f chatImportFixture) checkStored(before bool) {
	enter(stageChatImportStored)
	expired := f.expiredRows()
	if before {
		require(expired == len(f))
	} else {
		require(expired == 0)
	}
}

func (f chatImportFixture) checkNoOriginal(body []byte) {
	for _, account := range f {
		for _, row := range account.Rows {
			raw := row.original()
			require(!bytes.Contains(body, raw))
			require(!bytes.Contains(body, []byte(base64.StdEncoding.EncodeToString(raw))))
		}
	}
}

// Record only the fixed startup retry signal. Child output stays private.
type cleanupLog struct{ retried atomic.Bool }

func (l *cleanupLog) Write(p []byte) (int, error) {
	if bytes.Contains(p, []byte(`"msg":"startup cleanup pending","module":"chat_imports","result":"retry"`)) {
		l.retried.Store(true)
	}
	return len(p), nil
}

func (f chatImportFixture) checkProcess(restored fixture) {
	f.checkStored(true)
	enter(stageChatImportProcess)
	lock, err := db.Begin(ctx)
	must(err)
	defer lock.Rollback(context.Background())
	// A SHARE lock lets the ready API read, while the startup DELETE times out.
	_, err = lock.Exec(ctx, `lock table chat_imports in share mode`)
	must(err)

	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	must(err)
	addr := listener.Addr().String()
	must(listener.Close())
	childCtx, stop := context.WithCancel(ctx)
	defer stop()
	child := osExec.CommandContext(childCtx, os.Getenv("T34_DRILL_API"))
	child.Env = append(os.Environ(), "LISTEN_ADDR="+addr)
	log := new(cleanupLog)
	child.Stdout = log
	must(child.Start())
	done := make(chan struct{})
	go func() {
		_ = child.Wait()
		close(done)
	}()
	defer func() { stop(); <-done }()

	transport := &http.Transport{}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	get := func(path, token string) (int, []byte) {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+addr+path, nil)
		must(err)
		if token != "" {
			request.Header.Set("Authorization", "Bearer "+token)
		}
		response, err := client.Do(request)
		if err != nil {
			return 0, nil
		}
		defer response.Body.Close()
		body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
		must(err)
		return response.StatusCode, body
	}
	wait := func(timeout time.Duration, ready func() bool) {
		deadline := time.NewTimer(timeout)
		defer deadline.Stop()
		tick := time.NewTicker(250 * time.Millisecond)
		defer tick.Stop()
		for !ready() {
			select {
			case <-tick.C:
			case <-done:
				fail(2)
			case <-deadline.C:
				fail(2)
			case <-ctx.Done():
				fail(2)
			}
		}
	}

	wait(30*time.Second, func() bool {
		code, body := get("/v1/health", "")
		return code == http.StatusOK && bytes.Equal(body, []byte(`{"ok":true}`)) && log.retried.Load()
	})
	f.checkStored(true)

	enter(stageChatImportRead)
	for _, check := range []struct {
		path, token string
		want        int
	}{
		{"/v1/reviews/" + restored.Activities[0].String(), restored.A.AccessToken, 404},
		{"/v1/me", restored.A.AccessToken, 200},
		{"/v1/me", restored.B.AccessToken, 401},
	} {
		code, _ := get(check.path, check.token)
		require(code == check.want)
	}
	for i, account := range f {
		for _, row := range account.Rows {
			path := "/v1/sessions/" + row.Activity.String()
			code, body := get(path, account.Tokens.AccessToken)
			require(code == http.StatusOK && bytes.Contains(body, []byte(safeScenario)))
			require(bytes.Contains(body, []byte(row.Activity.String())))
			f.checkNoOriginal(body)
			code, body = get(path, f[1-i].Tokens.AccessToken)
			require(code == http.StatusNotFound)
			f.checkNoOriginal(body)
		}
		enter(stageChatImportExport)
		body := export(account.Tokens.UserId)
		require(bytes.Contains(body, []byte(safeScenario)))
		f.checkNoOriginal(body)
		for _, row := range account.Rows {
			require(bytes.Contains(body, []byte(row.Activity.String())))
		}
		for _, row := range f[1-i].Rows {
			require(!bytes.Contains(body, []byte(row.Activity.String())))
		}
		enter(stageChatImportRead)
	}
	// Ensure the read/export assertions ran while every original was present.
	f.checkStored(true)
	enter(stageChatImportRetry)
	must(lock.Rollback(ctx))
	wait(80*time.Second, func() bool { return f.expiredRows() == 0 })
	f.checkStored(false)
	code, _ := get("/v1/health", "")
	require(code == http.StatusOK)
}
