//go:build integration

package service

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
)

func TestProfileDispatchFences(t *testing.T) {
	f := newProfilePersistenceFixture(t)
	positive := profileMetering{calls: 3, generated: 1, input: 12, output: 3, cost: 0.018}
	for _, state := range []struct {
		name   string
		status int
	}{
		{"chat-withdrawal", 409},
		{"account-freeze", 401},
		{"contact-erasure-intent", 503},
		{"owner-replacement", 409},
	} {
		for _, inFlight := range []bool{false, true} {
			phase := "before-first-authorization"
			if inFlight {
				phase = "during-model-dispatch"
			}
			t.Run(state.name+"/"+phase, func(t *testing.T) {
				f.t = t
				subject := uuid.NewString()
				a := f.login(f.s, subject)
				other := f.login(f.s, uuid.NewString())
				for _, account := range []app.Tokens{a, other} {
					f.grant(account.AccessToken, "contacts", true)
					f.grant(account.AccessToken, "chat_import", true)
				}
				contact := f.contact(a.AccessToken)
				contactID := uuid.MustParse(contact[len("contacts/"):])
				path := contact + "/infer"
				otherPath := f.contact(other.AccessToken) + "/infer"
				input := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
				sibling := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
				f.request(a.AccessToken, http.MethodPost, path, sibling, 200, nil)
				f.request(other.AccessToken, http.MethodPost, otherPath, input, 200, nil)
				var encryptedBefore []byte
				f.must(f.s.db.QueryRow(f.ctx, `select profile_enc from contacts where id=$1`, contactID).Scan(&encryptedBefore))
				checkProfileDispatchFence(t, f, state.name, state.status, inFlight, subject, a, other, contact, otherPath, input, sibling, encryptedBefore, positive)
			})
		}
	}
}

