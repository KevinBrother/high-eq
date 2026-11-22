//go:build integration || marks_stdio

package service

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/marks"
	"high-eq/server/internal/privacy"
)

// Only run against a disposable development database. Accounts are created by
// the real T05 login/grant flows; no provider credentials or user data needed.
func TestT32AMarkLifecycle(t *testing.T) {
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(t.Context(), cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	srv := httptest.NewServer(s.Router())
	defer srv.Close()
	exerciseMarks(t, s, srv.URL, srv.Client().Do)
}

func exerciseMarks(t *testing.T, s *Runtime, origin string, do func(*http.Request) (*http.Response, error)) {
	ctx := t.Context()
	must := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	send := func(method, path, tok string, in any, want int, out any) error {
		b, e := json.Marshal(in)
		if e != nil {
			return e
		}
		req, e := http.NewRequestWithContext(ctx, method, origin+"/v1/"+path, bytes.NewReader(b))
		if e != nil {
			return e
		}
		req.Header.Set("Authorization", "Bearer "+tok)
		req.Header.Set("Content-Type", "application/json")
		r, e := do(req)
		if e != nil {
			return e
		}
		defer r.Body.Close()
		if r.StatusCode != want {
			return fmt.Errorf("%s %s: HTTP %d want %d", method, path, r.StatusCode, want)
		}
		if out != nil {
			return json.NewDecoder(r.Body).Decode(out)
		}
		return nil
	}
	call := func(m, path, tok string, in any, w int, out any) { t.Helper(); must(send(m, path, tok, in, w, out)) }
	signup := func() app.Tokens {
		ticket := uuid.NewString()
		must(s.cache.Set(ctx, "dev:ticket:apple:"+ticket, "synthetic-"+uuid.NewString(), time.Minute).Err())
		var a app.Tokens
		call("POST", "auth/login", "", map[string]any{"credential": map[string]string{"provider": "apple", "proof": ticket}, "age_confirmed": true, "terms_version": "2026-11", "privacy_version": "2026-11"}, 200, &a)
		return a
	}
	a, b := signup(), signup()
	exec := func(sql string, args ...any) { t.Helper(); _, e := s.db.Exec(ctx, sql, args...); must(e) }
	consent := func(tok string, on bool) {
		call("PUT", "me/consents/manual_mark", tok, map[string]any{"version": "v1", "granted": on}, 200, nil)
	}
	exec(`insert into daily_quota_usage(user_id,feature,charged_day,used) select $1,f,(now() at time zone 'Asia/Shanghai')::date,3 from unnest(array['practice','reply','review']) f`, a.UserId)
	checkFree := func() {
		var rights app.Entitlements
		call("GET", "entitlements", a.AccessToken, nil, 200, &rights)
		if rights.Tier != "free" || len(rights.Allowances) != 3 {
			t.Fatal("expected free account")
		}
		for _, x := range rights.Allowances {
			if x.Remaining == nil || *x.Remaining != 0 {
				t.Fatal("expected exhausted")
			}
		}
	}
	// An expired paid period must not turn the free path into a renewal gate.
	exec(`with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements(order_id,user_id,starts_at,ends_at) select id,user_id,now()-interval '2 days',now()-interval '1 day' from o`, a.UserId, []byte(uuid.NewString()))
	checkFree()
	in := func(k uuid.UUID) app.CreateMarkInput { return app.CreateMarkInput{RequestId: k} }
	call("GET", "marks", "", nil, 401, nil)
	call("POST", "marks", a.AccessToken, in(uuid.New()), 400, nil)
	consent(a.AccessToken, true)
	consent(b.AccessToken, true)
	// A burst of distinct requests must produce ONE row and one alias per request.
	const n = 12
	keys := make([]uuid.UUID, n)
	start := make(chan struct{})
	type result struct {
		m app.Mark
		e error
	}
	done := make(chan result, n)
	for i := range keys {
		keys[i] = uuid.New()
		go func(k uuid.UUID) {
			<-start
			var m app.Mark
			e := send("POST", "marks", a.AccessToken, in(k), 200, &m)
			done <- result{m, e}
		}(keys[i])
	}
	close(start)
	var first app.Mark
	for i := 0; i < n; i++ {
		v := <-done
		must(v.e)
		if i > 0 && (v.m.Id != first.Id || !v.m.MarkedAt.Equal(first.MarkedAt)) {
			t.Fatal("split window")
		}
		first = v.m
	}
	var foreign app.Mark
	call("POST", "marks", b.AccessToken, in(keys[0]), 200, &foreign)
	if foreign.Id == first.Id {
		t.Fatal("shared mark")
	}
	principal, e := s.Accounts.Parse(a.AccessToken)
	must(e)
	at := func(delta time.Duration, key uuid.UUID) app.Mark {
		var m app.Mark
		must(s.Accounts.WithSession(ctx, principal, false, func(tx pgx.Tx) error {
			var e error
			m, e = s.Marks.Create(ctx, tx, a.UserId, in(key), first.MarkedAt.Add(delta))
			return e
		}))
		return m
	}
	alias := uuid.New()
	if at(60*time.Second-time.Microsecond, alias).Id != first.Id {
		t.Fatal("early rollover")
	}
	second := at(time.Minute, uuid.New())
	if second.Id == first.Id || !second.MarkedAt.Equal(first.MarkedAt.Add(time.Minute)) {
		t.Fatal("late rollover")
	}
	for _, k := range append(keys, alias) {
		if at(2*time.Minute, k).Id != first.Id {
			t.Fatal("retry lost original")
		}
	}
	var page app.ListMarksResult
	call("GET", "marks?limit=1", a.AccessToken, nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != second.Id || page.NextCursor == nil {
		t.Fatal("bad page 1")
	}
	call("GET", "marks?limit=1&cursor="+url.QueryEscape(*page.NextCursor), a.AccessToken, nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != first.Id || page.NextCursor != nil {
		t.Fatal("bad page 2")
	}
	call("GET", "marks?limit=0", a.AccessToken, nil, 400, nil)
	path := "marks/" + first.Id.String()
	call("PATCH", path, b.AccessToken, map[string]string{"scene": "work"}, 404, nil)
	call("DELETE", path, b.AccessToken, nil, 404, nil)
	contact := uuid.New()
	encrypted, e := s.Fields.Seal([]byte(`{"Nickname":"合成对象","Scene":"work"}`), []byte("profile/"+a.UserId.String()+"/"+contact.String()))
	must(e)
	exec(`insert into contacts(user_id,id,profile_enc)values($1,$2,$3)`, a.UserId, contact, encrypted)
	call("PATCH", "marks/"+foreign.Id.String(), b.AccessToken, map[string]any{"contact_id": contact}, 400, nil)
	var edited app.Mark
	call("PATCH", path, a.AccessToken, map[string]any{"contact_id": contact, "scene": "work"}, 200, &edited)
	call("PATCH", path, a.AccessToken, map[string]any{"scene": nil}, 200, &edited)
	if edited.ContactId == nil || *edited.ContactId != contact || edited.Scene != nil {
		t.Fatal("null/omission mismatch")
	}
	call("PATCH", path, a.AccessToken, map[string]string{"scene": "family"}, 200, &edited)
	call("PATCH", path, a.AccessToken, map[string]string{"scene": "unknown"}, 400, nil)
	call("PATCH", path, a.AccessToken, map[string]string{"audio": "unused"}, 400, nil)
	var cipher []byte
	must(s.db.QueryRow(ctx, `select mark_enc from manual_marks where id=$1`, first.Id).Scan(&cipher))
	plain, e := s.Fields.Open(cipher, []byte("mark/"+a.UserId.String()+"/"+first.Id.String()))
	must(e)
	var stored app.Mark
	must(json.Unmarshal(plain, &stored))
	if stored.Scene == nil || *stored.Scene != "family" || stored.Id != first.Id {
		t.Fatal("incompatible payload")
	}
	export := func(u uuid.UUID) []app.Mark {
		var dst bytes.Buffer
		must(s.Data.Export(ctx, privacy.ExportRequest{OperationID: uuid.New(), UserID: u}, &dst))
		z, e := zip.NewReader(bytes.NewReader(dst.Bytes()), int64(dst.Len()))
		must(e)
		f, e := z.Open("manual_marks.json")
		must(e)
		defer f.Close()
		var out []app.Mark
		dec := json.NewDecoder(f)
		dec.DisallowUnknownFields()
		must(dec.Decode(&out))
		return out
	}
	consent(a.AccessToken, false)
	call("POST", "marks", a.AccessToken, in(uuid.New()), 400, nil)
	call("PATCH", path, a.AccessToken, map[string]any{"scene": nil}, 400, nil)
	if x := export(a.UserId); len(x) != 2 || x[0].Id != second.Id || x[1].Id != first.Id {
		t.Fatal("bad export")
	}
	call("DELETE", path, a.AccessToken, nil, 200, nil)
	call("DELETE", path, a.AccessToken, nil, 404, nil)
	if x := export(a.UserId); len(x) != 1 || x[0].Id != second.Id {
		t.Fatal("source still exported")
	}

	// A deleted request ID remains a tombstone even after the minute window.
	// Replaying it must neither rebuild the deleted mark nor expose success.
	tomb := signup()
	consent(tomb.AccessToken, true)
	tombKey := uuid.New()
	var tombMark app.Mark
	call("POST", "marks", tomb.AccessToken, in(tombKey), 200, &tombMark)
	call("DELETE", "marks/"+tombMark.Id.String(), tomb.AccessToken, nil, 200, nil)
	var conflict map[string]any
	call("POST", "marks", tomb.AccessToken, in(tombKey), 409, &conflict)
	if conflict["code"] != "conflict" || conflict["retryable"] != false {
		t.Fatalf("deleted request response = %#v", conflict)
	}
	tombPrincipal, e := s.Accounts.Parse(tomb.AccessToken)
	must(e)
	var replayErr error
	must(s.Accounts.WithSession(ctx, tombPrincipal, false, func(tx pgx.Tx) error {
		_, replayErr = s.Marks.Create(ctx, tx, tomb.UserId, in(tombKey), time.Now().Add(61*time.Second))
		return nil
	}))
	if replayErr == nil {
		t.Fatal("deleted request was accepted after the minute window")
	}
	var count int
	must(s.db.QueryRow(ctx, `select count(*) from manual_marks where user_id=$1`, tomb.UserId).Scan(&count))
	if count != 0 {
		t.Fatal("deleted request rebuilt a mark")
	}
	must(s.db.QueryRow(ctx, `select count(*) from manual_mark_tombstones where user_id=$1 and request_id=$2`, tomb.UserId, tombKey).Scan(&count))
	if count != 1 {
		t.Fatal("deleted request tombstone missing")
	}
	var shape string
	must(s.db.QueryRow(ctx, `select coalesce(string_agg(column_name, ',' order by column_name), '') from information_schema.columns where table_schema=current_schema() and table_name='manual_mark_tombstones'`).Scan(&shape))
	if shape != "request_id,user_id" {
		t.Fatalf("tombstone columns = %q, want only opaque replay evidence", shape)
	}
	var fresh app.Mark
	call("POST", "marks", tomb.AccessToken, in(uuid.New()), 200, &fresh)
	if fresh.Id == tombMark.Id {
		t.Fatal("new request reused deleted mark")
	}

	// Expiry is a logical deletion. Before maintenance removes the row, replaying
	// its original request key must conflict exactly as it will after cleanup.
	expiryNow := time.Now().UTC().Truncate(time.Microsecond)
	expired := signup()
	consent(expired.AccessToken, true)
	expiredKey := uuid.New()
	expiredPrincipal, e := s.Accounts.Parse(expired.AccessToken)
	must(e)
	must(s.Accounts.WithSession(ctx, expiredPrincipal, false, func(tx pgx.Tx) error {
		_, e := s.Marks.Create(ctx, tx, expired.UserId, in(expiredKey), expiryNow.Add(-180*24*time.Hour))
		return e
	}))
	var expiredReplay error
	must(s.Accounts.WithSession(ctx, expiredPrincipal, false, func(tx pgx.Tx) error {
		_, expiredReplay = s.Marks.Create(ctx, tx, expired.UserId, in(expiredKey), expiryNow)
		return nil
	}))
	if !errors.Is(expiredReplay, marks.ErrDeleted) {
		t.Fatalf("expired replay = %v, want ErrDeleted", expiredReplay)
	}
	call("POST", "marks", expired.AccessToken, in(expiredKey), 409, &conflict)
	if conflict["code"] != "conflict" || conflict["retryable"] != false {
		t.Fatalf("expired request response = %#v", conflict)
	}
	must(s.db.QueryRow(ctx, `select count(*) from manual_marks where user_id=$1`, expired.UserId).Scan(&count))
	if count != 1 {
		t.Fatal("expired replay created a mark before cleanup")
	}
	must(s.Marks.PurgeDue(ctx, expiryNow.Add(time.Second)))
	call("POST", "marks", expired.AccessToken, in(expiredKey), 409, &conflict)
	must(s.db.QueryRow(ctx, `select count(*) from manual_marks where user_id=$1`, expired.UserId).Scan(&count))
	if count != 0 {
		t.Fatal("expired mark remains after cleanup")
	}
	must(s.db.QueryRow(ctx, `select count(*) from manual_mark_tombstones where user_id=$1 and request_id=$2`, expired.UserId, expiredKey).Scan(&count))
	if count != 1 {
		t.Fatal("expired request lost replay evidence")
	}

	// A committed deletion intent can be recovered by retrying the exact source.
	// Use a fresh account so the pending barrier cannot hide the main lifecycle
	// assertions or leak a tombstone into their export/retention checks.
	d := signup()
	consent(d.AccessToken, true)
	pendingKey := uuid.New()
	var pendingMark app.Mark
	call("POST", "marks", d.AccessToken, in(pendingKey), 200, &pendingMark)
	exec(`insert into pending_erasure(root_id) values($1)`, pendingMark.Id)
	var unavailable struct {
		Code      string `json:"code"`
		Retryable bool   `json:"retryable"`
	}
	call("GET", "marks", d.AccessToken, nil, 503, &unavailable)
	if unavailable.Code != "service_unavailable" || !unavailable.Retryable {
		t.Fatalf("pending barrier response = %#v", unavailable)
	}
	// Token refresh runs through the same fail-closed barrier. It is an
	// availability failure, not proof that the refresh token was revoked.
	call("POST", "auth/refresh", "", map[string]any{"refresh_token": d.RefreshToken}, 503, &unavailable)
	if unavailable.Code != "service_unavailable" || !unavailable.Retryable {
		t.Fatalf("pending refresh response = %#v", unavailable)
	}
	call("DELETE", "marks/"+pendingMark.Id.String(), d.AccessToken, nil, 200, nil)
	call("GET", "marks", d.AccessToken, nil, 200, nil)
	var pendingRemains bool
	must(s.db.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, d.UserId, pendingMark.Id).Scan(&pendingRemains))
	if pendingRemains {
		t.Fatal("exact pending retry left mark")
	}

	// A committed deletion intent remains retryable even if the source crosses
	// its retention boundary before maintenance runs. A 404 here would tell the
	// App that privacy erasure completed while the row still exists.
	expiredPending := signup()
	consent(expiredPending.AccessToken, true)
	expiredPendingKey := uuid.New()
	var expiredPendingMark app.Mark
	call("POST", "marks", expiredPending.AccessToken, in(expiredPendingKey), 200, &expiredPendingMark)
	exec(`insert into pending_erasure(root_id) values($1)`, expiredPendingMark.Id)
	exec(`update manual_marks set accepted_at=clock_timestamp()-interval '4320 hours' where id=$1`, expiredPendingMark.Id)
	call("DELETE", "marks/"+expiredPendingMark.Id.String(), expiredPending.AccessToken, nil, 200, nil)
	var expiredPendingRemains bool
	must(s.db.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, expiredPending.UserId, expiredPendingMark.Id).Scan(&expiredPendingRemains))
	if expiredPendingRemains {
		t.Fatal("expired pending retry left mark")
	}
	call("DELETE", "marks/"+expiredPendingMark.Id.String(), expiredPending.AccessToken, nil, 404, nil)
	must(s.db.QueryRow(ctx, `select count(*) from manual_mark_tombstones where user_id=$1 and request_id=$2`, expiredPending.UserId, expiredPendingKey).Scan(&count))
	if count != 1 {
		t.Fatal("expired pending retry lost replay evidence")
	}

	// The running minute maintenance path must resume a pending manual-mark
	// deletion without waiting for a restart. This intentionally calls
	// Marks.PurgeDue, not the generic privacy coordinator.
	resumeKey := uuid.New()
	var resumeMark app.Mark
	call("POST", "marks", d.AccessToken, in(resumeKey), 200, &resumeMark)
	exec(`insert into pending_erasure(root_id) values($1)`, resumeMark.Id)
	call("GET", "marks", d.AccessToken, nil, 503, &unavailable)
	if unavailable.Code != "service_unavailable" || !unavailable.Retryable {
		t.Fatalf("resume barrier response = %#v", unavailable)
	}
	must(s.Marks.PurgeDue(ctx, time.Now()))
	call("GET", "marks", d.AccessToken, nil, 200, nil)
	var resumeRemains bool
	must(s.db.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, d.UserId, resumeMark.Id).Scan(&resumeRemains))
	if resumeRemains {
		t.Fatal("minute maintenance left pending mark")
	}

	// A different pending root remains a fail-closed barrier, even when the
	// requested mark is unrelated.
	barrierKey := uuid.New()
	var barrierMark app.Mark
	call("POST", "marks", d.AccessToken, in(barrierKey), 200, &barrierMark)
	exec(`update manual_marks set accepted_at=clock_timestamp()-interval '2 minutes' where id=$1`, barrierMark.Id)
	targetKey := uuid.New()
	var targetMark app.Mark
	call("POST", "marks", d.AccessToken, in(targetKey), 200, &targetMark)
	exec(`insert into pending_erasure(root_id) values($1)`, barrierMark.Id)
	call("DELETE", "marks/"+targetMark.Id.String(), d.AccessToken, nil, 503, &unavailable)
	if unavailable.Code != "service_unavailable" || !unavailable.Retryable {
		t.Fatalf("unrelated pending response = %#v", unavailable)
	}
	var targetRemains bool
	must(s.db.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, d.UserId, targetMark.Id).Scan(&targetRemains))
	if !targetRemains {
		t.Fatal("unrelated pending root allowed deletion")
	}
	call("DELETE", "marks/"+barrierMark.Id.String(), d.AccessToken, nil, 200, nil)
	call("DELETE", "marks/"+targetMark.Id.String(), d.AccessToken, nil, 200, nil)

	// A failed physical delete must roll back both the row deletion and its
	// tombstone, and the HTTP layer must not report success.
	failed := signup()
	consent(failed.AccessToken, true)
	failedKey := uuid.New()
	var failedMark app.Mark
	call("POST", "marks", failed.AccessToken, in(failedKey), 200, &failedMark)
	exec(`create function pg_temp.t32a_reject_mark_delete() returns trigger language plpgsql as $$ begin raise exception 'synthetic delete failure'; end $$`)
	exec(`create trigger t32a_reject_mark_delete before delete on manual_marks for each row execute function pg_temp.t32a_reject_mark_delete()`)
	call("DELETE", "marks/"+failedMark.Id.String(), failed.AccessToken, nil, 500, nil)
	var failedRemains, failedTombstone bool
	must(s.db.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, failed.UserId, failedMark.Id).Scan(&failedRemains))
	must(s.db.QueryRow(ctx, `select exists(select from manual_mark_tombstones where user_id=$1 and request_id=$2)`, failed.UserId, failedKey).Scan(&failedTombstone))
	if !failedRemains || failedTombstone {
		t.Fatal("failed delete did not roll back")
	}
	exec(`drop trigger t32a_reject_mark_delete on manual_marks`)
	exec(`drop function pg_temp.t32a_reject_mark_delete()`)
	call("DELETE", "marks/"+failedMark.Id.String(), failed.AccessToken, nil, 200, nil)

	// Session validation belongs to the same account-locked transaction that
	// records the deletion intent. Revoke the session after the HTTP gate has
	// parsed it, then exercise the real DELETE handler.
	revoked := signup()
	consent(revoked.AccessToken, true)
	var revokedMark app.Mark
	call("POST", "marks", revoked.AccessToken, in(uuid.New()), 200, &revokedMark)
	revokedPrincipal, eParse := s.Accounts.Parse(revoked.AccessToken)
	must(eParse)
	exec(`delete from auth_sessions where id=$1`, revokedPrincipal.Session)
	call("DELETE", "marks/"+revokedMark.Id.String(), revoked.AccessToken, nil, 401, nil)
	var revokedRemains bool
	must(s.db.QueryRow(ctx, `select exists(select from manual_marks where user_id=$1 and id=$2)`, revoked.UserId, revokedMark.Id).Scan(&revokedRemains))
	if !revokedRemains {
		t.Fatal("revoked session deleted mark")
	}
	var revokedPending bool
	must(s.db.QueryRow(ctx, `select exists(select from pending_erasure where root_id=$1)`, revokedMark.Id).Scan(&revokedPending))
	if revokedPending {
		t.Fatal("revoked session recorded deletion intent")
	}
	// Retention excludes the exact boundary, before maintenance physically erases it.
	now := time.Now().UTC().Truncate(time.Microsecond)
	exec(`update manual_marks set accepted_at=$2 where id=$1`, second.Id, now.Add(-180*24*time.Hour))
	must(s.Accounts.WithSession(ctx, principal, false, func(tx pgx.Tx) error {
		pg, e := s.Marks.List(ctx, tx, a.UserId, app.ListMarksParams{}, now)
		if len(pg.Items) != 0 {
			return fmt.Errorf("expiry boundary exposed")
		}
		return e
	}))
	call("GET", "marks", a.AccessToken, nil, 200, &page)
	if len(page.Items) != 0 || len(export(a.UserId)) != 0 {
		t.Fatal("expired mark exposed")
	}
	must(s.Marks.PurgeDue(ctx, now))
	must(s.db.QueryRow(ctx, `select (select count(*) from mark_requests where user_id=$1)+(select count(*) from manual_marks where user_id=$1)+(select count(*) from activities where user_id=$1)`, a.UserId).Scan(&count))
	if count != 0 {
		t.Fatal("aliases, marks or AI activities remain")
	}
	checkFree()
	// The contact root cascades the mark and every request alias. No contact API
	// from another in-flight card is required by this fixture.
	consent(a.AccessToken, true)
	attachedKey := uuid.New()
	var attached app.Mark
	call("POST", "marks", a.AccessToken, map[string]any{"request_id": attachedKey, "contact_id": contact}, 200, &attached)
	must(s.Data.Delete(ctx, privacy.Deletion{OperationID: uuid.New(), UserID: a.UserId, SourceID: contact, Scope: "contacts"}))
	if len(export(a.UserId)) != 0 {
		t.Fatal("contact cascade left mark")
	}
	must(s.db.QueryRow(ctx, `select count(*) from mark_requests where mark_id=$1`, attached.Id).Scan(&count))
	if count != 0 {
		t.Fatal("contact cascade left aliases")
	}
	var tombstoned bool
	must(s.db.QueryRow(ctx, `select exists(select from manual_mark_tombstones where user_id=$1 and request_id=$2)`, a.UserId, attachedKey).Scan(&tombstoned))
	if !tombstoned {
		t.Fatal("contact cascade did not tombstone request")
	}
	call("POST", "marks", a.AccessToken, map[string]any{"request_id": attachedKey, "contact_id": contact}, 409, nil)
	if x := export(b.UserId); len(x) != 1 || x[0].Id != foreign.Id {
		t.Fatal("cross-account erasure")
	}
	// Account deletion must remove the opaque replay evidence too.
	call("DELETE", "marks/"+foreign.Id.String(), b.AccessToken, nil, 200, nil)
	must(s.db.QueryRow(ctx, `select count(*) from manual_mark_tombstones where user_id=$1`, b.UserId).Scan(&count))
	if count != 1 {
		t.Fatal("account tombstone missing before purge")
	}
	// Test actual T05 closure maintenance, not just a direct account cascade.
	exec(`update users set closure_requested_at=now()-interval '361 hours' where id=$1`, b.UserId)
	call("GET", "marks", b.AccessToken, nil, 401, nil)
	must(s.Accounts.PurgeDue(ctx))
	call("GET", "marks", b.AccessToken, nil, 401, nil)
	must(s.db.QueryRow(ctx, `select count(*) from mark_requests where user_id=$1`, b.UserId).Scan(&count))
	if count != 0 {
		t.Fatal("account aliases remain")
	}
	must(s.db.QueryRow(ctx, `select count(*) from manual_mark_tombstones where user_id=$1`, b.UserId).Scan(&count))
	if count != 0 {
		t.Fatal("account tombstones remain")
	}
}
