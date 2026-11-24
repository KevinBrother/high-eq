//go:build integration

package service

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
)

func TestProfileActiveReentryBehindAuthorize(t *testing.T) {
	f := newProfilePersistenceFixture(t)
	account := f.login(f.s, uuid.NewString())
	f.grant(account.AccessToken, "contacts", true)
	f.grant(account.AccessToken, "chat_import", true)
	f.exec(f.s, `with o as (
		insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
		values($1,'apple',$2,'t35-active-reentry',1,'paid') returning id,user_id
	) insert into entitlements(order_id,user_id,starts_at,ends_at)
	select id,user_id,now()-interval '1 minute',now()+interval '1 hour' from o`, account.UserId, []byte(uuid.NewString()))
	contact := f.contact(account.AccessToken)
	sibling := f.contact(account.AccessToken)
	path := contact + "/infer"
	input := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	differentMaterial := app.InferProfileInput{RequestId: input.RequestId, ChatText: profilePersistenceMaterial + "-DIFFERENT"}

	invalidated := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	digest := sha256.Sum256([]byte(invalidated.ChatText))
	f.exec(f.s, `insert into profile_inference_requests(
		user_id,request_id,contact_id,chat_consent_id,contacts_consent_id,input_digest,state)
		select $1,$2,$3,chat.id,contacts.id,$4,'invalidated'
		from (select id from consents where user_id=$1 and purpose='chat_import' and withdrawn_at is null
			order by granted_at desc,id desc limit 1) chat
		cross join (select id from consents where user_id=$1 and purpose='contacts' and withdrawn_at is null
			order by granted_at desc,id desc limit 1) contacts`,
		account.UserId, invalidated.RequestId, uuid.MustParse(contact[len("contacts/"):]), digest[:])

	production := f.s.Profiles.AI
	entered, release := make(chan struct{}), make(chan struct{})
	resume := sync.OnceFunc(func() { close(release) })
	var holdOnce sync.Once
	f.s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
		authorize := call.Authorize
		call.Authorize = func(attemptCtx context.Context, tx pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			return authorize(attemptCtx, tx, func(sendCtx context.Context, tx pgx.Tx) error {
				holdOnce.Do(func() { close(entered) })
				select {
				case <-release:
				case <-sendCtx.Done():
					return sendCtx.Err()
				}
				return send(sendCtx, tx)
			})
		}
		return production.Run(ctx, call)
	})
	t.Cleanup(func() {
		f.s.Profiles.AI = production
		resume()
	})

	done := f.startInference(f.router, account.AccessToken, path, input)
	awaitProfileStep(t, entered)
	before := f.reservation(f.s, account.UserId, input.RequestId)
	if before.state != "processing" || !before.live || !before.owner.Valid {
		t.Fatalf("first request did not hold a live reservation: %+v", before)
	}
	meterBefore := f.metering(f.s, account.UserId, input.RequestId)
	callsBefore := f.calls.Load()

	pending := profileRequestWithin(t, f.router, account.AccessToken, path, input, 2*time.Second)
	if pending.Code != http.StatusAccepted {
		t.Fatalf("same active request status = %d, want 202; body=%s", pending.Code, pending.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(pending.Body.Bytes(), &body); err != nil || len(body) != 2 ||
		body["request_id"] != input.RequestId.String() || body["status"] != "in_progress" {
		t.Fatalf("pending response = %s, want exact request_id/status", pending.Body.String())
	}
	if got := f.reservation(f.s, account.UserId, input.RequestId); got != before {
		t.Fatalf("reentry changed the active reservation: before=%+v after=%+v", before, got)
	}
	if got := f.metering(f.s, account.UserId, input.RequestId); got != meterBefore || f.calls.Load() != callsBefore {
		t.Fatalf("reentry dispatched or charged: before=%+v after=%+v calls=%d", meterBefore, got, f.calls.Load()-callsBefore)
	}
	var consents app.ListConsentsResult
	consentsRead := profileReadWithin(t, f.router, account.AccessToken, "me/consents", &consents, 2*time.Second)
	if consentsRead.Code != http.StatusOK {
		t.Fatalf("active-request consent read status = %d, want 200; body=%s", consentsRead.Code, consentsRead.Body.String())
	}
	seenConsents := map[app.ConsentPurpose]bool{}
	for _, consent := range consents.Items {
		seenConsents[consent.Purpose] = consent.Granted
	}
	if !seenConsents["contacts"] || !seenConsents["chat_import"] {
		t.Fatalf("active-request consent read lost current grants: %+v", consents.Items)
	}

	for _, conflict := range []struct {
		name string
		path string
		in   app.InferProfileInput
	}{
		{"different-material", path, differentMaterial},
		{"different-contact", sibling + "/infer", input},
		{"invalidated", path, invalidated},
	} {
		t.Run(conflict.name, func(t *testing.T) {
			w := profileRequestWithin(t, f.router, account.AccessToken, conflict.path, conflict.in, 2*time.Second)
			if w.Code != http.StatusConflict {
				t.Fatalf("status = %d, want 409; body=%s", w.Code, w.Body.String())
			}
		})
	}
	if got := f.reservation(f.s, account.UserId, input.RequestId); got != before {
		t.Fatalf("conflicts changed the active reservation: before=%+v after=%+v", before, got)
	}
	if got := f.metering(f.s, account.UserId, input.RequestId); got != meterBefore || f.calls.Load() != callsBefore {
		t.Fatalf("conflicts dispatched or charged: before=%+v after=%+v calls=%d", meterBefore, got, f.calls.Load()-callsBefore)
	}

	resume()
	var first app.Profile
	f.check(awaitProfileStep(t, done), http.StatusOK, &first)
	afterFirst := f.metering(f.s, account.UserId, input.RequestId)
	callsAfterFirst := f.calls.Load()

	var replay app.Profile
	f.request(account.AccessToken, http.MethodPost, path, input, http.StatusOK, &replay)
	if string(mustJSON(t, replay)) != string(mustJSON(t, first)) {
		t.Fatal("completed replay did not return the original profile")
	}
	if got := f.metering(f.s, account.UserId, input.RequestId); got != afterFirst || f.calls.Load() != callsAfterFirst {
		t.Fatalf("completed replay dispatched or charged: before=%+v after=%+v calls=%d", afterFirst, got, f.calls.Load()-callsAfterFirst)
	}

	fresh := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	f.request(account.AccessToken, http.MethodPost, path, fresh, http.StatusOK, nil)
	if got := f.metering(f.s, account.UserId, fresh.RequestId); got == (profileMetering{}) || f.calls.Load() <= callsAfterFirst {
		t.Fatalf("new request key did not dispatch normally: %+v calls=%d", got, f.calls.Load()-callsAfterFirst)
	}

	rebound := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	seedProfileInferenceBinding(t, f, account.UserId, uuid.MustParse(contact[len("contacts/"):]), rebound.RequestId, "processing", true)
	callsBeforeRebind := f.calls.Load()
	f.grant(account.AccessToken, "chat_import", false)
	f.grant(account.AccessToken, "chat_import", true)
	w := profileRequestWithin(t, f.router, account.AccessToken, path, rebound, 2*time.Second)
	if w.Code != http.StatusConflict {
		t.Fatalf("live request with rebound consent status = %d, want 409; body=%s", w.Code, w.Body.String())
	}
	if got := f.metering(f.s, account.UserId, rebound.RequestId); got != (profileMetering{}) || f.calls.Load() != callsBeforeRebind {
		t.Fatalf("rebound consent dispatched or charged: metering=%+v dispatches=%d", got, f.calls.Load()-callsBeforeRebind)
	}
	t.Logf("active HTTP 202 returned without dispatch; conflicts=409; replay=200; new key=200; calls=%d", f.calls.Load())
}

func TestProfileReentryFallsBackForExpiredAndRetryable(t *testing.T) {
	f := newProfilePersistenceFixture(t)
	account := f.login(f.s, uuid.NewString())
	f.grant(account.AccessToken, "contacts", true)
	f.grant(account.AccessToken, "chat_import", true)
	f.exec(f.s, `with o as (
		insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
		values($1,'apple',$2,'t35-reentry-states',1,'paid') returning id,user_id
	) insert into entitlements(order_id,user_id,starts_at,ends_at)
	select id,user_id,now()-interval '1 minute',now()+interval '1 hour' from o`, account.UserId, []byte(uuid.NewString()))
	contact := f.contact(account.AccessToken)
	contactID := uuid.MustParse(contact[len("contacts/"):])
	path := contact + "/infer"

	for _, tc := range []struct {
		name  string
		state string
	}{
		{"expired-processing", "processing"},
		{"retryable", "retryable"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
			seedProfileInferenceBinding(t, f, account.UserId, contactID, input.RequestId, tc.state, false)
			callsBefore := f.calls.Load()
			var profile app.Profile
			f.request(account.AccessToken, http.MethodPost, path, input, http.StatusOK, &profile)
			if row := f.reservation(f.s, account.UserId, input.RequestId); row.state != "complete" || row.owner.Valid {
				t.Fatalf("reclaimed reservation = %+v, want completed without owner", row)
			}
			want := profileMetering{calls: 3, generated: 1, input: 12, output: 3, cost: 0.018}
			if got := f.metering(f.s, account.UserId, input.RequestId); got != want || f.calls.Load()-callsBefore != 3 {
				t.Fatalf("reclaimed metering = %+v, want %+v; dispatches=%d", got, want, f.calls.Load()-callsBefore)
			}
			callsAfter := f.calls.Load()
			f.request(account.AccessToken, http.MethodPost, path, input, http.StatusOK, nil)
			if got := f.metering(f.s, account.UserId, input.RequestId); got != want || f.calls.Load() != callsAfter {
				t.Fatalf("completed replay dispatched or charged: metering=%+v dispatches=%d", got, f.calls.Load()-callsAfter)
			}
		})
	}

	invalidated := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	seedProfileInferenceBinding(t, f, account.UserId, contactID, invalidated.RequestId, "invalidated", false)
	callsBefore := f.calls.Load()
	w := profileRequestWithin(t, f.router, account.AccessToken, path, invalidated, 2*time.Second)
	if w.Code != http.StatusConflict {
		t.Fatalf("invalidated status = %d, want 409; body=%s", w.Code, w.Body.String())
	}
	if got := f.metering(f.s, account.UserId, invalidated.RequestId); got != (profileMetering{}) || f.calls.Load() != callsBefore {
		t.Fatalf("invalidated request dispatched or charged: metering=%+v dispatches=%d", got, f.calls.Load()-callsBefore)
	}
}

