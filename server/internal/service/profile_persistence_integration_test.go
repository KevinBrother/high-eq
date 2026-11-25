//go:build integration

package service

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
)

const profilePersistenceMaterial = "T35-SYNTHETIC-PERSISTENCE-CHAT"
const profileLateChoices = `{"choices":[2,2,1,2,0,0,0]}`

type profilePersistenceFixture struct {
	t           *testing.T
	ctx         context.Context
	s           *Runtime
	start       func() *Runtime
	stop        func()
	router      http.Handler
	calls       atomic.Int32
	fail        atomic.Bool
	lateChoices atomic.Bool
	modelHold   atomic.Pointer[func(context.Context) error]
}

func newProfilePersistenceFixture(t *testing.T) *profilePersistenceFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	t.Cleanup(cancel)
	f := &profilePersistenceFixture{t: t, ctx: ctx}
	f.s, f.start, f.stop = reviewRuntimeWithRestartableVendor(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Stream   bool
			Messages []gateway.Message
		}
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil || len(in.Messages) != 2 {
			t.Error("invalid synthetic profile call")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.calls.Add(1)
		if !in.Stream {
			if f.fail.Load() {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			fmt.Fprintf(w, `{"choices":[{"message":{"content":%q},"finish_reason":"stop"}]}`, `{"verdict":"allow"}`)
			return
		}
		if in.Messages[1].Content != profilePersistenceMaterial {
			t.Error("unbound material reached generation")
		}
		if hold := f.modelHold.Load(); hold != nil {
			if err := (*hold)(r.Context()); err != nil {
				return
			}
		}
		choices := `{"choices":[1,1,2,1,0,0,0]}`
		if f.lateChoices.Swap(false) {
			choices = profileLateChoices
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q},\"finish_reason\":\"stop\"}]}\n\n", choices)
		fmt.Fprint(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n")
	}), map[admin.Task]uuid.UUID{admin.TaskProfileInference: uuid.MustParse("b935fb60-5a85-4c12-82c0-401afd649325")})
	f.router = f.s.Router()
	f.exec(f.s, `update model_configs set input_cny_per_million=1000,output_cny_per_million=2000
		where id in (select primary_model from model_routes where task='profile_inference')`)
	return f
}

func (f *profilePersistenceFixture) must(err error) {
	f.t.Helper()
	if err != nil {
		f.t.Fatal(err)
	}
}

func (f *profilePersistenceFixture) exec(s *Runtime, sql string, args ...any) {
	f.t.Helper()
	_, err := s.db.Exec(f.ctx, sql, args...)
	f.must(err)
}

func profilePersistenceRequest(ctx context.Context, router http.Handler, token, method, path string, body any) *httptest.ResponseRecorder {
	data, err := json.Marshal(body)
	if err != nil {
		panic(err)
	}
	r := httptest.NewRequestWithContext(ctx, method, "/v1/"+path, bytes.NewReader(data))
	r.Header.Set("Authorization", "Bearer "+token)
	r.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	router.ServeHTTP(w, r)
	return w
}

func (f *profilePersistenceFixture) check(w *httptest.ResponseRecorder, want int, out any) {
	f.t.Helper()
	if w.Code != want {
		f.t.Fatalf("HTTP status = %d, want %d", w.Code, want)
	}
	if out != nil {
		t35Decode(f.t, w.Body.Bytes(), out)
	}
}

func (f *profilePersistenceFixture) request(token, method, path string, body any, want int, out any) {
	f.t.Helper()
	f.check(profilePersistenceRequest(f.ctx, f.router, token, method, path, body), want, out)
}

func (f *profilePersistenceFixture) proof(s *Runtime, subject string) map[string]string {
	f.t.Helper()
	ticket := uuid.NewString()
	f.must(s.cache.Set(f.ctx, "dev:ticket:apple:"+ticket, subject, time.Minute).Err())
	return map[string]string{"provider": "apple", "proof": ticket}
}

func (f *profilePersistenceFixture) login(s *Runtime, subject string) app.Tokens {
	f.t.Helper()
	var a app.Tokens
	f.request("", "POST", "auth/login", map[string]any{
		"credential": f.proof(s, subject), "age_confirmed": true,
		"privacy_version": "2026-11", "terms_version": "2026-11",
	}, 200, &a)
	return a
}

func (f *profilePersistenceFixture) grant(token, purpose string, granted bool) {
	f.t.Helper()
	f.request(token, "PUT", "me/consents/"+purpose, map[string]any{"version": accounts.ContactNoticeVersion, "granted": granted}, 200, nil)
}