func checkProfileDispatchFence(t *testing.T, f *profilePersistenceFixture, state string, status int, inFlight bool, subject string, account, other app.Tokens, contact, otherPath string, input, sibling app.InferProfileInput, encryptedBefore []byte, positive profileMetering) {
	t.Helper()
	path := contact + "/infer"
	contactID := uuid.MustParse(contact[len("contacts/"):])
	baseDispatches := f.calls.Load()
	nextOwner := uuid.New()
	waitingSQL := "select id from users where id="
	change := func() error { return nil }
	switch state {
	case "chat-withdrawal":
		change = func() error {
			w := profilePersistenceRequest(f.ctx, f.router, account.AccessToken, http.MethodPut, "me/consents/chat_import", map[string]any{"version": "v1", "granted": false})
			return profileDispatchStatus(w.Code, 200)
		}
	case "account-freeze":
		proof := f.proof(f.s, subject)
		change = func() error {
			w := profilePersistenceRequest(f.ctx, f.router, account.AccessToken, http.MethodPost, "me/closure", map[string]any{"proof": proof})
			return profileDispatchStatus(w.Code, 200)
		}
	case "contact-erasure-intent":
		// A target-specific deferred failure retains the committed intent and
		// Redis tombstone while rolling back the physical contact deletion.
		f.exec(f.s, `create function t35_profile_prevent_physical_delete() returns trigger language plpgsql
			as $$ begin raise exception 'synthetic retained erasure intent'; end $$`)
		t.Cleanup(func() {
			_, err := f.s.db.Exec(f.ctx, `drop function if exists t35_profile_prevent_physical_delete() cascade`)
			if err != nil {
				t.Error(err)
			}
		})
		f.exec(f.s, fmt.Sprintf(`create constraint trigger t35_profile_prevent_physical_delete after delete on contacts
			deferrable initially deferred for each row when (old.id = '%s'::uuid)
			execute function t35_profile_prevent_physical_delete()`, contactID))
		change = func() error {
			w := profilePersistenceRequest(f.ctx, f.router, account.AccessToken, http.MethodDelete, contact, nil)
			return profileDispatchStatus(w.Code, 500)
		}
	case "owner-replacement":
		waitingSQL = "update profile_inference_requests set owner_id="
		change = func() error {
			tag, err := f.s.db.Exec(f.ctx, `update profile_inference_requests set owner_id=$3
				where user_id=$1 and request_id=$2 and state='processing'`, account.UserId, input.RequestId, nextOwner)
			if err == nil && tag.RowsAffected() != 1 {
				return errors.New("synthetic owner replacement must update exactly one row")
			}
			return err
		}
	}
	authEntered, authResume, authHold := holdProfileAttempt(t)
	var modelEntered <-chan struct{}
	var modelResume func()
	if inFlight {
		entered, resume, hold := holdProfileAttempt(t)
		modelEntered, modelResume = entered, resume
		f.modelHold.Store(&hold)
		t.Cleanup(func() { f.modelHold.Store(nil) })
	}
	pid := make(chan int32, 1)
	production := f.s.Profiles.AI
	f.s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
		authorize := call.Authorize
		var attempt int
		call.Authorize = func(attemptCtx context.Context, tx pgx.Tx, send func(context.Context, pgx.Tx) error) error {
			attempt++
			if (!inFlight && attempt == 1) || (inFlight && attempt == 3) {
				if err := authHold(attemptCtx); err != nil {
					return err
				}
			}
			return authorize(attemptCtx, tx, func(sendCtx context.Context, tx pgx.Tx) error {
				if inFlight && attempt == 2 {
					var backend int32
					if err := tx.QueryRow(sendCtx, `select pg_backend_pid()`).Scan(&backend); err != nil {
						return err
					}
					pid <- backend
				}
				return send(sendCtx, tx)
			})
		}
		return production.Run(ctx, call)
	})
	done := f.startInference(f.router, account.AccessToken, path, input)
	if inFlight {
		awaitProfileStep(t, modelEntered)
		backend := awaitProfileStep(t, pid)
		controlDone := make(chan error, 1)
		go func() { controlDone <- change() }()
		requireProfileMutationBlocked(t, f, backend, waitingSQL)
		if m := f.metering(f.s, account.UserId, input.RequestId); m != (profileMetering{calls: 1}) {
			t.Fatalf("before releasing model adapter: %+v", m)
		}
		if got := f.calls.Load() - baseDispatches; got != 2 {
			t.Fatalf("in-flight provider requests = %d, want 2", got)
		}
		modelResume()
		awaitProfileStep(t, authEntered)
		f.must(awaitProfileStep(t, controlDone))
		t.Log("PostgreSQL reported the control request waiting on the model authorization transaction")
	} else {
		awaitProfileStep(t, authEntered)
		f.must(change())
	}
	authResume()
	f.check(awaitProfileStep(t, done), status, nil)
	f.s.Profiles.AI = production
	f.modelHold.Store(nil)

	want := profileMetering{}
	if inFlight {
		want = profileMetering{calls: 2, generated: 1, input: 12, output: 3, cost: 0.018}
	}
	checkMet := func() {
		t.Helper()
		if got := f.metering(f.s, account.UserId, input.RequestId); got != want || f.calls.Load()-baseDispatches != int32(want.calls) {
			t.Fatalf("target metering = %+v, want %+v; dispatches=%d", got, want, f.calls.Load()-baseDispatches)
		}
	}
	checkMet()
	var encryptedAfter []byte
	f.must(f.s.db.QueryRow(f.ctx, `select profile_enc from contacts where id=$1`, contactID).Scan(&encryptedAfter))
	if !bytes.Equal(encryptedBefore, encryptedAfter) {
		t.Fatal("fenced execution changed the contact profile")
	}
	switch state {
	case "chat-withdrawal":
		f.request(account.AccessToken, http.MethodPost, path, input, 403, nil)
		f.grant(account.AccessToken, "chat_import", true)
		f.request(account.AccessToken, http.MethodPost, path, input, 409, nil)
		if got := f.reservation(f.s, account.UserId, input.RequestId); got.state != "invalidated" || got.owner.Valid {
			t.Fatalf("withdrawal left a resumable reservation: %+v", got)
		}
	case "account-freeze":
		f.request(account.AccessToken, http.MethodPost, path, input, 401, nil)
		relogged := f.login(f.s, subject)
		f.request(relogged.AccessToken, http.MethodPost, path, input, 401, nil)
	case "contact-erasure-intent":
		var pending bool
		f.must(f.s.db.QueryRow(f.ctx, `select exists(select from pending_erasure where root_id=$1)`, contactID).Scan(&pending))
		if !pending {
			t.Fatal("public DELETE did not commit its erasure intent")
		}
		f.request(account.AccessToken, http.MethodPost, path, input, 503, nil)
	case "owner-replacement":
		got := f.reservation(f.s, account.UserId, input.RequestId)
		if got.state != "processing" || !got.live || !got.owner.Valid || got.owner.UUID != nextOwner {
			t.Fatalf("stale request changed replacement reservation: %+v", got)
		}
		f.pending(account.AccessToken, path, input)
	}
	f.request(other.AccessToken, http.MethodPost, otherPath, input, 200, nil)
	checkMet()
	if got := f.metering(f.s, other.UserId, input.RequestId); got != positive {
		t.Fatalf("same request id on other account: %+v", got)
	}
	if got := f.metering(f.s, account.UserId, sibling.RequestId); got != positive {
		t.Fatalf("different request id on same account: %+v", got)
	}
	t.Logf("HTTP %d; dispatches=%d; committed attempts=%d; cost=%.3f CNY; profile, retry fences and isolated ledgers verified", status, f.calls.Load()-baseDispatches, want.calls, want.cost)
}

