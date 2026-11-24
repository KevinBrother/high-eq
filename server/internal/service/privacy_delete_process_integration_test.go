//go:build integration && process

package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/api/app"
)

const (
	t35FirstTickDeadline = 90 * time.Second
	t35NextTickWait      = 90 * time.Second
)

type t35ProcessAPI struct {
	t         *testing.T
	cmd       *exec.Cmd
	done      <-chan error
	baseURL   string
	startedAt time.Time
	stopOnce  sync.Once
}

func startT35ProcessAPI(t *testing.T, binary, address string) *t35ProcessAPI {
	t.Helper()
	cmd := exec.Command(binary)
	cmd.Env = replaceEnv(os.Environ(), "LISTEN_ADDR", address)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	startedAt := time.Now()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	api := &t35ProcessAPI{
		t:         t,
		cmd:       cmd,
		done:      done,
		baseURL:   "http://" + address,
		startedAt: startedAt,
	}
	deadline := time.Now().Add(30 * time.Second)
	for {
		if t35Healthy(api.baseURL) {
			return api
		}
		select {
		case err := <-done:
			t.Fatalf("real API process exited before becoming healthy: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			<-done
			t.Fatal("real API process did not become healthy")
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (a *t35ProcessAPI) stop() {
	a.t.Helper()
	a.stopOnce.Do(func() {
		if err := a.cmd.Process.Signal(os.Interrupt); err != nil && !errors.Is(err, os.ErrProcessDone) {
			a.t.Fatalf("stop real API process: %v", err)
		}
		select {
		case err := <-a.done:
			// Wait has already reaped the process and made ProcessState available.
			if err != nil {
				a.t.Fatalf("real API process stopped with %v", err)
			}
		case <-time.After(10 * time.Second):
			_ = a.cmd.Process.Kill()
			<-a.done
			a.t.Fatal("real API process did not stop")
		}
	})
}

func (a *t35ProcessAPI) requireAlive() {
	a.t.Helper()
	if err := a.cmd.Process.Signal(syscall.Signal(0)); err != nil {
		a.t.Fatalf("real API process pid %d is no longer alive: %v", a.cmd.Process.Pid, err)
	}
}

func replaceEnv(env []string, key, value string) []string {
	prefix := key + "="
	out := make([]string, 0, len(env)+1)
	for _, item := range env {
		if !strings.HasPrefix(item, prefix) {
			out = append(out, item)
		}
	}
	return append(out, prefix+value)
}

func freeT35Loopback(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := l.Addr().String()
	if err := l.Close(); err != nil {
		t.Fatal(err)
	}
	return address
}

func t35Healthy(baseURL string) bool {
	client := &http.Client{Timeout: time.Second}
	response, err := client.Get(baseURL + "/v1/health")
	if err != nil {
		return false
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	return err == nil && response.StatusCode == http.StatusOK && bytes.Contains(body, []byte(`"ok":true`))
}

func t35Listening(address string) bool {
	conn, err := net.DialTimeout("tcp", address, 100*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}

type t35HTTPDriver struct {
	t       *testing.T
	baseURL string
	client  *http.Client
}

func (d t35HTTPDriver) request(method, path, token string, body any, want int) []byte {
	d.t.Helper()
	var payload io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			d.t.Fatal(err)
		}
		payload = bytes.NewReader(raw)
	}
	request, err := http.NewRequest(method, d.baseURL+path, payload)
	if err != nil {
		d.t.Fatal(err)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := d.client.Do(request)
	if err != nil {
		d.t.Fatal(err)
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(response.Body)
	if err != nil {
		d.t.Fatal(err)
	}
	if response.StatusCode != want {
		d.t.Fatalf("%s %s = %d, want %d: %s", method, path, response.StatusCode, want, raw)
	}
	return raw
}

func (d t35HTTPDriver) decode(method, path, token string, body any, want int, out any) {
	d.t.Helper()
	raw := d.request(method, path, token, body, want)
	if out != nil {
		if err := json.Unmarshal(raw, out); err != nil {
			d.t.Fatalf("%s %s response: %v: %s", method, path, err, raw)
		}
	}
}

type t35Database struct {
	t   *testing.T
	ctx context.Context
	db  *pgx.Conn
	rds *redis.Client
}

func newT35Database(t *testing.T) *t35Database {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	t.Cleanup(cancel)
	db, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close(context.Background()) })
	options, err := redis.ParseURL(os.Getenv("REDIS_URL"))
	if err != nil {
		t.Fatal(err)
	}
	rds := redis.NewClient(options)
	t.Cleanup(func() { _ = rds.Close() })
	return &t35Database{t: t, ctx: ctx, db: db, rds: rds}
}

func (d *t35Database) exec(sql string, args ...any) {
	d.t.Helper()
	if _, err := d.db.Exec(d.ctx, sql, args...); err != nil {
		d.t.Fatalf("fixture SQL: %v\n%s", err, sql)
	}
}

func t35Drop(db *t35Database, sql string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, _ = db.db.Exec(ctx, sql)
}

func (d *t35Database) login(driver t35HTTPDriver, subject string) app.Tokens {
	d.t.Helper()
	var tokens app.Tokens
	driver.decode(http.MethodPost, "/v1/auth/login", "", map[string]any{
		"credential":      map[string]any{"provider": "apple", "proof": d.ticket(subject)},
		"age_confirmed":   true,
		"privacy_version": "2026-11",
		"terms_version":   "2026-11",
	}, http.StatusOK, &tokens)
	return tokens
}

func (d *t35Database) grantMemberContactCapacity(driver t35HTTPDriver, account app.Tokens) {
	d.t.Helper()
	// The barrier fixture needs a second writable source in the same account.
	// Seed a real paid order/entitlement, then require the production endpoint
	// to observe it before creating either contact.
	d.exec(`with o as (
		insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
		values($1,'apple',$2,'t35-process-fixture',1,'paid') returning id,user_id
	) insert into entitlements(order_id,user_id,starts_at,ends_at)
	select id,user_id,now()-interval '1 minute',now()+interval '1 hour' from o`,
		account.UserId, []byte(uuid.NewString()))
	var rights app.Entitlements
	driver.decode(http.MethodGet, "/v1/entitlements", account.AccessToken, nil, http.StatusOK, &rights)
	if rights.Tier != app.EntitlementsTierMember || rights.MaxActiveContacts != nil {
		d.t.Fatalf("barrier fixture entitlement = tier %q max_active_contacts %v, want member and unlimited",
			rights.Tier, rights.MaxActiveContacts)
	}
}

func (d *t35Database) createContact(driver t35HTTPDriver, token, nickname string) uuid.UUID {
	d.t.Helper()
	driver.request(http.MethodPut, "/v1/me/consents/contacts", token, map[string]any{
		"version": "v1", "granted": true,
	}, http.StatusOK)
	var contact app.Contact
	driver.decode(http.MethodPost, "/v1/contacts", token, map[string]any{
		"nickname": nickname, "scene": "partner",
	}, http.StatusOK, &contact)
	return contact.Id
}

func (d *t35Database) setContactID(oldID, newID uuid.UUID) {
	d.t.Helper()
	d.exec(`update contacts set id=$2 where id=$1`, oldID, newID)
}

func t35OrderedContactID(firstByte byte) uuid.UUID {
	id := uuid.New()
	// Keep the random UUID's uniqueness while placing the persistent failure
	// before the recoverable roots in the production retry query's ordering.
	id[0] = firstByte
	return id
}

func (d *t35Database) deletionState(id uuid.UUID) (remains, pending bool) {
	d.t.Helper()
	if err := d.db.QueryRow(d.ctx, `select exists(select 1 from contacts where id=$1), exists(select 1 from pending_erasure where root_id=$1)`, id).Scan(&remains, &pending); err != nil {
		d.t.Fatal(err)
	}
	return remains, pending
}

func requireT35DeletionState(t *testing.T, db *t35Database, id uuid.UUID, wantRemains, wantPending bool) {
	t.Helper()
	remains, pending := db.deletionState(id)
	if remains != wantRemains || pending != wantPending {
		t.Fatalf("deletion state for %s: remains=%t pending=%t, want remains=%t pending=%t", id, remains, pending, wantRemains, wantPending)
	}
}

func installT35OnceCleanupFailure(t *testing.T, db *t35Database, target uuid.UUID, slug string) {
	t.Helper()
	function := "t35_process_" + slug + "_once_fail"
	sequence := function + "_calls"
	trigger := function
	db.exec(`create sequence ` + sequence)
	db.exec(fmt.Sprintf(`create function %s() returns trigger language plpgsql as $$
begin
	if nextval('%s') = 1 then
		raise exception 'injected recoverable contact cleanup failure';
	end if;
	return old;
end $$`, function, sequence))
	db.exec(fmt.Sprintf(`create constraint trigger %s after delete on contacts
	deferrable initially deferred for each row when (old.id = '%s'::uuid)
	execute function %s()`, trigger, target, function))
	t.Cleanup(func() {
		t35Drop(db, `drop trigger if exists `+trigger+` on contacts`)
		t35Drop(db, `drop function if exists `+function+`()`)
		t35Drop(db, `drop sequence if exists `+sequence)
	})
}

func installT35PersistentCleanupFailure(t *testing.T, db *t35Database, target uuid.UUID, slug string) func() {
	t.Helper()
	function := "t35_process_" + slug + "_persistent_fail"
	trigger := function
	db.exec(fmt.Sprintf(`create function %s() returns trigger language plpgsql as $$
begin
	raise exception 'injected persistent contact cleanup failure';
end $$`, function))
	db.exec(fmt.Sprintf(`create constraint trigger %s after delete on contacts
	deferrable initially deferred for each row when (old.id = '%s'::uuid)
	execute function %s()`, trigger, target, function))
	t.Cleanup(func() { dropT35PersistentCleanupFailure(db, slug) })
	return func() { db.exec(`drop trigger ` + trigger + ` on contacts`) }
}

func dropT35PersistentCleanupFailure(db *t35Database, slug string) {
	function := "t35_process_" + slug + "_persistent_fail"
	t35Drop(db, `drop trigger if exists `+function+` on contacts`)
	t35Drop(db, `drop function if exists `+function+`()`)
}

func requireT35Problem(t *testing.T, body []byte, code, message string, retryable bool) {
	t.Helper()
	var problem map[string]any
	if err := json.Unmarshal(body, &problem); err != nil {
		t.Fatal(err)
	}
	if len(problem) != 3 || problem["code"] != code || problem["message"] != message || problem["retryable"] != retryable {
		t.Fatalf("problem response = %#v, want code=%q message=%q retryable=%t", problem, code, message, retryable)
	}
}

func requireT35InternalDeletionFailure(t *testing.T, body []byte) {
	t.Helper()
	requireT35Problem(t, body, "internal_error", "服务暂不可用，可重试", true)
}

func waitT35RecoveredWhileBlocked(t *testing.T, db *t35Database, recovering []uuid.UUID, blocked uuid.UUID, deadline time.Time) {
	t.Helper()
	for {
		allRecovered := true
		for _, id := range recovering {
			remains, pending := db.deletionState(id)
			if remains || pending {
				allRecovered = false
				break
			}
		}
		blockedRemains, blockedPending := db.deletionState(blocked)
		if allRecovered && blockedRemains && blockedPending {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("real minute ticker did not recover other accounts while the first failure remained: blocked remains=%t pending=%t", blockedRemains, blockedPending)
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func waitT35DeletionConverged(t *testing.T, db *t35Database, id uuid.UUID, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		remains, pending := db.deletionState(id)
		if !remains && !pending {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("real minute ticker did not converge committed deletion %s: remains=%t pending=%t", id, remains, pending)
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func requireT35FirstPendingRoot(t *testing.T, db *t35Database, want uuid.UUID) {
	t.Helper()
	var first uuid.UUID
	if err := db.db.QueryRow(db.ctx, `select root_id from pending_erasure order by root_id limit 1`).Scan(&first); err != nil {
		t.Fatal(err)
	}
	if first != want {
		t.Fatalf("first pending root = %s, want persistent failure root %s", first, want)
	}
}

func cleanupT35Contacts(db *t35Database, ids ...uuid.UUID) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for _, id := range ids {
		_, _ = db.db.Exec(ctx, `delete from pending_erasure where root_id=$1`, id)
		_, _ = db.db.Exec(ctx, `delete from contacts where id=$1`, id)
	}
}

func TestContactDeletionPublicDeleteBarrier(t *testing.T) {
	binary := os.Getenv("T35_API_BIN")
	if binary == "" {
		t.Fatal("T35_API_BIN must point at a built cmd/api binary")
	}
	db := newT35Database(t)
	api := startT35ProcessAPI(t, binary, freeT35Loopback(t))
	defer api.stop()
	driver := t35HTTPDriver{t: t, baseURL: api.baseURL, client: &http.Client{Timeout: 10 * time.Second}}

	ownerSubject := uuid.NewString()
	otherSubject := uuid.NewString()
	owner := db.login(driver, ownerSubject)
	expiringSession := db.login(driver, ownerSubject)
	if expiringSession.UserId != owner.UserId || expiringSession.AccessToken == owner.AccessToken {
		t.Fatal("expected two distinct sessions for the owner")
	}
	other := db.login(driver, otherSubject)
	db.grantMemberContactCapacity(driver, owner)
	pendingTarget := db.createContact(driver, owner.AccessToken, "T35 公开删除待恢复对象")
	blockedTarget := db.createContact(driver, owner.AccessToken, "T35 同账号其他源")
	otherTarget := db.createContact(driver, other.AccessToken, "T35 无关账号对象")
	// Contact cleanup runs after the trigger cleanup (callbacks are LIFO).
	var otherSurvivor uuid.UUID
	t.Cleanup(func() { cleanupT35Contacts(db, pendingTarget, blockedTarget, otherTarget, otherSurvivor) })

	pendingPath := "/v1/contacts/" + pendingTarget.String()
	summaryPath := pendingPath + "/summary"
	driver.request(http.MethodGet, summaryPath, owner.AccessToken, nil, http.StatusOK)

	// Create one legal child through the public API to exercise a retry of an
	// already registered contact cascade.
	driver.request(http.MethodPut, "/v1/me/consents/manual_mark", owner.AccessToken, map[string]any{
		"version": "v1", "granted": true,
	}, http.StatusOK)
	var mark app.Mark
	driver.decode(http.MethodPost, "/v1/marks", owner.AccessToken, app.CreateMarkInput{
		ContactId: &pendingTarget, RequestId: uuid.New(),
	}, http.StatusOK, &mark)
	if mark.Id == uuid.Nil || mark.ContactId == nil || *mark.ContactId != pendingTarget {
		t.Fatal("fixture mark is not linked to the pending contact")
	}
	ledgerOptions, err := redis.ParseURL(os.Getenv("LEDGER_URL"))
	if err != nil {
		t.Fatal("invalid synthetic LEDGER_URL")
	}
	ledger := redis.NewClient(ledgerOptions)
	t.Cleanup(func() { _ = ledger.Close() })
	contactKey, markKey := "deleted:"+pendingTarget.String(), "deleted:"+mark.Id.String()
	requireLedgerBatch := func() {
		t.Helper()
		n, err := ledger.Exists(db.ctx, contactKey, markKey).Result()
		if err != nil || n != 2 {
			t.Fatalf("contact cascade tombstones: got %d of 2, error %v", n, err)
		}
	}

	clearFailure := installT35PersistentCleanupFailure(t, db, pendingTarget, "public_barrier")

	// Establish the unfinished root through the public route. The 500 is a
	// cleanup failure, not the 503 availability barrier.
	body := driver.request(http.MethodDelete, pendingPath, owner.AccessToken, nil, http.StatusInternalServerError)
	requireT35InternalDeletionFailure(t, body)
	requireT35DeletionState(t, db, pendingTarget, true, true)
	requireLedgerBatch()
	body = driver.request(http.MethodGet, summaryPath, owner.AccessToken, nil, http.StatusServiceUnavailable)
	requireT35Problem(t, body, "service_unavailable", "数据暂时不可用，请稍后重试", true)

	// The authenticated owner may retry the exact pending contact. It reaches
	// cleanup again (and returns the injected 500) instead of being fenced by 503.
	body = driver.request(http.MethodDelete, pendingPath, owner.AccessToken, nil, http.StatusInternalServerError)
	requireT35InternalDeletionFailure(t, body)

	// Another source in the same account must be blocked by the account barrier.
	body = driver.request(http.MethodDelete, "/v1/contacts/"+blockedTarget.String(), owner.AccessToken, nil, http.StatusServiceUnavailable)
	requireT35Problem(t, body, "service_unavailable", "数据暂时不可用，请稍后重试", true)
	requireT35DeletionState(t, db, blockedTarget, true, false)

	// The owner's pending barrier also fences an attempt to delete another
	// account's source, without revealing or changing that source's ownership.
	body = driver.request(http.MethodDelete, "/v1/contacts/"+otherTarget.String(), owner.AccessToken, nil, http.StatusServiceUnavailable)
	requireT35Problem(t, body, "service_unavailable", "数据暂时不可用，请稍后重试", true)
	requireT35DeletionState(t, db, otherTarget, true, false)

	// The other account is not covered by the owner's account barrier, so its
	// attempt on the owner's source follows normal ownership checks and returns
	// the ordinary 404 instead of inheriting the owner's 503.
	body = driver.request(http.MethodDelete, "/v1/contacts/"+pendingTarget.String(), other.AccessToken, nil, http.StatusNotFound)
	requireT35Problem(t, body, "not_found", "未找到这条记录", false)
	requireT35DeletionState(t, db, pendingTarget, true, true)

	// An unrelated account remains usable while the owner still has an
	// unfinished root, including an exact public DELETE of its own contact.
	var ack app.Ack
	driver.decode(http.MethodDelete, "/v1/contacts/"+otherTarget.String(), other.AccessToken, nil, http.StatusOK, &ack)
	if !ack.Ok {
		t.Fatal("unrelated account contact deletion did not acknowledge success")
	}
	requireT35DeletionState(t, db, otherTarget, false, false)
	driver.request(http.MethodGet, "/v1/contacts", other.AccessToken, nil, http.StatusOK)
	otherSurvivor = db.createContact(driver, other.AccessToken, "T35 无关账号保留对象")

	// Session validation still distinguishes an invalid owner session from the
	// availability barrier on the exact pending source. Keep the original
	// session valid so it can perform the successful retry.
	expiringHash := sha256.Sum256([]byte(expiringSession.RefreshToken))
	db.exec(`update auth_sessions set expires_at=clock_timestamp()-interval '1 second' where user_id=$1 and refresh_hash=$2`,
		owner.UserId, expiringHash[:])
	body = driver.request(http.MethodDelete, pendingPath, expiringSession.AccessToken, nil, http.StatusUnauthorized)
	requireT35Problem(t, body, "unauthenticated", "验证已失效，请重新登录", false)
	requireT35DeletionState(t, db, pendingTarget, true, true)
	requireT35DeletionState(t, db, blockedTarget, true, false)
	requireLedgerBatch()

	clearFailure()
	var retryAck map[string]any
	driver.decode(http.MethodDelete, pendingPath, owner.AccessToken, nil, http.StatusOK, &retryAck)
	if len(retryAck) != 1 || retryAck["ok"] != true {
		t.Fatalf("owner retry acknowledgement = %#v, want only ok: true", retryAck)
	}
	// The maintenance ticker starts after process launch. Require the public
	// retry to finish before it can race between journaling and cleanup.
	if elapsed := time.Since(api.startedAt); elapsed >= time.Minute {
		t.Fatalf("owner retry completed after %v; it must finish before the first maintenance tick", elapsed)
	}
	body = driver.request(http.MethodGet, summaryPath, owner.AccessToken, nil, http.StatusNotFound)
	requireT35Problem(t, body, "contact_not_found", "未找到这条记录", false)
	body = driver.request(http.MethodDelete, pendingPath, owner.AccessToken, nil, http.StatusNotFound)
	requireT35Problem(t, body, "not_found", "未找到这条记录", false)
	requireT35DeletionState(t, db, pendingTarget, false, false)
	var cascadeRows int
	if err := db.db.QueryRow(db.ctx, `select
		(select count(*) from manual_marks where id=$1) +
		(select count(*) from mark_requests where mark_id=$1)`, mark.Id).Scan(&cascadeRows); err != nil {
		t.Fatal(err)
	}
	if cascadeRows != 0 {
		t.Fatalf("contact retry left %d mark or request rows", cascadeRows)
	}
	requireLedgerBatch()
	requireT35DeletionState(t, db, blockedTarget, true, false)
	requireT35DeletionState(t, db, otherSurvivor, true, false)
	driver.request(http.MethodGet, "/v1/contacts/"+blockedTarget.String()+"/summary", owner.AccessToken, nil, http.StatusOK)
	driver.request(http.MethodGet, "/v1/contacts/"+otherSurvivor.String()+"/summary", other.AccessToken, nil, http.StatusOK)
	t.Log("original owner retry: DELETE 200 ok:true, summary 404 contact_not_found, cascade cleaned, unrelated contacts retained")
	t.Log("post-completion owner DELETE: 404 not_found, retryable:false")
}

func TestContactDeletionProcessTicker(t *testing.T) {
	binary := os.Getenv("T35_API_BIN")
	if binary == "" {
		t.Fatal("T35_API_BIN must point at a built cmd/api binary")
	}
	db := newT35Database(t)
	address := freeT35Loopback(t)
	api := startT35ProcessAPI(t, binary, address)
	defer api.stop()
	driver := t35HTTPDriver{t: t, baseURL: api.baseURL, client: &http.Client{Timeout: 10 * time.Second}}

	persistentSubject := uuid.NewString()
	expiredSubject := uuid.NewString()
	revokedSubject := uuid.NewString()
	persistent := db.login(driver, persistentSubject)
	expired := db.login(driver, expiredSubject)
	revoked := db.login(driver, revokedSubject)
	persistentOriginal := db.createContact(driver, persistent.AccessToken, "T35 持续失败对象")
	expiredOriginal := db.createContact(driver, expired.AccessToken, "T35 过期会话对象")
	revokedOriginal := db.createContact(driver, revoked.AccessToken, "T35 撤销会话对象")
	// The production retry query orders by root_id. Make the persistent failure
	// first so recovery of later roots proves one failure does not block the pass.
	persistentTarget := t35OrderedContactID(0x00)
	expiredTarget := t35OrderedContactID(0x80)
	revokedTarget := t35OrderedContactID(0x80)
	db.setContactID(persistentOriginal, persistentTarget)
	db.setContactID(expiredOriginal, expiredTarget)
	db.setContactID(revokedOriginal, revokedTarget)
	installT35PersistentCleanupFailure(t, db, persistentTarget, "ticker")
	installT35OnceCleanupFailure(t, db, expiredTarget, "ticker_expired")
	installT35OnceCleanupFailure(t, db, revokedTarget, "ticker_revoked")

	for _, item := range []struct {
		token  string
		target uuid.UUID
	}{
		{persistent.AccessToken, persistentTarget},
		{expired.AccessToken, expiredTarget},
		{revoked.AccessToken, revokedTarget},
	} {
		body := driver.request(http.MethodDelete, "/v1/contacts/"+item.target.String(), item.token, nil, http.StatusInternalServerError)
		requireT35InternalDeletionFailure(t, body)
		requireT35DeletionState(t, db, item.target, true, true)
	}
	requireT35FirstPendingRoot(t, db, persistentTarget)

	// Recovery is driven by committed SQL intents. No original session may be
	// usable at the first production minute tick.
	db.exec(`update auth_sessions set expires_at=clock_timestamp()-interval '1 second' where user_id=$1`, persistent.UserId)
	db.exec(`update auth_sessions set expires_at=clock_timestamp()-interval '1 second' where user_id=$1`, expired.UserId)
	db.exec(`delete from auth_sessions where user_id=$1`, revoked.UserId)
	// GET /v1/contacts is deliberately fenced by the privacy barrier before
	// session validation, so its 503 is availability evidence, not proof that a
	// token's database session is expired or revoked. The exact pending contact
	// DELETE defers the generic barrier and validates the presented session in
	// the cleanup transaction, making its 401 the real public-route auth proof.
	for _, item := range []struct {
		token  string
		target uuid.UUID
	}{
		{persistent.AccessToken, persistentTarget},
		{expired.AccessToken, expiredTarget},
		{revoked.AccessToken, revokedTarget},
	} {
		body := driver.request(http.MethodGet, "/v1/contacts", item.token, nil, http.StatusServiceUnavailable)
		requireT35Problem(t, body, "service_unavailable", "数据暂时不可用，请稍后重试", true)
		body = driver.request(http.MethodDelete, "/v1/contacts/"+item.target.String(), item.token, nil, http.StatusUnauthorized)
		requireT35Problem(t, body, "unauthenticated", "验证已失效，请重新登录", false)
	}
	driver.request(http.MethodPost, "/v1/auth/login", "", map[string]any{
		"credential": map[string]any{"provider": "apple", "proof": db.ticket(persistentSubject)},
	}, http.StatusServiceUnavailable)

	waitT35RecoveredWhileBlocked(t, db, []uuid.UUID{expiredTarget, revokedTarget}, persistentTarget, api.startedAt.Add(t35FirstTickDeadline))
	elapsed := time.Since(api.startedAt)
	if elapsed < 55*time.Second {
		t.Fatalf("cleanup appeared after %v; the production minute ticker was not allowed to run naturally", elapsed)
	}
	api.requireAlive()
	t.Logf("minute ticker recovered expired and revoked sessions in pid %d after %v while a persistent failure remained isolated", api.cmd.Process.Pid, elapsed)

	for _, item := range []struct {
		subject string
		userId  uuid.UUID
	}{
		{expiredSubject, expired.UserId},
		{revokedSubject, revoked.UserId},
	} {
		resumed := db.login(driver, item.subject)
		if resumed.UserId != item.userId {
			t.Fatalf("original subject %s resumed as user %s, want %s", item.subject, resumed.UserId, item.userId)
		}
		driver.request(http.MethodGet, "/v1/contacts", resumed.AccessToken, nil, http.StatusOK)
	}
	driver.request(http.MethodPost, "/v1/auth/login", "", map[string]any{
		"credential": map[string]any{"provider": "apple", "proof": db.ticket(persistentSubject)},
	}, http.StatusServiceUnavailable)

	dropT35PersistentCleanupFailure(db, "ticker")
	waitT35DeletionConverged(t, db, persistentTarget, t35NextTickWait)
	api.requireAlive()
	resumed := db.login(driver, persistentSubject)
	if resumed.UserId != persistent.UserId {
		t.Fatalf("persistent subject resumed as user %s, want %s", resumed.UserId, persistent.UserId)
	}
	driver.request(http.MethodGet, "/v1/contacts", resumed.AccessToken, nil, http.StatusOK)
	t.Logf("next natural minute tick cleared the previously persistent failure in pid %d", api.cmd.Process.Pid)
}

func (d *t35Database) ticket(subject string) string {
	d.t.Helper()
	ticket := uuid.NewString()
	if err := d.rds.Set(d.ctx, "dev:ticket:apple:"+ticket, subject, time.Minute).Err(); err != nil {
		d.t.Fatal(err)
	}
	return ticket
}

func TestContactDeletionStartupFailClosed(t *testing.T) {
	binary := os.Getenv("T35_API_BIN")
	if binary == "" {
		t.Fatal("T35_API_BIN must point at a built cmd/api binary")
	}
	db := newT35Database(t)
	firstAddress := freeT35Loopback(t)
	api := startT35ProcessAPI(t, binary, firstAddress)
	defer api.stop()
	driver := t35HTTPDriver{t: t, baseURL: api.baseURL, client: &http.Client{Timeout: 10 * time.Second}}

	subject := uuid.NewString()
	account := db.login(driver, subject)
	target := db.createContact(driver, account.AccessToken, "T35 启动恢复失败对象")
	installT35PersistentCleanupFailure(t, db, target, "startup")
	body := driver.request(http.MethodDelete, "/v1/contacts/"+target.String(), account.AccessToken, nil, http.StatusInternalServerError)
	requireT35InternalDeletionFailure(t, body)
	requireT35DeletionState(t, db, target, true, true)

	// Stop before the first minute tick and restart against the same durable
	// state. This restart checks fail-closed startup, not timer recovery.
	api.stop()
	failedAddress := freeT35Loopback(t)
	startT35ProcessExpectFailure(t, binary, failedAddress, 30*time.Second)
	requireT35DeletionState(t, db, target, true, true)

	dropT35PersistentCleanupFailure(db, "startup")
	recoveredAddress := freeT35Loopback(t)
	recovered := startT35ProcessAPI(t, binary, recoveredAddress)
	defer recovered.stop()
	requireT35DeletionState(t, db, target, false, false)
	t.Logf("restart remained without a listener while recovery failed, then opened only after the fault was removed")
}

func startT35ProcessExpectFailure(t *testing.T, binary, address string, timeout time.Duration) {
	t.Helper()
	cmd := exec.Command(binary)
	cmd.Env = replaceEnv(os.Environ(), "LISTEN_ADDR", address)
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		if t35Listening(address) {
			_ = cmd.Process.Kill()
			<-done
			t.Fatalf("startup opened listener %s while recovery was failing; output:\n%s", address, output.String())
		}
		select {
		case err := <-done:
			if err == nil {
				t.Fatalf("startup exited successfully while recovery was failing; output:\n%s", output.String())
			}
			var exit *exec.ExitError
			if !errors.As(err, &exit) || exit.ExitCode() == 0 {
				t.Fatalf("startup failure was not a nonzero process exit: %v; output:\n%s", err, output.String())
			}
			if t35Listening(address) {
				t.Fatalf("startup failure left listener %s open; output:\n%s", address, output.String())
			}
			t.Logf("startup exited with code %d before opening a listener; output: %s", exit.ExitCode(), strings.TrimSpace(output.String()))
			return
		case <-ticker.C:
		case <-timer.C:
			_ = cmd.Process.Kill()
			<-done
			t.Fatalf("startup neither exited nor opened a listener within %v; output:\n%s", timeout, output.String())
		}
	}
}