func (f *profilePersistenceFixture) contact(token string) string {
	f.t.Helper()
	var c app.Contact
	f.request(token, "POST", "contacts", map[string]string{"nickname": "合成关系人", "scene": "partner"}, 200, &c)
	return "contacts/" + c.Id.String()
}

type profileReservationState struct {
	state string
	owner uuid.NullUUID
	live  bool
}

func (f *profilePersistenceFixture) reservation(s *Runtime, user, request uuid.UUID) profileReservationState {
	f.t.Helper()
	var row profileReservationState
	f.must(s.db.QueryRow(f.ctx, `select state,owner_id,coalesce(lease_expires_at>clock_timestamp(),false)
		from profile_inference_requests where user_id=$1 and request_id=$2`, user, request).Scan(&row.state, &row.owner, &row.live))
	return row
}

func (f *profilePersistenceFixture) expire(s *Runtime, user, request uuid.UUID) {
	f.t.Helper()
	tag, err := s.db.Exec(f.ctx, `update profile_inference_requests set lease_expires_at=clock_timestamp()-interval '1 second'
		where user_id=$1 and request_id=$2 and state='processing'`, user, request)
	f.must(err)
	if tag.RowsAffected() != 1 {
		f.t.Fatal("expected one interrupted reservation")
	}
}

type profileMetering struct {
	calls, failedReview, generated, input, output, quota int
	cost                                                 float64
}

func (f *profilePersistenceFixture) metering(s *Runtime, user, request uuid.UUID) profileMetering {
	f.t.Helper()
	var m profileMetering
	f.must(s.db.QueryRow(f.ctx, `select count(*),count(*) filter(where outcome='moderation_unavailable'),
		count(*) filter(where prompt_version_id is not null and outcome='ok'),
		coalesce(sum(input_tokens),0),coalesce(sum(output_tokens),0),coalesce(sum(cost_cny),0)::float8,
		(select coalesce(sum(used),0) from daily_quota_usage where user_id=$1)
		from ai_calls where user_id=$1 and operation_id=$2 and task='profile_inference'`, user, request).
		Scan(&m.calls, &m.failedReview, &m.generated, &m.input, &m.output, &m.cost, &m.quota))
	return m
}

func (f *profilePersistenceFixture) pending(token, path string, input app.InferProfileInput) {
	f.t.Helper()
	var pending struct {
		RequestID uuid.UUID `json:"request_id"`
		Status    string    `json:"status"`
	}
	f.request(token, "POST", path, input, 202, &pending)
	if pending.RequestID != input.RequestId || pending.Status != "in_progress" {
		f.t.Fatal("202 did not identify the submitting account's pending request")
	}
}

func (f *profilePersistenceFixture) requireUnavailable(token, path string, input app.InferProfileInput) {
	f.t.Helper()
	var problem app.Error
	f.request(token, "POST", path, input, 503, &problem)
	if problem.Code != "moderation_unavailable" || !problem.Retryable {
		f.t.Fatalf("unexpected cleanup-failure response code %q, retryable=%t", problem.Code, problem.Retryable)
	}
}

func (f *profilePersistenceFixture) startInference(router http.Handler, token, path string, input app.InferProfileInput) <-chan *httptest.ResponseRecorder {
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- profilePersistenceRequest(f.ctx, router, token, "POST", path, input) }()
	return done
}

func awaitProfileStep[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case step := <-ch:
		return step
	case <-time.After(8 * time.Second):
		t.Fatal("profile inference did not reach the expected step")
		var zero T
		return zero
	}
}