func seedProfileInferenceBinding(t *testing.T, f *profilePersistenceFixture, user, contact, request uuid.UUID, state string, live bool) {
	t.Helper()
	digest := sha256.Sum256([]byte(profilePersistenceMaterial))
	owner := uuid.New()
	tag, err := f.s.db.Exec(f.ctx, `insert into profile_inference_requests(
		user_id,request_id,contact_id,chat_consent_id,contacts_consent_id,input_digest,state,owner_id,lease_expires_at)
		select $1,$2,$3,chat.id,contacts.id,$4,$5,
			case when $5='processing' then $6::uuid else null end,
			case when $5='processing' and $7 then clock_timestamp()+interval '1 hour'
				when $5='processing' then clock_timestamp()-interval '1 second' else null end
		from (select id from consents where user_id=$1 and purpose='chat_import' and withdrawn_at is null
			order by granted_at desc,id desc limit 1) chat
		cross join (select id from consents where user_id=$1 and purpose='contacts' and withdrawn_at is null
			order by granted_at desc,id desc limit 1) contacts`, user, request, contact, digest[:], state, owner, live)
	f.must(err)
	if tag.RowsAffected() != 1 {
		t.Fatalf("seeded %s inference binding affected %d rows", state, tag.RowsAffected())
	}
}

func profileRequestWithin(t *testing.T, router http.Handler, token, path string, input app.InferProfileInput, limit time.Duration) *httptest.ResponseRecorder {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	start := time.Now()
	w := profilePersistenceRequest(ctx, router, token, http.MethodPost, path, input)
	elapsed := time.Since(start)
	if elapsed >= limit {
		t.Fatalf("request did not complete before the %s lock budget: status=%d body=%s", limit, w.Code, w.Body.String())
	}
	return w
}

func profileReadWithin(t *testing.T, router http.Handler, token, path string, out any, limit time.Duration) *httptest.ResponseRecorder {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	start := time.Now()
	w := profilePersistenceRequest(ctx, router, token, http.MethodGet, path, nil)
	elapsed := time.Since(start)
	if elapsed >= limit {
		t.Fatalf("read did not complete before the %s lock budget: status=%d body=%s", limit, w.Code, w.Body.String())
	}
	if out != nil && w.Code == http.StatusOK {
		t35Decode(t, w.Body.Bytes(), out)
	}
	return w
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
