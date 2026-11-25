//go:build integration

package service

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/gateway"
)

func TestAIExportGroupsAcrossBusinessRequests(t *testing.T) {
	ctx := t.Context()
	f := &reviewUpstream{entered: make(chan struct{}), resume: make(chan struct{})}
	close(f.resume)
	reviewVendor := f.handler(t)
	const replyText = "T35-SYNTHETIC-REPLY-CHAT"
	const profileText = "T35-SYNTHETIC-PROFILE-CHAT"
	const replacementText = "T35-SYNTHETIC-PROFILE-REPLACEMENT"
	var replyAttempts atomic.Int32
	var profileRequests atomic.Int32
	var failProfileModeration atomic.Bool
	vendor := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		var in struct {
			Stream   bool
			Messages []gateway.Message
		}
		if err != nil || json.Unmarshal(body, &in) != nil || len(in.Messages) != 2 {
			t.Error("invalid synthetic vendor request")
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		var response string
		switch user := in.Messages[1].Content; {
		case !in.Stream && (strings.Contains(user, profileText) || strings.Contains(user, replacementText)):
			profileRequests.Add(1)
			if failProfileModeration.Load() {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			reviewVendor.ServeHTTP(w, r)
			return
		case in.Stream && strings.Contains(user, replyText):
			if replyAttempts.Add(1) == 1 {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			response = `{"possible_feeling":"也许在担心进度","possible_need":"想知道时间","suggestions":[{"style":"直接","text":"我周三发计划。","reason":"明确时间。"},{"style":"确认","text":"你希望先看计划吗？","reason":"给出选择。"}]}`
		case in.Stream && (user == profileText || user == replacementText):
			profileRequests.Add(1)
			response = `{"choices":[1,1,2,1,0,0,0]}`
		default:
			r.Body = io.NopCloser(bytes.NewReader(body))
			reviewVendor.ServeHTTP(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":%q},\"finish_reason\":\"stop\"}]}\n\n", response)
		fmt.Fprint(w, "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3}}\n\ndata: [DONE]\n\n")
	})
	s := reviewRuntimeWithVendor(t, vendor, map[admin.Task]uuid.UUID{
		admin.TaskReplySuggestion:  uuid.MustParse("ffa572d2-bc80-441d-a6ac-6c9e17b33e21"),
		admin.TaskProfileInference: uuid.MustParse("b935fb60-5a85-4c12-82c0-401afd649325"),
	})
	router := s.Router()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	_, err := s.db.Exec(ctx, `update model_configs set input_cny_per_million=1000,output_cny_per_million=2000
where id in (select primary_model from model_routes where task='reply_suggestion'
             union select fallback_model from model_routes where task='reply_suggestion')`)
	must(err)
	request := func(token, method, path string, in any, status int, out any) {
		t.Helper()
		body, err := json.Marshal(in)
		must(err)
		r := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(body))
		r.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		router.ServeHTTP(w, r)
		if w.Code != status {
			t.Fatalf("%s %s: got %d, want %d: %s", method, path, w.Code, status, w.Body)
		}
		if out != nil {
			t35Decode(t, w.Body.Bytes(), out)
		}
	}
	count := func(query string, args ...any) int {
		t.Helper()
		var n int
		must(s.db.QueryRow(ctx, query, args...).Scan(&n))
		return n
	}
	used := func(user uuid.UUID, feature string) int {
		t.Helper()
		return count(`select coalesce(sum(used),0) from daily_quota_usage where user_id=$1 and feature=$2`, user, feature)
	}
	login := func(subject string) app.Tokens {
		t.Helper()
		ticket := uuid.NewString()
		must(s.cache.Set(ctx, "dev:ticket:apple:"+ticket, subject, time.Minute).Err())
		var tokens app.Tokens
		request("", "POST", "auth/login", map[string]any{
			"credential":    map[string]string{"provider": "apple", "proof": ticket},
			"age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11",
		}, 200, &tokens)
		return tokens
	}

	shared, separate := uuid.New(), uuid.New()
	type accountOperations struct {
		app.Tokens
		reply, contact, review, score uuid.UUID
		retried                       bool
	}
	run := func(retry bool) accountOperations {
		t.Helper()
		subject := uuid.NewString()
		a := accountOperations{retried: retry, Tokens: login(subject)}
		for _, purpose := range []string{"contacts", "chat_import", "review"} {
			request(a.AccessToken, "PUT", "me/consents/"+purpose, map[string]any{"version": "2026-11", "granted": true}, 200, nil)
		}
		request(a.AccessToken, "PUT", "me/consents/"+accounts.ReplyChatImportPurpose, map[string]any{
			"version": accounts.ReplyChatImportVersion, "granted": true,
		}, 200, nil)
		var contact app.Contact
		request(a.AccessToken, "POST", "contacts", map[string]string{"nickname": "合成对象", "scene": "partner"}, 200, &contact)
		a.contact = contact.Id
		path := "contacts/" + a.contact.String() + "/infer"
		profile := app.InferProfileInput{RequestId: shared, ChatText: profileText}
		if retry {
			failProfileModeration.Store(true)
			request(a.AccessToken, "POST", path, profile, 503, nil)
			failProfileModeration.Store(false)
			attempts := count(`select count(*) from ai_calls where user_id=$1 and task='profile_inference'
				and operation_id=$2 and outcome='moderation_unavailable'`, a.UserId, shared)
			if attempts != 1 {
				t.Fatalf("expected one failed moderation attempt, got %d", attempts)
			}

			relogged := login(subject)
			if relogged.UserId != a.UserId || relogged.AccessToken == a.AccessToken {
				t.Fatal("expected a new login session for the same account")
			}
			a.Tokens = relogged
			beforeRequests := profileRequests.Load()
			beforeCalls := count(`select count(*) from ai_calls where user_id=$1`, a.UserId)
			beforeUsage := count(`select coalesce(sum(used),0) from daily_quota_usage where user_id=$1`, a.UserId)
			replacement := app.InferProfileInput{RequestId: shared, ChatText: replacementText}
			request(a.AccessToken, "POST", path, replacement, 409, nil)
			if profileRequests.Load() != beforeRequests ||
				count(`select count(*) from ai_calls where user_id=$1`, a.UserId) != beforeCalls ||
				count(`select coalesce(sum(used),0) from daily_quota_usage where user_id=$1`, a.UserId) != beforeUsage {
				t.Fatal("rejected material made a provider request, recorded a call, or changed quota")
			}
		}
		request(a.AccessToken, "POST", path, profile, 200, nil)
		if retry {
			request(a.AccessToken, "POST", path, app.InferProfileInput{RequestId: separate, ChatText: profileText}, 200, nil)
		}
		var reply app.Reply
		replyInput := app.CreateReplyInput{RequestId: shared, ChatText: replyText,
			ReplyConsentId: replyFixtureDecision(t, s, a.Tokens, accounts.ReplyChatImportPurpose, accounts.ReplyChatImportVersion)}
		request(a.AccessToken, "POST", "replies", replyInput, 200, &reply)
		a.reply = reply.Id
		var review app.Review
		scene := app.ReviewInputSceneWork
		reviewInput := app.ReviewInput{RequestId: shared, Scene: &scene, Happened: "合成会议", MyFeeling: "着急", TheirPossibleFeeling: "也许没说完", MyAction: "我先说完", NextAction: "等对方说完"}
		if retry {
			f.mode.Store(2)
			request(a.AccessToken, "POST", "reviews", reviewInput, 503, nil)
			f.mode.Store(0)
			if n := used(a.UserId, "review"); n != 0 {
				t.Fatalf("failed review charged %d", n)
			}
		}
		request(a.AccessToken, "POST", "reviews", reviewInput, 200, &review)
		a.review, a.score = review.Id, review.Score.ScoreId
		attempts := count(`select count(*) from ai_calls where user_id=$1`, a.UserId)
		request(a.AccessToken, "POST", "replies", replyInput, 200, nil)
		request(a.AccessToken, "POST", path, profile, 200, nil)
		request(a.AccessToken, "POST", "reviews", reviewInput, 200, nil)
		if count(`select count(*) from ai_calls where user_id=$1`, a.UserId) != attempts ||
			used(a.UserId, "reply") != 1 || used(a.UserId, "review") != 1 {
			t.Fatal("replay recorded new attempts or changed quota")
		}
		return a
	}
	owner, foreign := run(true), run(false)

	type exportedCall struct {
		ID       uuid.UUID  `json:"id"`
		Group    uuid.UUID  `json:"operation_id"`
		Activity *uuid.UUID `json:"activity_id"`
		Contact  *uuid.UUID `json:"contact_id"`
		Score    *uuid.UUID `json:"score_id"`
		Model    uuid.UUID  `json:"model_id"`
		Prompt   *uuid.UUID `json:"prompt_version_id"`
		Task     string     `json:"task"`
		Outcome  string     `json:"outcome"`
		Input    *int       `json:"input_tokens"`
		Output   *int       `json:"output_tokens"`
		Cost     *float64   `json:"cost_cny"`
	}
	groups := func(a accountOperations) map[string]uuid.UUID {
		t.Helper()
		archive := t35Download(t, router, a.AccessToken)
		for _, entry := range archive.File {
			r, err := entry.Open()
			must(err)
			body, err := io.ReadAll(r)
			must(r.Close())
			must(err)
			for _, data := range [][]byte{[]byte(entry.Name), body} {
				t35Exclude(t, data, shared.String(), separate.String(), profileText, replacementText, `"input_digest":`)
			}
		}
		var calls []exportedCall
		t35Decode(t, t35Part(t, archive, "ai_calls"), &calls)
		byID := make(map[uuid.UUID]exportedCall)
		for _, call := range calls {
			if _, exists := byID[call.ID]; exists {
				t.Fatalf("duplicate exported attempt %s", call.ID)
			}
			byID[call.ID] = call
		}
		rows, err := s.db.Query(ctx, `select id,operation_id,activity_id,contact_id,score_id,model_id,
prompt_version_id,task,outcome,input_tokens,output_tokens,cost_cny::float8 from ai_calls where user_id=$1`, a.UserId)
		must(err)
		defer rows.Close()
		ids := make(map[string]uuid.UUID)
		labels := make(map[uuid.UUID]string)
		replyModels := make(map[uuid.UUID]bool)
		metered := make(map[string]int)
		var profileRetry, reviewAnalysis, reviewRetry, linkedScore bool
		for rows.Next() {
			var internal uuid.UUID
			var stored exportedCall
			must(rows.Scan(&stored.ID, &internal, &stored.Activity, &stored.Contact, &stored.Score, &stored.Model,
				&stored.Prompt, &stored.Task, &stored.Outcome, &stored.Input, &stored.Output, &stored.Cost))
			call := byID[stored.ID]
			stored.Group = call.Group
			if stored.Group.Version() != 8 || !reflect.DeepEqual(call, stored) || stored.Model == uuid.Nil ||
				(stored.Prompt != nil && *stored.Prompt == uuid.Nil) {
				t.Fatalf("export does not match persisted attempt %s", stored.ID)
			}
			delete(byID, stored.ID)
			label := stored.Task
			switch stored.Task {
			case "reply_suggestion":
				if stored.Activity == nil || *stored.Activity != a.reply || internal != shared {
					t.Fatal("reply attempt lost its public activity or original key in storage")
				}
				if stored.Prompt != nil {
					replyModels[stored.Model] = true
				}
			case "profile_inference":
				if stored.Activity != nil || stored.Contact == nil || *stored.Contact != a.contact ||
					(internal != shared && (!a.retried || internal != separate)) {
					t.Fatal("profile attempt lost its contact or original key in storage")
				}
				if internal == separate {
					label += "/separate"
				} else if stored.Outcome == "moderation_unavailable" {
					profileRetry = true
				}
			case "review_analysis", "scoring":
				if stored.Activity == nil || *stored.Activity != a.review || internal != shared {
					t.Fatal("review attempt lost its public activity or original key in storage")
				}
				if stored.Score != nil {
					if stored.Task != "scoring" || stored.Prompt == nil || *stored.Score != a.score || stored.Outcome != "ok" {
						t.Fatalf("unrelated attempt linked to score %s", a.score)
					}
					linkedScore = true
				}
				reviewAnalysis = reviewAnalysis || stored.Task == "review_analysis"
				reviewRetry = reviewRetry || stored.Task == "scoring" && stored.Outcome == "moderation_unavailable"
				label = "review"
			default:
				t.Fatalf("unexpected exported task %q", stored.Task)
			}
			if stored.Prompt != nil && stored.Outcome == "ok" &&
				(stored.Task == "reply_suggestion" || stored.Task == "profile_inference") {
				if stored.Input == nil || *stored.Input != 12 || stored.Output == nil || *stored.Output != 3 ||
					stored.Cost == nil || *stored.Cost != 0.018 {
					t.Fatalf("wrong exported metering for %s", stored.Task)
				}
				metered[label]++
			}
			if prior, ok := ids[label]; ok && prior != call.Group {
				t.Fatalf("attempts for %q were split", label)
			}
			if prior, ok := labels[call.Group]; ok && prior != label {
				t.Fatalf("independent operations %q and %q share a group", prior, label)
			}
			ids[label], labels[call.Group] = call.Group, label
		}
		must(rows.Err())
		if len(byID) != 0 || !linkedScore || !reviewAnalysis ||
			metered["profile_inference"] != 1 || metered["reply_suggestion"] != 1 {
			t.Fatal("missing owned operation or unrelated attempt present in export")
		}
		if a.retried && (!profileRetry || !reviewRetry || len(replyModels) != 2 || metered["profile_inference/separate"] != 1) {
			t.Fatal("missing actual retry, fallback, or second profile operation")
		}
		return ids
	}
	first, repeated, other := groups(owner), groups(owner), groups(foreign)
	if !reflect.DeepEqual(first, repeated) {
		t.Fatal("groups changed across repeated downloads")
	}
	for name, group := range other {
		if first[name] == group {
			t.Fatalf("accounts share an exported group for %q", name)
		}
	}

	// Simulate history whose attempts outlived their request binding.
	_, err = s.db.Exec(ctx, `delete from profile_inference_requests where user_id=$1 and request_id=$2`, owner.UserId, separate)
	must(err)
	beforeRequests := profileRequests.Load()
	legacy := app.InferProfileInput{RequestId: separate, ChatText: replacementText}
	request(owner.AccessToken, "POST", "contacts/"+owner.contact.String()+"/infer", legacy, 409, nil)
	if profileRequests.Load() != beforeRequests || !reflect.DeepEqual(groups(owner), first) {
		t.Fatal("reusing an unbound historical key changed its export or reached the provider")
	}
}