func profileDispatchStatus(got, want int) error {
	if got != want {
		return fmt.Errorf("control HTTP status = %d, want %d", got, want)
	}
	return nil
}

func requireProfileMutationBlocked(t *testing.T, f *profilePersistenceFixture, blocker int32, queryPrefix string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(f.ctx, 5*time.Second)
	defer cancel()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		var waiting bool
		if err := f.s.db.QueryRow(ctx, `select exists(select from pg_stat_activity where datname=current_database()
			and wait_event_type='Lock' and $1=any(pg_blocking_pids(pid)) and query like $2 || '%')`, blocker, queryPrefix).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			return
		}
		select {
		case <-ctx.Done():
			t.Fatal("the expected PostgreSQL mutation was never blocked by the adapter authorization transaction")
		case <-ticker.C:
		}
	}
}

func TestProfileDispatchCancellation(t *testing.T) {
	f := newProfilePersistenceFixture(t)
	account := f.login(f.s, uuid.NewString())
	f.grant(account.AccessToken, "contacts", true)
	f.grant(account.AccessToken, "chat_import", true)
	path := f.contact(account.AccessToken) + "/infer"
	production := f.s.Profiles.AI

	t.Run("canceled-while-waiting-for-account-lock", func(t *testing.T) {
		input := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
		ctx, cancel := context.WithCancel(f.ctx)
		defer cancel()
		entered, resume, hold := holdProfileAttempt(t)
		f.s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			authorize := call.Authorize
			call.Authorize = func(attemptCtx context.Context, tx pgx.Tx, send func(context.Context, pgx.Tx) error) error {
				if err := hold(attemptCtx); err != nil {
					return err
				}
				return authorize(attemptCtx, tx, send)
			}
			return production.Run(ctx, call)
		})
		done := make(chan struct{})
		go func() {
			defer close(done)
			profilePersistenceRequest(ctx, f.router, account.AccessToken, http.MethodPost, path, input)
		}()
		awaitProfileStep(t, entered)
		tx, err := f.s.db.Begin(f.ctx)
		f.must(err)
		defer tx.Rollback(f.ctx)
		var blocker int32
		f.must(tx.QueryRow(f.ctx, `select pg_backend_pid() from users where id=$1 for update`, account.UserId).Scan(&blocker))
		resume()
		requireProfileMutationBlocked(t, f, blocker, "select id from users where id=")
		cancel()
		f.must(tx.Commit(f.ctx))
		awaitProfileStep(t, done)
		f.s.Profiles.AI = production
		if got := f.metering(f.s, account.UserId, input.RequestId); got != (profileMetering{}) || f.calls.Load() != 0 {
			t.Fatalf("canceled before adapter boundary: %+v; synthetic upstream calls=%d", got, f.calls.Load())
		}
	})

	t.Run("canceled-after-model-adapter-return", func(t *testing.T) {
		input := app.InferProfileInput{RequestId: uuid.New(), ChatText: profilePersistenceMaterial}
		ctx, cancel := context.WithCancel(f.ctx)
		defer cancel()
		prior := f.calls.Load()
		inside := make(chan int, 1)
		f.s.Profiles.AI = profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			authorize := call.Authorize
			var attempt int
			call.Authorize = func(attemptCtx context.Context, tx pgx.Tx, send func(context.Context, pgx.Tx) error) error {
				attempt++
				return authorize(attemptCtx, tx, func(sendCtx context.Context, tx pgx.Tx) error {
					if err := send(sendCtx, tx); err != nil || attempt != 2 {
						return err
					}
					cancel()
					var rows int
					err := tx.QueryRow(sendCtx, `select count(*) from ai_calls where user_id=$1 and operation_id=$2
						and prompt_version_id is not null and cost_cny=0.018`, account.UserId, input.RequestId).Scan(&rows)
					inside <- rows
					return err
				})
			}
			return production.Run(ctx, call)
		})
		profilePersistenceRequest(ctx, f.router, account.AccessToken, http.MethodPost, path, input)
		f.s.Profiles.AI = production
		if n := awaitProfileStep(t, inside); n != 1 {
			t.Fatalf("visible paid model rows before authorize returns = %d", n)
		}
		want := profileMetering{calls: 2, generated: 1, input: 12, output: 3, cost: 0.018}
		if got := f.metering(f.s, account.UserId, input.RequestId); got != want || f.calls.Load()-prior != 2 {
			t.Fatalf("after canceled authorization returns: %+v, want %+v; dispatches=%d", got, want, f.calls.Load()-prior)
		}
		if row := f.reservation(f.s, account.UserId, input.RequestId); row.state != "retryable" || row.owner.Valid {
			t.Fatalf("canceled result should leave a retryable binding: %+v", row)
		}
		t.Log("the paid model row was visible in the guarded transaction after cancellation and persisted once after commit")
	})
}