// The pause is at the service/gateway boundary, outside any account or
// connection lock. It lets the test move the database clock predicate without
// waiting for the production lease or changing it globally.
func holdProfileAttempt(t *testing.T) (<-chan struct{}, func(), func(context.Context) error) {
	t.Helper()
	entered, release := make(chan struct{}), make(chan struct{})
	resume := sync.OnceFunc(func() { close(release) })
	t.Cleanup(resume)
	return entered, resume, func(ctx context.Context) error {
		close(entered)
		select {
		case <-release:
			return nil
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func TestProfileInferenceRecoversInterruptedExecution(t *testing.T) {
	f := newProfilePersistenceFixture(t)
	old := f.s
	subject := uuid.NewString()
	a := f.login(old, subject)
	f.grant(a.AccessToken, "contacts", true)
	f.grant(a.AccessToken, "chat_import", true)
	f.exec(old, `with o as (
		insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state)
		values($1,'apple',$2,'t35-persistence-fixture',1,'paid') returning id,user_id
	) insert into entitlements(order_id,user_id,starts_at,ends_at)
	select id,user_id,now()-interval '1 minute',now()+interval '1 hour' from o`, a.UserId, []byte(uuid.NewString()))
	contact := f.contact(a.AccessToken)
	otherPath := f.contact(a.AccessToken) + "/infer"
	path := contact + "/infer"
	input := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	changed := input
	changed.ChatText += "-REPLACEMENT"

	// PostgreSQL rejects only this request's release, after the real gateway
	// has persisted the failed moderation attempt.
	f.exec(old, `create function t35_fail_profile_release() returns trigger language plpgsql as $$
		begin raise exception 'synthetic profile release failure'; end $$`)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := old.db.Exec(ctx, `drop function if exists t35_fail_profile_release() cascade`); err != nil {
			t.Error(err)
		}
	})
	f.exec(old, fmt.Sprintf(`create trigger t35_fail_profile_release before update on profile_inference_requests
		for each row when (old.request_id = '%s'::uuid and old.state = 'processing' and new.state = 'retryable')
		execute function t35_fail_profile_release()`, input.RequestId))
	f.fail.Store(true)
	f.requireUnavailable(a.AccessToken, path, input)
	f.fail.Store(false)
	interrupted := f.reservation(old, a.UserId, input.RequestId)
	if interrupted.state != "processing" || !interrupted.owner.Valid || !interrupted.live {
		t.Fatal("cleanup injection did not leave a live persisted reservation")
	}
	failed := profileMetering{calls: 1, failedReview: 1}
	if got := f.metering(old, a.UserId, input.RequestId); got != failed || f.calls.Load() != 1 {
		t.Fatalf("first failure metering = %+v; dispatches=%d", got, f.calls.Load())
	}
	f.exec(old, `drop trigger t35_fail_profile_release on profile_inference_requests`)

	// A replacement runtime has a new pool and catalog, and sees only the
	// durable binding. The prior runtime is retained to deliver stale work.
	next := f.start()
	f.router = next.Router()
	relogged := f.login(next, subject)
	if relogged.UserId != a.UserId || relogged.AccessToken == a.AccessToken {
		t.Fatal("replacement instance did not establish a fresh session for the same account")
	}
	f.pending(relogged.AccessToken, path, input)
	f.request(relogged.AccessToken, "POST", path, changed, 409, nil)
	f.expire(next, a.UserId, input.RequestId)
	f.request(relogged.AccessToken, "POST", path, changed, 409, nil)
	f.request(relogged.AccessToken, "POST", otherPath, input, 409, nil)
	if got := f.metering(next, a.UserId, input.RequestId); got != failed || f.calls.Load() != 1 {
		t.Fatalf("pending or mismatched requests reached routing: %+v; dispatches=%d", got, f.calls.Load())
	}

	entered, resume, hold := holdProfileAttempt(t)
	nextAI := next.Profiles.AI
	next.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
		if err := hold(ctx); err != nil {
			return gateway.Reply{}, err
		}
		return nextAI.Run(ctx, call)
	})
	done := f.startInference(f.router, relogged.AccessToken, path, input)
	awaitProfileStep(t, entered)
	replacement := f.reservation(next, a.UserId, input.RequestId)
	if replacement.state != "processing" || !replacement.live || !replacement.owner.Valid || replacement.owner == interrupted.owner {
		t.Fatal("retry did not acquire a distinct owner")
	}
	f.request(relogged.AccessToken, "POST", path, changed, 409, nil)
	f.pending(relogged.AccessToken, path, input)
	contactID := uuid.MustParse(contact[len("contacts/"):])
	f.must(old.Data.ReleaseProfileInference(f.ctx, a.UserId, contactID, input.RequestId, interrupted.owner.UUID))
	if got := f.reservation(next, a.UserId, input.RequestId); got != replacement {
		t.Fatal("stale cleanup altered the replacement reservation")
	}
	resume()
	var saved, replay app.Profile
	f.check(awaitProfileStep(t, done), 200, &saved)
	next.Profiles.AI = nextAI
	f.request(relogged.AccessToken, "POST", path, input, 200, &replay)
	if !reflect.DeepEqual(saved, replay) || f.reservation(next, a.UserId, input.RequestId) != (profileReservationState{state: "complete"}) {
		t.Fatal("completed retry was not read back from storage")
	}
	success := profileMetering{calls: 4, failedReview: 1, generated: 1, input: 12, output: 3, cost: 0.018}
	if got := f.metering(next, a.UserId, input.RequestId); got != success || f.calls.Load() != 4 {
		t.Fatalf("recovery or replay metering = %+v; dispatches=%d", got, f.calls.Load())
	}
	f.requirePrivateProfileGroup(relogged.AccessToken, input, changed.ChatText, interrupted.owner.UUID, replacement.owner.UUID)
	f.requireLateProfileCompletionIsFenced(old, next, a, relogged, contact)
}

