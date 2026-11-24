//go:build integration

package service

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/replies"
)

func TestReplyRoutedDispatchOperationCancellationKeepsAttempt(t *testing.T) {
	entered, resume, hold := holdProfileAttempt(t)
	var dispatches atomic.Int32
	s := reviewRuntimeWithVendor(t, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Stream bool }
		if err := json.NewDecoder(r.Body).Decode(&in); err != nil {
			t.Error("invalid synthetic reply call")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		dispatches.Add(1)
		if !in.Stream {
			fmt.Fprint(w, `{"choices":[{"message":{"content":"{\"verdict\":\"allow\"}"},"finish_reason":"stop"}]}`)
			return
		}
		_ = hold(r.Context())
	}), map[admin.Task]uuid.UUID{admin.TaskReplySuggestion: uuid.MustParse("ffa572d2-bc80-441d-a6ac-6c9e17b33e21")})
	defer resume()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	// A reply survives HTTP disconnect. Cancel the execution context used by
	// the real router, while leaving the reply's production Authorize intact.
	cancelExecution := make(chan context.CancelFunc, 1)
	s.Replies = replies.New(s.Accounts, s.Membership, s.Data, s.Fields, s.db, s.Bus, cfg.authMaster, func(stop gateway.Stop) (replies.Runner, error) {
		routed, err := s.catalog.NewRouter(s.Data, stop)
		if err != nil {
			return nil, err
		}
		return profileRunner(func(ctx context.Context, call gateway.Call) (gateway.Reply, error) {
			run, cancel := context.WithCancel(ctx)
			defer cancel()
			cancelExecution <- cancel
			return routed.Run(run, call)
		}), nil
	})
	f := &profilePersistenceFixture{t: t, ctx: t.Context(), s: s, router: s.Router()}
	a := f.login(s, uuid.NewString())
	f.grant(a.AccessToken, "chat_import", true)
	requestID := uuid.New()
	done := make(chan struct{})
	go func() {
		defer close(done)
		profilePersistenceRequest(t.Context(), f.router, a.AccessToken, http.MethodPost, "replies", app.CreateReplyInput{
			RequestId: requestID,
			ChatText:  "T35-SYNTHETIC-REPLY-CANCEL",
		})
	}()
	cancel := awaitProfileStep(t, cancelExecution)
	defer cancel()
	awaitProfileStep(t, entered)
	cancel()
	awaitProfileStep(t, done)
	var total, model int
	f.must(s.db.QueryRow(t.Context(), `select count(*),count(*) filter(where prompt_version_id is not null and outcome='failed')
		from ai_calls where user_id=$1 and operation_id=$2 and task='reply_suggestion'`, a.UserId, requestID).Scan(&total, &model))
	if got := dispatches.Load(); got != 2 || total != 2 || model != 1 {
		t.Fatalf("synthetic provider dispatches=%d, durable attempts=%d, canceled model attempts=%d; want 2/2/1", got, total, model)
	}
	t.Log("input review and canceled model dispatch each left one durable attempt")
}
