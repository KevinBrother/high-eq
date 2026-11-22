//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/profile"
)

type profileRunner func(context.Context, gateway.Call) (gateway.Reply, error)

func (fn profileRunner) Run(ctx context.Context, c gateway.Call) (gateway.Reply, error) {
	return fn(ctx, c)
}
func TestProfileLifecycle(t *testing.T) {
	ctx := context.Background()
	must := func(e error) {
		t.Helper()
		if e != nil {
			t.Fatal(e)
		}
	}
	cfg, e := LoadConfig()
	must(e)
	s, e := Start(ctx, cfg)
	must(e)
	defer s.Close()
	router := s.Router()
	call := func(method, path, token string, in any, status int, out any) {
		t.Helper()
		b, e := json.Marshal(in)
		must(e)
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s: %d want %d: %s", method, path, w.Code, status, w.Body)
		}
		if out != nil {
			must(json.Unmarshal(w.Body.Bytes(), out))
		}
	}
	signup := func() app.Tokens {
		ticket := uuid.NewString()
		must(s.cache.Set(ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err())
		var a app.Tokens
		call("POST", "auth/login", "", map[string]any{"credential": map[string]string{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"}, 200, &a)
		return a
	}
	a, b := signup(), signup()
	u, tok := a.UserId, a.AccessToken
	exec := func(sql string, args ...any) { t.Helper(); _, e := s.db.Exec(ctx, sql, args...); must(e) }
	grant := func(p string, on bool) {
		call("PUT", "me/consents/"+p, tok, map[string]any{"version": "v1", "granted": on}, 200, nil)
	}
	call("GET", "contact-questions", "", nil, 401, nil)
	var bank struct{ Items []profile.Question }
	call("GET", "contact-questions", tok, nil, 200, &bank)
	if len(bank.Items) != 7 {
		t.Fatal("question count")
	}
	in := map[string]any{"nickname": "合成甲", "scene": "partner", "answers": []any{map[string]any{"question_id": bank.Items[5].ID, "answer": "一起商量"}}}
	var one, two app.Contact
	call("POST", "contacts", tok, in, 403, nil)
	grant("contacts", true)
	call("POST", "contacts", tok, in, 200, &one)
	call("POST", "contacts", tok, in, 403, nil)
	call("GET", "emotion-summary", tok, nil, 403, nil)
	exec(`with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '2 days',now()+interval '1 day' from o`, u, []byte(uuid.NewString()))
	in["nickname"] = "合成乙"
	call("POST", "contacts", tok, in, 200, &two)
	p := "contacts/" + one.Id.String()
	pTwo := "contacts/" + two.Id.String()
	call("POST", p+"/activate", tok, nil, 200, nil)
	call("GET", p+"/summary", b.AccessToken, nil, 404, nil)
	call("DELETE", p, b.AccessToken, nil, 404, nil)
	var page app.ListContactsResult
	call("GET", "contacts?limit=1", tok, nil, 200, &page)
	if len(page.Items) != 1 || page.NextCursor == nil {
		t.Fatal("first page")
	}
	first := page.Items[0].Id
	call("GET", "contacts?limit=1&cursor="+*page.NextCursor, tok, nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id == first || page.NextCursor != nil {
		t.Fatal("second page")
	}
	exec(`update entitlements set ends_at=now()-interval '1 day' where user_id=$1`, u)
	var people app.ListContactsResult
	call("GET", "contacts", tok, nil, 200, &people)
	for _, v := range people.Items {
		if v.Editable != (v.Id == one.Id) {
			t.Fatal("wrong default")
		}
	}
	edit := map[string]string{"nickname": "合成丙", "scene": "work"}
	call("PATCH", pTwo, tok, edit, 403, nil)
	raw := "只用于内存的合成聊天"
	material := app.InferProfileInput{RequestId: uuid.New(), ChatText: raw}
	call("POST", p+"/infer", tok, material, 403, nil)
	if e = s.Data.Access(ctx, u, func(tx pgx.Tx) error { _, e := s.Profiles.ForModel(ctx, tx, u, two.Id); return e }); !errors.Is(e, membership.ErrForbidden) {
		t.Fatal("training use not rejected", e)
	}
	activity, src := uuid.New(), uuid.New()
	exec(`insert into activities(id,user_id,source_id,kind,contact_id,state) values($1,$2,$3,'review',$4,'complete')`, activity, u, src, one.Id)
	note := "一起商量"
	feedback := app.SendProfileFeedbackInput{SourceId: src, Subject: "contact", Confirmed: true, ContactId: &one.Id, Note: &note}
	rejectedActivity, rejectedSrc := uuid.New(), uuid.New()
	exec(`insert into activities(id,user_id,source_id,kind,contact_id,state) values($1,$2,$3,'review',$4,'complete')`, rejectedActivity, u, rejectedSrc, two.Id)
	rejectedFeedback := app.SendProfileFeedbackInput{SourceId: rejectedSrc, Subject: "contact", Confirmed: true, ContactId: &two.Id, Note: &note}
	call("POST", "profiles/feedback", tok, rejectedFeedback, 403, nil)
	call("POST", p+"/activate", tok, nil, 200, nil)
	call("PATCH", p, tok, edit, 200, nil)
	call("POST", p+"/infer", tok, material, 403, nil)
	grant("chat_import", true)
	var body app.Profile
	mode := "ok"
	s.Profiles.AI = profileRunner(func(_ context.Context, c gateway.Call) (gateway.Reply, error) {
		if c.User != u || c.Contact != one.Id || c.Task != gateway.ProfileInference || c.Messages[0].Content != raw {
			t.Fatal("wrong inference scope")
		}
		switch mode {
		case "safety":
			return gateway.Reply{Terminal: &gateway.Terminal{Safety: true, Message: gateway.HelpMessage}}, nil
		case "down":
			return gateway.Reply{Terminal: &gateway.Terminal{Code: "moderation_unavailable", Retryable: true}}, nil
		case "withdraw":
			grant("chat_import", false)
		}
		return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(`{"choices":[1,1,2,1,0,0,0]}`)}}, nil
	})
	call("POST", p+"/infer", tok, material, 200, &body)
	if body.Attachment != nil || body.BigFive[0].Confidence == 0 {
		t.Fatal("bad inference")
	}
	mode = "safety"
	var safe app.Safety
	safetyMaterial := app.InferProfileInput{RequestId: uuid.New(), ChatText: raw}
	call("POST", p+"/infer", tok, safetyMaterial, 200, &safe)
	if !safe.Safety {
		t.Fatal("missing safety")
	}
	mode = "down"
	downMaterial := app.InferProfileInput{RequestId: uuid.New(), ChatText: raw}
	call("POST", p+"/infer", tok, downMaterial, 503, nil)
	mode = "withdraw"
	withdrawMaterial := app.InferProfileInput{RequestId: uuid.New(), ChatText: raw}
	call("POST", p+"/infer", tok, withdrawMaterial, 409, nil)
	call("POST", "profiles/feedback", tok, feedback, 200, nil)
	call("POST", "profiles/feedback", tok, feedback, 200, nil)
	var after app.Profile
	call("GET", p+"/summary", tok, nil, 200, &after)
	if after.ConflictStyle.Confidence <= body.ConflictStyle.Confidence {
		t.Fatal("missing reinforcement")
	}
	// Use the actual bus for a second, explicitly sourced observation.
	src2 := uuid.New()
	exec(`insert into activities(user_id,source_id,kind,contact_id,state) values($1,$2,'reply',$3,'complete')`, u, src2, one.Id)
	ev := events.Feedback{UserID: u, SourceID: src2, FeedbackID: uuid.New(), Subject: "contact", SourceKind: "reply", OccurredAt: time.Now().UTC().Truncate(time.Microsecond), ContactID: &one.Id}
	must(s.Data.Access(ctx, u, func(tx pgx.Tx) error { return s.Profiles.RecordActivity(ctx, tx, ev, note, "work") }))
	must(s.Bus.PublishFeedback(ctx, ev))
	must(s.Bus.PublishFeedback(ctx, ev))
	var reinforced app.Profile
	call("GET", p+"/summary", tok, nil, 200, &reinforced)
	if reinforced.ConflictStyle.Confidence <= after.ConflictStyle.Confidence {
		t.Fatal("bus observation missing")
	}
	must(s.Data.Delete(ctx, privacy.Deletion{UserID: u, SourceID: src2, OperationID: uuid.New(), Scope: "replies"}))
	call("GET", p+"/summary", tok, nil, 200, &reinforced)
	if reinforced.ConflictStyle != after.ConflictStyle || s.Bus.PublishFeedback(ctx, ev) == nil {
		t.Fatal("deleted observation survived")
	}
	exec(`update entitlements set ends_at=now()+interval '1 day' where user_id=$1`, u)
	call("GET", "contacts", tok, nil, 200, &people)
	for _, v := range people.Items {
		if !v.Editable {
			t.Fatal("renewal")
		}
	}
	// Same scene and contact: a manual mark is its own count; even an asserted
	// yes on a rhythm event cannot become personal evidence. Then add one verified self event.
	sc := "work"
	mark := uuid.New()
	now := time.Now().UTC()
	seal := func(kind string, id uuid.UUID, v any) []byte {
		b, e := json.Marshal(v)
		must(e)
		enc, e := s.Fields.Seal(b, []byte(kind+"/"+u.String()+"/"+id.String()))
		must(e)
		return enc
	}
	exec(`insert into manual_marks(user_id,id,contact_id,mark_enc) values($1,$2,$3,$4)`, u, mark, one.Id, seal("mark", mark, app.Mark{Id: mark, Scene: &sc, MarkedAt: now, ContactId: &one.Id}))
	call("POST", "profiles/feedback", tok, app.SendProfileFeedbackInput{Confirmed: true, Subject: "self", SourceId: mark}, 404, nil)
	grant("voice", true)
	grant("health", true)
	for _, kind := range []string{"conversation_rhythm", "self_fluctuation"} {
		id, fid := uuid.New(), uuid.New()
		canonical := map[string]any{"id": id, "kind": kind, "starts_at": now, "scene": sc, "contact_id": one.Id, "confirmation": "yes", "confirmed_at": now, "feedback_id": fid}
		exec(`insert into signal_events(user_id,id,contact_id,occurred_at,event_enc) values($1,$2,$3,$4,$5)`, u, id, one.Id, now, seal("event", id, canonical))
		event := events.Feedback{UserID: u, SourceID: id, SourceKind: "self_event", Subject: "self", FeedbackID: fid, OccurredAt: now}
		first := s.Bus.PublishFeedback(ctx, event)
		if kind == "conversation_rhythm" {
			if first == nil {
				t.Fatal("rhythm accepted")
			}
		} else {
			must(first)
			must(s.Bus.PublishFeedback(ctx, event))
		}
	}
	var groups app.EmotionSummaryResult
	call("GET", "emotion-summary", tok, nil, 200, &groups)
	if len(groups.Groups) != 1 || groups.Groups[0].ManualCount != 1 || groups.Groups[0].ConfirmedSelfCount != 1 || groups.Groups[0].Scene == nil || *groups.Groups[0].Scene != sc {
		t.Fatal("manual/rhythm misattributed", groups)
	}

	// The full export now includes growth. Seed a canonical, account-bound T23
	// score and have T26 produce the encrypted numeric copy just as it does online.
	detail, err := s.Fields.Seal([]byte(reviewScore), []byte("review/v1/"+u.String()+"/"+src.String()+"/score"))
	must(err)
	var scoredAt time.Time
	must(s.db.QueryRow(ctx, `insert into scores(id,activity_id,activity_kind,detail_enc) values($1,$2,'review',$3) returning occurred_at`, src, activity, detail).Scan(&scoredAt))
	must(s.Bus.PublishScore(ctx, events.Score{ScoreKey: privacy.ScoreKey{UserID: u, ActivityID: activity, SourceID: src, Kind: "review", OccurredAt: scoredAt}}))
	var projectionCount int
	must(s.db.QueryRow(ctx, `select count(*) from growth_scores where score_id=$1`, src).Scan(&projectionCount))
	if projectionCount != 1 {
		t.Fatalf("growth subscriber produced %d numeric copies", projectionCount)
	}
	export := func() []byte {
		var buf bytes.Buffer
		must(s.Data.Export(ctx, privacy.ExportRequest{UserID: u, OperationID: uuid.New()}, &buf))
		z, e := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
		must(e)
		f, e := z.Open("profiles.json")
		must(e)
		defer f.Close()
		v, e := io.ReadAll(f)
		must(e)
		return v
	}
	if x := export(); !bytes.Contains(x, []byte(src.String())) || bytes.Contains(x, []byte(raw)) {
		t.Fatal("bad profile export")
	}
	call("DELETE", p, tok, nil, 200, nil)
	if x := export(); bytes.Contains(x, []byte(one.Id.String())) || bytes.Contains(x, []byte(src.String())) || !bytes.Contains(x, []byte(two.Id.String())) {
		t.Fatal("bad contact cascade")
	}
	call("GET", "emotion-summary", tok, nil, 200, &groups)
	if len(groups.Groups) != 0 {
		t.Fatal("stale groups after cascade")
	}
	var n int
	must(s.db.QueryRow(ctx, `select (select count(*) from scores where id=$1)+(select count(*) from growth_scores where score_id=$1)+(select count(*) from activities where source_id=$1)`, src).Scan(&n))
	if n != 0 {
		t.Fatal("score copies survived")
	}
}

func TestProfileInferenceReviewRegressions(t *testing.T) {
	ctx := context.Background()
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	router := s.Router()
	requestWithContext := func(ctx context.Context, method, path, token string, in any) (int, []byte) {
		b, e := json.Marshal(in)
		if e != nil {
			panic(e)
		}
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		r = r.WithContext(ctx)
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		return w.Code, w.Body.Bytes()
	}
	request := func(method, path, token string, in any) (int, []byte) {
		return requestWithContext(context.Background(), method, path, token, in)
	}
	mustCall := func(method, path, token string, in any, status int, out any) []byte {
		t.Helper()
		code, body := request(method, path, token, in)
		if code != status {
			t.Fatalf("%s %s: %d want %d: %s", method, path, code, status, body)
		}
		if out != nil {
			if e := json.Unmarshal(body, out); e != nil {
				t.Fatal(e)
			}
		}
		return body
	}
	proof := func(subject string) map[string]string {
		t.Helper()
		ticket := uuid.NewString()
		if e := s.cache.Set(ctx, "dev:ticket:apple:"+ticket, subject, time.Minute).Err(); e != nil {
			t.Fatal(e)
		}
		return map[string]string{"provider": "apple", "proof": ticket}
	}
	loginSubject := func(subject string, register bool) app.Tokens {
		t.Helper()
		in := map[string]any{"credential": proof(subject)}
		if register {
			in["age_confirmed"] = true
			in["privacy_version"] = "2026-11"
			in["terms_version"] = "2026-11"
		}
		var a app.Tokens
		mustCall("POST", "auth/login", "", in, 200, &a)
		return a
	}
	signup := func() app.Tokens {
		t.Helper()
		return loginSubject(uuid.NewString(), true)
	}
	grant := func(token, purpose string, on bool) {
		t.Helper()
		mustCall("PUT", "me/consents/"+purpose, token, map[string]any{"version": "v1", "granted": on}, 200, nil)
	}
	create := func(token string) app.Contact {
		t.Helper()
		var c app.Contact
		mustCall("POST", "contacts", token, map[string]any{"nickname": "合成审查关系人", "scene": "partner"}, 200, &c)
		return c
	}
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, e := s.db.Exec(ctx, sql, args...); e != nil {
			t.Fatal(e)
		}
	}

	t.Run("consent change invalidates in-flight result", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		c := create(a.AccessToken)
		p := "contacts/" + c.Id.String()
		var before app.Profile
		mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &before)

		started := make(chan struct{}, 1)
		release := make(chan struct{})
		var releaseOnce sync.Once
		unblock := func() { releaseOnce.Do(func() { close(release) }) }
		defer unblock()
		var calls atomic.Int32
		s.Profiles.AI = profileRunner(func(ctx context.Context, c gateway.Call) (gateway.Reply, error) {
			calls.Add(1)
			select {
			case started <- struct{}{}:
			default:
			}
			select {
			case <-release:
				if c.BeforeAttempt == nil {
					return gateway.Reply{}, errors.New("inference dispatch has no authorization guard")
				}
				if e := c.BeforeAttempt(ctx); e != nil {
					return gateway.Reply{}, e
				}
				return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(`{"choices":[1,1,1,1,1,1,0]}`)}}, nil
			case <-ctx.Done():
				return gateway.Reply{}, ctx.Err()
			}
		})
		in := app.InferProfileInput{RequestId: uuid.New(), ChatText: "只用于内存的合成审查片段"}
		type result struct {
			code int
			body []byte
		}
		done := make(chan result, 1)
		go func() {
			code, body := request("POST", p+"/infer", a.AccessToken, in)
			done <- result{code, body}
		}()
		select {
		case <-started:
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not start")
		}
		if code, body := request("POST", p+"/infer", a.AccessToken, in); code != 202 || !bytes.Contains(body, []byte(`"status":"in_progress"`)) {
			t.Fatalf("pending request replay: %d want 202: %s", code, body)
		}
		grant(a.AccessToken, "chat_import", false)
		grant(a.AccessToken, "chat_import", true)
		unblock()
		select {
		case got := <-done:
			if got.code != 409 {
				t.Fatalf("stale consent inference: %d want 409: %s", got.code, got.body)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not finish")
		}
		var after app.Profile
		mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &after)
		if !reflect.DeepEqual(before, after) || calls.Load() != 1 {
			t.Fatalf("stale result applied: before=%+v after=%+v calls=%d", before, after, calls.Load())
		}
		if code, body := request("POST", p+"/infer", a.AccessToken, in); code != 409 || calls.Load() != 1 {
			t.Fatalf("invalidated request retried: %d calls=%d: %s", code, calls.Load(), body)
		}
		var state string
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&state); e != nil || state != "invalidated" {
			t.Fatalf("stale request state: %q %v", state, e)
		}
	})

	runBlockedAuthorization := func(t *testing.T, a app.Tokens, c app.Contact, change, restore func()) {
		t.Helper()
		p := "contacts/" + c.Id.String()
		var before app.Profile
		mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &before)
		started := make(chan struct{}, 1)
		release := make(chan struct{})
		var releaseOnce sync.Once
		unblock := func() { releaseOnce.Do(func() { close(release) }) }
		defer unblock()
		var calls atomic.Int32
		var guardErr error
		var dispatched bool
		s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			calls.Add(1)
			select {
			case started <- struct{}{}:
			default:
			}
			select {
			case <-release:
				if call.BeforeAttempt == nil {
					guardErr = errors.New("inference dispatch has no authorization guard")
					return gateway.Reply{}, guardErr
				}
				guardErr = call.BeforeAttempt(ctx)
				if guardErr != nil {
					return gateway.Reply{}, guardErr
				}
				dispatched = true
				return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(`{"choices":[1,1,1,1,1,1,0]}`)}}, nil
			case <-ctx.Done():
				return gateway.Reply{}, ctx.Err()
			}
		})
		in := app.InferProfileInput{RequestId: uuid.New(), ChatText: "只用于内存的合成授权反例"}
		type result struct {
			code int
			body []byte
		}
		done := make(chan result, 1)
		go func() {
			code, body := request("POST", p+"/infer", a.AccessToken, in)
			done <- result{code, body}
		}()
		select {
		case <-started:
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not start")
		}
		change()
		unblock()
		select {
		case got := <-done:
			if got.code != 409 {
				t.Fatalf("authorization change: %d want 409: %s", got.code, got.body)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not finish")
		}
		if !errors.Is(guardErr, membership.ErrConflict) || dispatched || calls.Load() != 1 {
			t.Fatalf("guard err=%v dispatched=%v calls=%d", guardErr, dispatched, calls.Load())
		}
		var after app.Profile
		mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &after)
		if !reflect.DeepEqual(before, after) {
			t.Fatalf("authorization change applied stale profile: before=%+v after=%+v", before, after)
		}
		restore()
		if code, body := request("POST", p+"/infer", a.AccessToken, in); code != 409 || calls.Load() != 1 {
			t.Fatalf("invalidated request replayed: %d calls=%d: %s", code, calls.Load(), body)
		}
		var state string
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&state); e != nil || state != "invalidated" {
			t.Fatalf("authorization-change state: %q %v", state, e)
		}
	}

	t.Run("contacts withdrawal blocks dispatch", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		c := create(a.AccessToken)
		runBlockedAuthorization(t, a, c,
			func() { grant(a.AccessToken, "contacts", false) },
			func() { grant(a.AccessToken, "contacts", true) },
		)
	})

	t.Run("contacts regrant invalidates in-flight inference", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		c := create(a.AccessToken)
		runBlockedAuthorization(t, a, c,
			func() {
				grant(a.AccessToken, "contacts", false)
				grant(a.AccessToken, "contacts", true)
			},
			func() {},
		)
	})

	t.Run("read-only contact blocks dispatch", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		first := create(a.AccessToken)
		exec(`with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '2 days',now()+interval '1 day' from o`, a.UserId, []byte(uuid.NewString()))
		second := create(a.AccessToken)
		mustCall("POST", "contacts/"+first.Id.String()+"/activate", a.AccessToken, nil, 200, nil)
		runBlockedAuthorization(t, a, second,
			func() {
				exec(`update entitlements set ends_at=now()-interval '1 day' where user_id=$1`, a.UserId)
				var people app.ListContactsResult
				mustCall("GET", "contacts", a.AccessToken, nil, 200, &people)
				for _, v := range people.Items {
					if v.Id == second.Id && v.Editable {
						t.Fatal("expired membership left the non-default contact writable")
					}
				}
			},
			func() { exec(`update entitlements set ends_at=now()+interval '1 day' where user_id=$1`, a.UserId) },
		)
	})

	t.Run("client disconnect releases reservation for retry", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		c := create(a.AccessToken)
		p := "contacts/" + c.Id.String()
		started := make(chan struct{})
		var startedOnce sync.Once
		var calls atomic.Int32
		s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			if calls.Add(1) == 1 {
				startedOnce.Do(func() { close(started) })
				<-ctx.Done()
				return gateway.Reply{}, ctx.Err()
			}
			return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(`{"choices":[1,1,1,1,1,1,0]}`)}}, nil
		})
		in := app.InferProfileInput{RequestId: uuid.New(), ChatText: "只用于内存的断连重试材料"}
		reqCtx, cancel := context.WithCancel(context.Background())
		type result struct {
			code int
			body []byte
		}
		done := make(chan result, 1)
		go func() {
			code, body := requestWithContext(reqCtx, "POST", p+"/infer", a.AccessToken, in)
			done <- result{code, body}
		}()
		select {
		case <-started:
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not start")
		}
		var state string
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&state); e != nil || state != "processing" {
			t.Fatalf("pre-disconnect state: %q %v", state, e)
		}
		cancel()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			t.Fatal("canceled inference did not return")
		}
		var count int
		if e := s.db.QueryRow(ctx, `select count(*) from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&count); e != nil || count != 0 {
			t.Fatalf("canceled reservation survived: count=%d err=%v", count, e)
		}
		mustCall("POST", p+"/infer", a.AccessToken, in, 200, nil)
		if calls.Load() != 2 {
			t.Fatalf("retry calls=%d want 2", calls.Load())
		}
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&state); e != nil || state != "complete" {
			t.Fatalf("retry state: %q %v", state, e)
		}
	})

	t.Run("session refresh cleanup permits retry", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		c := create(a.AccessToken)
		p := "contacts/" + c.Id.String()
		started := make(chan struct{})
		release := make(chan struct{})
		var startedOnce, releaseOnce sync.Once
		unblock := func() { releaseOnce.Do(func() { close(release) }) }
		defer unblock()
		var calls atomic.Int32
		s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			if calls.Add(1) == 1 {
				startedOnce.Do(func() { close(started) })
				select {
				case <-release:
				case <-ctx.Done():
					return gateway.Reply{}, ctx.Err()
				}
			}
			if call.BeforeAttempt == nil {
				return gateway.Reply{}, errors.New("inference dispatch has no authorization guard")
			}
			if e := call.BeforeAttempt(ctx); e != nil {
				return gateway.Reply{}, e
			}
			return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(`{"choices":[1,1,1,1,1,1,0]}`)}}, nil
		})
		in := app.InferProfileInput{RequestId: uuid.New(), ChatText: "只用于内存的刷新重试材料"}
		type result struct {
			code int
			body []byte
		}
		done := make(chan result, 1)
		go func() {
			code, body := request("POST", p+"/infer", a.AccessToken, in)
			done <- result{code, body}
		}()
		select {
		case <-started:
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not start")
		}
		var rotated app.Tokens
		mustCall("POST", "auth/refresh", "", map[string]any{"refresh_token": a.RefreshToken}, 200, &rotated)
		unblock()
		select {
		case got := <-done:
			if got.code != 401 {
				t.Fatalf("expired inference session: %d want 401: %s", got.code, got.body)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not finish")
		}
		var count int
		if e := s.db.QueryRow(ctx, `select count(*) from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&count); e != nil || count != 0 {
			t.Fatalf("expired-session reservation survived: count=%d err=%v", count, e)
		}
		mustCall("POST", p+"/infer", rotated.AccessToken, in, 200, nil)
		if calls.Load() != 2 {
			t.Fatalf("retry calls=%d want 2", calls.Load())
		}
		var state string
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&state); e != nil || state != "complete" {
			t.Fatalf("refresh retry state: %q %v", state, e)
		}
	})

	t.Run("closure cleanup permits retry after unfreeze", func(t *testing.T) {
		subject := uuid.NewString()
		a := loginSubject(subject, true)
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		c := create(a.AccessToken)
		p := "contacts/" + c.Id.String()

		started := make(chan struct{})
		release := make(chan struct{})
		var startedOnce, releaseOnce sync.Once
		unblock := func() { releaseOnce.Do(func() { close(release) }) }
		defer unblock()
		var calls atomic.Int32
		s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			if calls.Add(1) == 1 {
				startedOnce.Do(func() { close(started) })
				select {
				case <-release:
				case <-ctx.Done():
					return gateway.Reply{}, ctx.Err()
				}
			}
			if call.BeforeAttempt == nil {
				return gateway.Reply{}, errors.New("inference dispatch has no authorization guard")
			}
			if e := call.BeforeAttempt(ctx); e != nil {
				return gateway.Reply{}, e
			}
			return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(`{"choices":[1,1,1,1,1,1,0]}`)}}, nil
		})
		in := app.InferProfileInput{RequestId: uuid.New(), ChatText: "只用于内存的注销冻结重试材料"}
		type result struct {
			code int
			body []byte
		}
		done := make(chan result, 1)
		go func() {
			code, body := request("POST", p+"/infer", a.AccessToken, in)
			done <- result{code, body}
		}()
		select {
		case <-started:
		case <-time.After(10 * time.Second):
			t.Fatal("inference did not start")
		}
		var state string
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&state); e != nil || state != "processing" {
			t.Fatalf("pre-closure state: %q %v", state, e)
		}

		// Freeze from a second verified credential while the first request is
		// blocked. This deletes its login session before the dispatch guard runs.
		mustCall("POST", "me/closure", a.AccessToken, map[string]any{"proof": proof(subject)}, 200, nil)
		unblock()
		select {
		case got := <-done:
			if got.code != 401 {
				t.Fatalf("frozen inference: %d want 401: %s", got.code, got.body)
			}
		case <-time.After(10 * time.Second):
			t.Fatal("frozen inference did not finish")
		}
		var count int
		if e := s.db.QueryRow(ctx, `select count(*) from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&count); e != nil || count != 0 {
			t.Fatalf("closure cleanup left reservation: count=%d err=%v", count, e)
		}

		// A recovery login is allowed during the cancellation window, then the
		// original request key can be retried after closure is cancelled.
		recovery := loginSubject(subject, false)
		mustCall("DELETE", "me/closure", recovery.AccessToken, nil, 200, nil)
		mustCall("POST", p+"/infer", recovery.AccessToken, in, 200, nil)
		if calls.Load() != 2 {
			t.Fatalf("post-unfreeze retry calls=%d want 2", calls.Load())
		}
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&state); e != nil || state != "complete" {
			t.Fatalf("post-unfreeze state: %q %v", state, e)
		}
	})

	t.Run("unused new contact does not take default", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		used := create(a.AccessToken)
		mustCall("POST", "contacts/"+used.Id.String()+"/activate", a.AccessToken, nil, 200, nil)
		exec(`with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '2 days',now()+interval '1 day' from o`, a.UserId, []byte(uuid.NewString()))
		unused := create(a.AccessToken)
		exec(`update entitlements set ends_at=now()-interval '1 day' where user_id=$1`, a.UserId)
		var people app.ListContactsResult
		mustCall("GET", "contacts", a.AccessToken, nil, 200, &people)
		for _, v := range people.Items {
			if v.Editable != (v.Id == used.Id) {
				t.Fatalf("unused contact took default: %+v", people.Items)
			}
			if v.Id == unused.Id && v.Editable {
				t.Fatalf("new unused contact is writable: %+v", v)
			}
		}
	})

	t.Run("terminal replies survive accompanying errors", func(t *testing.T) {
		for _, tc := range []struct {
			name     string
			terminal *gateway.Terminal
			status   int
			check    func(*testing.T, []byte)
		}{
			{
				name:     "crisis with audit failure",
				terminal: &gateway.Terminal{Safety: true, Message: gateway.HelpMessage},
				status:   200,
				check: func(t *testing.T, body []byte) {
					var safe app.Safety
					if e := json.Unmarshal(body, &safe); e != nil || !safe.Safety || safe.Message != gateway.HelpMessage {
						t.Fatalf("crisis body=%s err=%v", body, e)
					}
				},
			},
			{
				name:     "moderation unavailable with audit failure",
				terminal: &gateway.Terminal{Code: "moderation_unavailable", Retryable: true, Message: gateway.UnavailableMessage},
				status:   503,
				check: func(t *testing.T, body []byte) {
					var problem struct {
						Code      string `json:"code"`
						Retryable bool   `json:"retryable"`
					}
					if e := json.Unmarshal(body, &problem); e != nil || problem.Code != "moderation_unavailable" || !problem.Retryable {
						t.Fatalf("moderation body=%s err=%v", body, e)
					}
				},
			},
		} {
			t.Run(tc.name, func(t *testing.T) {
				a := signup()
				grant(a.AccessToken, "contacts", true)
				grant(a.AccessToken, "chat_import", true)
				c := create(a.AccessToken)
				p := "contacts/" + c.Id.String()
				var before app.Profile
				mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &before)
				s.Profiles.AI = profileRunner(func(context.Context, gateway.Call) (gateway.Reply, error) {
					return gateway.Reply{Terminal: tc.terminal}, errors.New("synthetic audit failure")
				})
				in := app.InferProfileInput{RequestId: uuid.New(), ChatText: "只用于内存的终止反例"}
				body := mustCall("POST", p+"/infer", a.AccessToken, in, tc.status, nil)
				tc.check(t, body)
				var after app.Profile
				mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &after)
				if !reflect.DeepEqual(before, after) {
					t.Fatalf("terminal reply saved profile: before=%+v after=%+v", before, after)
				}
				var count int
				if e := s.db.QueryRow(ctx, `select count(*) from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, in.RequestId).Scan(&count); e != nil || count != 0 {
					t.Fatalf("terminal reservation survived: count=%d err=%v", count, e)
				}
			})
		}
	})

	t.Run("completed retry does not overwrite newer inference", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		grant(a.AccessToken, "chat_import", true)
		c := create(a.AccessToken)
		p := "contacts/" + c.Id.String()
		var calls atomic.Int32
		s.Profiles.AI = profileRunner(func(context.Context, gateway.Call) (gateway.Reply, error) {
			choice := "1"
			if calls.Add(1) == 2 {
				choice = "2"
			}
			object := fmt.Sprintf(`{"choices":[%s,%s,%s,%s,%s,%s,0]}`, choice, choice, choice, choice, choice, choice)
			return gateway.Reply{Result: gateway.Result{Object: json.RawMessage(object)}}, nil
		})
		first := app.InferProfileInput{RequestId: uuid.New(), ChatText: "同一份内存合成材料"}
		second := app.InferProfileInput{RequestId: uuid.New(), ChatText: first.ChatText}
		var firstProfile app.Profile
		mustCall("POST", p+"/infer", a.AccessToken, first, 200, &firstProfile)
		var latest app.Profile
		mustCall("POST", p+"/infer", a.AccessToken, second, 200, &latest)
		var replay app.Profile
		mustCall("POST", p+"/infer", a.AccessToken, first, 200, &replay)
		if calls.Load() != 2 || !reflect.DeepEqual(replay, latest) {
			t.Fatalf("completed request regenerated: calls=%d replay=%+v latest=%+v", calls.Load(), replay, latest)
		}
		changed := first
		changed.ChatText = "不同的内存合成材料"
		if code, body := request("POST", p+"/infer", a.AccessToken, changed); code != 409 || calls.Load() != 2 {
			t.Fatalf("same request id accepted different input: %d calls=%d: %s", code, calls.Load(), body)
		}
		var state string
		if e := s.db.QueryRow(ctx, `select state from profile_inference_requests where user_id=$1 and request_id=$2`, a.UserId, first.RequestId).Scan(&state); e != nil || state != "complete" {
			t.Fatalf("completed request state: %q %v", state, e)
		}
	})

	t.Run("self feedback uses immutable activity scene", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		c := create(a.AccessToken)
		p := "contacts/" + c.Id.String()
		// The mutable contact scene deliberately disagrees with the source
		// activity scene throughout this regression.
		mustCall("PATCH", p, a.AccessToken, map[string]string{"nickname": c.Nickname, "scene": "friends"}, 200, nil)
		exec(`with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '2 days',now()+interval '1 day' from o`, a.UserId, []byte(uuid.NewString()))

		// Standalone T25 fixture: reproduce T23's authenticated journal and
		// matching score row, but do not write any T25 context or observation.
		reviewSource := func(contact *uuid.UUID, submitted string, withScore bool) (uuid.UUID, uuid.UUID) {
			t.Helper()
			activity, src := uuid.New(), uuid.New()
			enc, e := s.Fields.Seal([]byte(`{"submitted":`+submitted+`,"repair_phrase":"合成修复话"}`),
				[]byte("review/v1/"+a.UserId.String()+"/"+activity.String()+"/journal"))
			if e != nil {
				t.Fatal(e)
			}
			exec(`insert into activities(id,user_id,source_id,kind,contact_id,state,content_enc) values($1,$2,$3,'review',$4,'complete',$5)`, activity, a.UserId, src, contact, enc)
			if withScore {
				exec(`insert into scores(id,activity_id,activity_kind,detail_enc) values($1,$2,'review',$3)`, src, activity, []byte{1})
			}
			return activity, src
		}
		note := "本人上头"
		activity, src := reviewSource(&c.Id, `{"scene":"work","happened":"合成日记"}`, true)
		in := app.SendProfileFeedbackInput{SourceId: src, Subject: "self", Confirmed: true, Note: &note}
		missingScoreActivity, missingScore := reviewSource(&c.Id, `{"scene":"work"}`, false)
		unfinishedActivity, unfinished := reviewSource(&c.Id, `{"scene":"work"}`, true)
		exec(`update activities set state='pending' where id=$1`, unfinishedActivity)
		swappedActivity, swapped := reviewSource(&c.Id, `{"scene":"work"}`, true)
		exec(`update activities set content_enc=(select content_enc from activities where id=$1) where id=$2`, activity, swappedActivity)
		for _, bad := range []struct {
			activity, source uuid.UUID
			status           int
		}{
			{missingScoreActivity, missingScore, 404},
			{unfinishedActivity, unfinished, 404},
			{swappedActivity, swapped, 500},
		} {
			wrong := in
			wrong.SourceId = bad.source
			mustCall("POST", "profiles/feedback", a.AccessToken, wrong, bad.status, nil)
			var written bool
			if e := s.db.QueryRow(ctx, `select exists(select from profile_observations where activity_id=$1) or exists(select from activity_profile_context where activity_id=$1)`, bad.activity).Scan(&written); e != nil || written {
				t.Fatalf("untrusted review wrote profile data: %t, err=%v", written, e)
			}
		}
		mustCall("POST", "profiles/feedback", a.AccessToken, in, 200, nil)
		var groups app.EmotionSummaryResult
		mustCall("GET", "emotion-summary", a.AccessToken, nil, 200, &groups)
		if len(groups.Groups) != 1 {
			t.Fatalf("self feedback groups=%+v want one", groups.Groups)
		}
		g := groups.Groups[0]
		if g.ContactId == nil || *g.ContactId != c.Id || g.Scene == nil || *g.Scene != "work" || g.ConfirmedSelfCount != 1 || g.ManualCount != 0 {
			t.Fatalf("self feedback lost activity scene: %+v", g)
		}

		// Editing the contact must not rewrite the frozen source context or turn
		// an exact replay into a conflict.
		mustCall("PATCH", p, a.AccessToken, map[string]string{"nickname": c.Nickname, "scene": "partner"}, 200, nil)
		mustCall("POST", "profiles/feedback", a.AccessToken, in, 200, nil)
		groups = app.EmotionSummaryResult{}
		mustCall("GET", "emotion-summary", a.AccessToken, nil, 200, &groups)
		if len(groups.Groups) != 1 {
			t.Fatalf("replayed self feedback groups=%+v want one", groups.Groups)
		}
		g = groups.Groups[0]
		if g.ContactId == nil || *g.ContactId != c.Id || g.Scene == nil || *g.Scene != "work" || g.ConfirmedSelfCount != 1 {
			t.Fatalf("contact edit changed replayed self feedback: %+v", g)
		}

		// A contactless review retains its source scene, and an associated
		// review without a scene does not fall back to the contact's scene.
		_, in.SourceId = reviewSource(nil, `{"scene":"work"}`, true)
		mustCall("POST", "profiles/feedback", a.AccessToken, in, 200, nil)
		_, in.SourceId = reviewSource(&c.Id, `{"happened":"合成无场景日记"}`, true)
		mustCall("POST", "profiles/feedback", a.AccessToken, in, 200, nil)
		mustCall("POST", "profiles/feedback", a.AccessToken, in, 200, nil)
		groups = app.EmotionSummaryResult{}
		mustCall("GET", "emotion-summary", a.AccessToken, nil, 200, &groups)
		if len(groups.Groups) != 3 {
			t.Fatalf("self feedback groups=%+v want three", groups.Groups)
		}
		var foundContactless, foundSceneless bool
		for _, g := range groups.Groups {
			if g.ConfirmedSelfCount != 1 {
				t.Fatalf("unexpected group count: %+v", g)
			}
			foundContactless = foundContactless || g.ContactId == nil && g.Scene != nil && *g.Scene == "work"
			foundSceneless = foundSceneless || g.ContactId != nil && *g.ContactId == c.Id && g.Scene == nil
		}
		if !foundContactless || !foundSceneless {
			t.Fatalf("lost source context: %+v", groups.Groups)
		}
	})

	t.Run("scene change hides historical partner attachment", func(t *testing.T) {
		a := signup()
		grant(a.AccessToken, "contacts", true)
		c := create(a.AccessToken)
		p := "contacts/" + c.Id.String()
		src := uuid.New()
		activity := uuid.New()
		if _, e := s.db.Exec(ctx, `insert into activities(id,user_id,source_id,kind,contact_id,state) values($1,$2,$3,'reply',$4,'complete')`, activity, a.UserId, src, c.Id); e != nil {
			t.Fatal(e)
		}
		ev := events.Feedback{UserID: a.UserId, SourceID: src, FeedbackID: uuid.New(), Subject: "contact", SourceKind: "reply", OccurredAt: time.Now().UTC().Truncate(time.Microsecond), ContactID: &c.Id}
		if e := s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error { return s.Profiles.RecordActivity(ctx, tx, ev, "希望收到回复", "partner") }); e != nil {
			t.Fatal(e)
		}
		if e := s.Bus.PublishFeedback(ctx, ev); e != nil {
			t.Fatal(e)
		}
		var partner app.Profile
		mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &partner)
		if partner.Attachment == nil || !strings.Contains(partner.Summary, "联系减少") {
			t.Fatalf("partner evidence missing: %+v", partner)
		}
		mustCall("PATCH", p, a.AccessToken, map[string]string{"nickname": c.Nickname, "scene": "work"}, 200, nil)
		var work app.Profile
		mustCall("GET", p+"/summary", a.AccessToken, nil, 200, &work)
		if work.Attachment != nil || strings.Contains(work.Summary, "联系减少") {
			t.Fatalf("historical partner evidence leaked after scene change: %+v", work)
		}
		var model app.Profile
		if e := s.Data.Access(ctx, a.UserId, func(tx pgx.Tx) error {
			var e error
			model, e = s.Profiles.ForModel(ctx, tx, a.UserId, c.Id)
			return e
		}); e != nil {
			t.Fatal(e)
		}
		if model.Attachment != nil || strings.Contains(model.Summary, "联系减少") {
			t.Fatalf("historical partner evidence leaked into model summary: %+v", model)
		}
		var archive bytes.Buffer
		if e := s.Data.Export(ctx, privacy.ExportRequest{UserID: a.UserId, OperationID: uuid.New()}, &archive); e != nil {
			t.Fatal(e)
		}
		z, e := zip.NewReader(bytes.NewReader(archive.Bytes()), int64(archive.Len()))
		if e != nil {
			t.Fatal(e)
		}
		f, e := z.Open("profiles.json")
		if e != nil {
			t.Fatal(e)
		}
		exported, e := io.ReadAll(f)
		f.Close()
		if e != nil {
			t.Fatal(e)
		}
		if bytes.Contains(exported, []byte("联系减少")) {
			t.Fatalf("historical partner evidence leaked into export: %s", exported)
		}
	})
}