func (f *profilePersistenceFixture) requireLateProfileCompletionIsFenced(old, next *Runtime, a, relogged app.Tokens, contact string) {
	f.t.Helper()
	path := contact + "/infer"
	input := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
	entered, resume, hold := holdProfileAttempt(f.t)
	f.lateChoices.Store(true)
	oldAI := old.Profiles.AI
	old.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
		reply, err := oldAI.Run(ctx, call)
		if err != nil || reply.Terminal != nil || string(reply.Result.Object) != profileLateChoices {
			f.t.Error("stale execution failed to generate its distinct approved profile")
			return reply, err
		}
		return reply, hold(ctx)
	})
	priorDispatches := f.calls.Load()
	done := f.startInference(old.Router(), a.AccessToken, path, input)
	awaitProfileStep(f.t, entered)
	one := profileMetering{calls: 3, generated: 1, input: 12, output: 3, cost: 0.018}
	if got := f.metering(next, a.UserId, input.RequestId); got != one || f.calls.Load() != priorDispatches+3 {
		f.t.Fatalf("after old Gateway.Run: %+v; dispatches=%d", got, f.calls.Load()-priorDispatches)
	}
	if row := f.reservation(next, a.UserId, input.RequestId); row.state != "processing" || !row.live || !row.owner.Valid {
		f.t.Fatalf("old execution must still own a live reservation: %+v", row)
	}
	f.pending(relogged.AccessToken, path, input)
	f.expire(next, a.UserId, input.RequestId)
	var saved, after, replay app.Profile
	f.request(relogged.AccessToken, "POST", path, input, 200, &saved)
	resume()
	f.check(awaitProfileStep(f.t, done), 409, nil)
	old.Profiles.AI = oldAI
	f.request(relogged.AccessToken, "GET", contact+"/summary", nil, 200, &after)
	f.request(relogged.AccessToken, "POST", path, input, 200, &replay)
	if !reflect.DeepEqual(saved, after) || !reflect.DeepEqual(saved, replay) ||
		f.reservation(next, a.UserId, input.RequestId) != (profileReservationState{state: "complete"}) {
		f.t.Fatal("late result or replay changed the completed replacement")
	}
	want := profileMetering{calls: 6, generated: 2, input: 24, output: 6, cost: 0.036}
	if got := f.metering(next, a.UserId, input.RequestId); got != want || f.calls.Load() != priorDispatches+6 {
		f.t.Fatalf("after replacement, old 409 and replay: %+v; dispatches=%d", got, f.calls.Load()-priorDispatches)
	}
	f.t.Log("old Gateway.Run returned with 3 committed attempts and 0.018 CNY; replacement 200; old write 409; replay 200; final 6 attempts and 0.036 CNY")
}

func (f *profilePersistenceFixture) requirePrivateProfileGroup(token string, input app.InferProfileInput, changed string, owners ...uuid.UUID) {
	f.t.Helper()
	archive := t35Download(f.t, f.router, token)
	digest := sha256.Sum256([]byte(input.ChatText))
	forbidden := []string{input.RequestId.String(), input.ChatText, changed, `"input_digest"`, hex.EncodeToString(digest[:])}
	for _, owner := range owners {
		forbidden = append(forbidden, owner.String())
	}
	for _, entry := range archive.File {
		r, err := entry.Open()
		f.must(err)
		body, err := io.ReadAll(r)
		f.must(r.Close())
		f.must(err)
		t35Exclude(f.t, []byte(entry.Name), forbidden...)
		t35Exclude(f.t, body, forbidden...)
	}
	var calls []struct {
		Group   uuid.UUID `json:"operation_id"`
		Task    string    `json:"task"`
		Outcome string    `json:"outcome"`
	}
	t35Decode(f.t, t35Part(f.t, archive, "ai_calls"), &calls)
	if len(calls) != 4 || calls[0].Group.Version() != 8 {
		f.t.Fatal("recovery did not export one opaque group for four attempts")
	}
	outcomes := map[string]int{}
	for _, call := range calls {
		if call.Task != "profile_inference" || call.Group != calls[0].Group {
			f.t.Fatal("recovery attempts split into different export groups")
		}
		outcomes[call.Outcome]++
	}
	if !reflect.DeepEqual(outcomes, map[string]int{"ok": 3, "moderation_unavailable": 1}) {
		f.t.Fatalf("unexpected exported outcomes: %v", outcomes)
	}
}
