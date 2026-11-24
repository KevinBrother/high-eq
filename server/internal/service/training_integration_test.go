//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/admin"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/training"
)

func (h *practiceWire) ledger(u app.Tokens, path, state string, n int) {
	h.t.Helper()
	v := h.history(u, path)
	if v.Status != state || v.Settlement.Net != n {
		h.t.Fatalf("state/charge = %s/%d want %s/%d", v.Status, v.Settlement.Net, state, n)
	}
	if got := h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is null`, v.ID); got != n {
		h.t.Fatal("ledger mismatch", got, n)
	}
	if state != "complete" && h.number(`select count(*) from scores where activity_id=$1`, v.ID) != 0 {
		h.t.Fatal("unexpected score")
	}
}
func TestPracticeWire(t *testing.T) {
	h := newPracticeWire(t)
	var full, skill atomic.Int32
	var deny atomic.Bool
	h.s.Bus.ScoreCompleted.Subscribe(func(_ context.Context, _ pgx.Tx, e events.Score) error {
		if deny.Load() {
			return errors.New("injected subscriber outage")
		}
		if e.Kind != "practice" || (e.NVC.Total != 100 && e.NVC.Total != 60) || e.SourceID == uuid.Nil {
			t.Error("wrong score projection")
		}
		full.Add(1)
		return nil
	})
	h.s.Bus.DrillProgressed.Subscribe(func(_ context.Context, _ pgx.Tx, d events.Drill) error {
		if (d.Score != 15 && d.Score != 25) || d.TargetItem != "observation" {
			t.Error("wrong drill projection")
		}
		skill.Add(1)
		return nil
	})
	t.Run("catalog_access_and_history", func(t *testing.T) {
		u, b := h.user(), h.user()
		var page app.ListLevelsResult
		h.json(u.AccessToken, "GET", "levels?scene=work&difficulty=1&limit=1", nil, 200, &page)
		if len(page.Items) != 1 || page.Items[0].Mode != "single_skill" {
			t.Fatal("filter")
		}
		path := h.create(u, 0)
		id := strings.TrimPrefix(path, "sessions/")
		h.json(u.AccessToken, "POST", "sessions", map[string]string{"request_id": id, "scene": "family", "scenario": "不同输入"}, 409, nil)
		h.json(b.AccessToken, "GET", path, nil, 404, nil)
		h.json(b.AccessToken, "POST", path+"/finish", nil, 404, nil)
		h.json(u.AccessToken, "PUT", "me/consents/contacts", map[string]any{"version": "v1", "granted": true}, 200, nil)
		c1, c2 := uuid.New(), uuid.New()
		h.exec(`insert into contacts(id,user_id,profile_enc,last_used_at) values($1,$3,'x',now()),($2,$3,'y',null)`, c1, c2, u.UserId)
		h.json(u.AccessToken, "POST", "sessions", map[string]any{"request_id": uuid.New(), "level_id": page.Items[0].Id, "contact_id": c2}, 403, nil)
		h.json(u.AccessToken, "POST", "sessions", map[string]any{"request_id": uuid.New(), "level_id": page.Items[0].Id, "contact_id": c1}, 200, nil)
		var history training.Page
		h.json(u.AccessToken, "GET", "sessions?limit=1", nil, 200, &history)
		if history.Next == nil || len(history.Items) != 1 || history.Items[0].Level == nil {
			t.Fatal("order")
		}
		h.json(u.AccessToken, "GET", "sessions?limit=1&cursor="+*history.Next, nil, 200, &history)
		if history.Next != nil || len(history.Items) != 1 || history.Items[0].ID.String() != id {
			t.Fatal("cursor")
		}
		h.json(u.AccessToken, "PUT", "me/consents/practice", map[string]any{"version": "v1", "granted": false}, 200, nil)
		h.json(u.AccessToken, "POST", path+"/messages", body(uuid.NewString()), 403, nil)
	})
	t.Run("completion_time_keeps_creation_history_order", func(t *testing.T) {
		u := h.user()
		createdFirst := h.create(u, 1)
		createdSecond := h.create(u, 5)
		firstID := uuid.MustParse(strings.TrimPrefix(createdFirst, "sessions/"))
		secondID := uuid.MustParse(strings.TrimPrefix(createdSecond, "sessions/"))

		// Finish in the reverse of creation order. The lobby's cursor remains on
		// created_at, while growth history needs the actual completion time.
		h.send(u, createdSecond)
		var secondResult training.Result
		h.json(u.AccessToken, "POST", createdSecond+"/finish", nil, 200, &secondResult)
		time.Sleep(5 * time.Millisecond)
		h.send(u, createdFirst)
		var firstResult training.Result
		h.json(u.AccessToken, "POST", createdFirst+"/finish", nil, 200, &firstResult)
		if secondResult.Score == nil || secondResult.Progress != nil || firstResult.Progress == nil || firstResult.Score != nil {
			t.Fatal("single and full-session results were mixed")
		}

		var firstPage, secondPage training.Page
		h.json(u.AccessToken, "GET", "sessions?limit=1", nil, 200, &firstPage)
		if firstPage.Next == nil || len(firstPage.Items) != 1 || firstPage.Items[0].ID != secondID {
			t.Fatal("lobby creation order or cursor changed")
		}
		h.json(u.AccessToken, "GET", "sessions?limit=1&cursor="+*firstPage.Next, nil, 200, &secondPage)
		if secondPage.Next != nil || len(secondPage.Items) != 1 || secondPage.Items[0].ID != firstID {
			t.Fatal("second lobby page does not preserve creation order")
		}
		createdSecondItem, createdFirstItem := firstPage.Items[0], secondPage.Items[0]
		if createdSecondItem.CompletedAt == nil || createdFirstItem.CompletedAt == nil {
			t.Fatal("completed history did not expose its completion time")
		}
		if !createdFirstItem.CompletedAt.After(*createdSecondItem.CompletedAt) {
			t.Fatalf("completion order=%s/%s want first-created to finish later", createdFirstItem.CompletedAt, createdSecondItem.CompletedAt)
		}
		if createdSecondItem.Result == nil || createdSecondItem.Result.Progress != nil || createdSecondItem.Result.Score == nil ||
			createdFirstItem.Result == nil || createdFirstItem.Result.Score != nil || createdFirstItem.Result.Progress == nil {
			t.Fatal("history results mixed single and full-session scores")
		}

		original := *createdFirstItem.CompletedAt
		h.json(u.AccessToken, "POST", createdFirst+"/finish", nil, 200, &firstResult)
		replayed := h.history(u, createdFirst)
		if replayed.CompletedAt == nil || !replayed.CompletedAt.Equal(original) {
			t.Fatalf("finish retry changed completion time: %v -> %v", original, replayed.CompletedAt)
		}
	})
	t.Run("authorization_is_rechecked_during_a_turn", func(t *testing.T) {
		t.Run("revocation during input review", func(t *testing.T) {
			u, p := h.user(), ""
			p = h.create(u, 0)
			started, release := h.holdReview()
			released := false
			defer func() {
				if !released {
					release()
				}
			}()
			before := h.generations.Load()
			type result struct {
				resp *http.Response
				err  error
			}
			done := make(chan result, 1)
			go func() {
				resp, err := h.request(u.AccessToken, "POST", p+"/messages", body(uuid.NewString()))
				done <- result{resp, err}
			}()
			select {
			case <-started:
			case <-time.After(5 * time.Second):
				t.Fatal("input review did not start")
			}
			h.json(u.AccessToken, "PUT", "me/consents/practice", map[string]any{"version": "v1", "granted": false}, 200, nil)
			release()
			released = true
			got := <-done
			h.must(got.err)
			defer got.resp.Body.Close()
			if got.resp.StatusCode != 403 {
				t.Fatalf("revoked turn status=%d want 403", got.resp.StatusCode)
			}
			if h.generations.Load() != before {
				t.Fatal("model received history after practice consent was withdrawn")
			}
			h.set("")
		})

		t.Run("logout fences an old stream", func(t *testing.T) {
			u := h.user()
			p := h.create(u, 0)
			release := h.hold()
			released := false
			defer func() {
				if !released {
					release()
				}
			}()
			before := h.generations.Load()
			r := h.stream(u, p, uuid.NewString())
			first(h, r)
			h.logout(u)
			release()
			released = true
			rest, err := io.ReadAll(r.Body)
			r.Body.Close()
			h.must(err)
			if strings.Contains(string(rest), "event: fragment") {
				t.Fatal("logged-out stream received another fragment")
			}
			if h.generations.Load() != before+1 {
				t.Fatal("unexpected regeneration")
			}
			id := uuid.MustParse(strings.TrimPrefix(p, "sessions/"))
			if h.number(`select count(*) from practice_messages where activity_id=$1 and role='assistant'`, id) != 0 || h.number(`select count(*) from practice_messages where activity_id=$1 and role='user'`, id) != 1 {
				t.Fatal("logged-out reply was persisted")
			}
			if h.number(`select count(*) from activities where id=$1 and state='failed'`, id) != 1 {
				t.Fatal("logged-out turn was not closed")
			}
			h.set("")
		})
	})
	t.Run("disconnect_and_exit", func(t *testing.T) {
		for _, mode := range []string{"lost_receipt", "disconnect", "explicit_exit"} {
			u := h.user()
			path := h.create(u, 0)
			release := h.hold()
			key := uuid.NewString()
			n := h.generations.Load()
			r := h.stream(u, path, key)
			first(h, r)
			h.frames(u, path, key, "in_progress")
			h.json(u.AccessToken, "POST", path+"/messages", body(uuid.NewString()), 409, nil)
			if mode == "explicit_exit" {
				h.json(u.AccessToken, "POST", path+"/exit", nil, 200, nil)
			}
			if mode == "disconnect" {
				r.Body.Close()
			}
			release()
			if mode == "explicit_exit" {
				io.Copy(io.Discard, r.Body)
				r.Body.Close()
				h.ledger(u, path, "exited", 0)
				if len(h.history(u, path).Messages) != 1 {
					t.Fatal("late reply")
				}
			} else {
				deadline := time.Now().Add(5 * time.Second)
				for len(h.history(u, path).Messages) != 2 && time.Now().Before(deadline) {
					time.Sleep(10 * time.Millisecond)
				}
				r.Body.Close()
				h.ledger(u, path, "active", 1)
				h.frames(u, path, key, "reply_saved")
				v := h.history(u, path)
				if len(v.Messages) != 2 || v.Messages[1].ClientMessageId.String() != key {
					t.Fatal("duplicate")
				}
				h.json(u.AccessToken, "POST", path+"/exit", nil, 200, nil)
				h.ledger(u, path, "exited", 1)
			}
			if h.generations.Load() != n+1 {
				t.Fatal("regenerated")
			}
			h.set("")
		}
	})
	t.Run("pre_fragment_outage_and_shared_quota", func(t *testing.T) {
		u := h.user()
		p := h.create(u, 1)
		h.set("preoutage")
		k := uuid.NewString()
		h.frames(u, p, k, "moderation_unavailable")
		h.ledger(u, p, "moderation_unavailable", 0)
		h.set("")
		h.frames(u, p, k, "fragment", "fragment", "reply_saved")
		for i := 0; i < 2; i++ {
			h.send(u, h.create(u, 5))
		}
		p = h.create(u, 5)
		h.json(u.AccessToken, "POST", p+"/messages", body(uuid.NewString()), 429, nil)
		h.ledger(u, p, "pending", 0)
	})
	t.Run("per_stage_settlement", func(t *testing.T) {
		for _, stage := range []string{"first", "later", "finish"} {
			for _, fault := range []string{"safety", "outage"} {
				u := h.user()
				path := h.create(u, 0)
				if stage != "first" {
					h.send(u, path)
				}
				h.set(fault)
				state := "safety"
				if fault == "outage" {
					state = "moderation_unavailable"
				}
				k := uuid.NewString()
				if stage == "finish" {
					var v gateway.Terminal
					code := 200
					if fault == "outage" {
						code = 503
					}
					h.json(u.AccessToken, "POST", path+"/finish", nil, code, &v)
					if v.Name() != state {
						t.Fatal("wrong terminal")
					}
				} else {
					h.frames(u, path, k, "fragment", "fragment", state)
				}
				h.ledger(u, path, state, 0)
				hist := h.history(u, path)
				if stage == "first" && hist.Settlement.Status != "uncharged" || stage != "first" && hist.Settlement.Status != "refunded" {
					t.Fatal("wrong settlement")
				}
				h.set("")
				if fault == "safety" {
					var stop gateway.Terminal
					h.json(u.AccessToken, "POST", path+"/finish", nil, 200, &stop)
					if !stop.Safety {
						t.Fatal("crisis reopened")
					}
				} else if stage != "finish" {
					h.json(u.AccessToken, "POST", path+"/messages", body(uuid.NewString()), 409, nil)
					h.frames(u, path, k, "fragment", "fragment", "reply_saved")
					h.ledger(u, path, "active", 1)
				} else {
					h.json(u.AccessToken, "POST", path+"/finish", nil, 200, nil)
					h.ledger(u, path, "complete", 1)
				}
			}
		}
	})
	t.Run("partial_and_final_schema_failure_original_day", func(t *testing.T) {
		u := h.user()
		p := h.create(u, 0)
		h.set("partial")
		h.frames(u, p, uuid.NewString(), "fragment")
		h.ledger(u, p, "failed", 0)
		h.set("")
		h.json(u.AccessToken, "PATCH", "me", map[string]string{"timezone": "Etc/GMT+12"}, 200, nil)
		p = h.create(u, 0)
		h.send(u, p)
		v := h.history(u, p)
		day := *v.Settlement.Day
		// Advance the account's actual quota date exactly one day through the API;
		// leave both SQL ledger rows untouched. An independent next-day charge must survive.
		h.json(u.AccessToken, "PATCH", "me", map[string]string{"timezone": "Etc/GMT-12"}, 200, nil)
		other := h.create(u, 0)
		h.send(u, other)
		if *h.history(u, other).Settlement.Day == day {
			t.Fatal("day boundary not crossed")
		}
		n := h.grades.Load()
		h.set("schema")
		h.json(u.AccessToken, "POST", p+"/finish", nil, 500, nil)
		h.ledger(u, p, "failed", 0)
		h.json(u.AccessToken, "POST", p+"/finish", nil, 409, nil)
		v = h.history(u, p)
		if h.grades.Load() != n+2 || v.Settlement.Day == nil || *v.Settlement.Day != day || h.number(`select used from daily_quota_usage where user_id=$1 and feature='practice' and charged_day=$2::date`, u.UserId, day) != 0 {
			t.Fatal("schema retry or original day refund")
		}
		var rights app.Entitlements
		h.json(u.AccessToken, "GET", "entitlements", nil, 200, &rights)
		for _, a := range rights.Allowances {
			if a.Feature == "practice" && (a.Remaining == nil || *a.Remaining != 2) {
				t.Fatal("next day quota")
			}
		}
		h.set("")
	})
	t.Run("terminal_settlement_has_durable_compensation", func(t *testing.T) {
		u := h.user()
		p := h.create(u, 0)
		h.send(u, p)
		id := uuid.MustParse(strings.TrimPrefix(p, "sessions/"))
		finishUser := h.user()
		finishPath := h.create(finishUser, 0)
		h.send(finishUser, finishPath)
		finishID := uuid.MustParse(strings.TrimPrefix(finishPath, "sessions/"))
		h.exec(`create or replace function t19_fail_activity_state() returns trigger language plpgsql as $fn$ begin raise exception 'injected activity state failure'; end $fn$`)
		h.exec(`drop trigger if exists t19_fail_activity_state on activities`)
		h.exec(`create trigger t19_fail_activity_state before update of state on activities for each row execute function t19_fail_activity_state()`)
		t.Cleanup(func() {
			_, _ = h.s.db.Exec(context.Background(), `drop trigger if exists t19_fail_activity_state on activities`)
			_, _ = h.s.db.Exec(context.Background(), `drop function if exists t19_fail_activity_state()`)
		})

		h.set("safety")
		key := uuid.NewString()
		h.frames(u, p, key, "fragment", "fragment", "safety")
		var pending bool
		var outcome string
		h.must(h.s.db.QueryRow(h.ctx, `select settlement_pending,settlement_outcome from practice_work where activity_id=$1`, id).Scan(&pending, &outcome))
		if !pending || outcome != "safety" {
			t.Fatalf("settlement intent=%t/%q", pending, outcome)
		}

		h.set("safety")
		var finishTerminal gateway.Terminal
		h.json(finishUser.AccessToken, "POST", finishPath+"/finish", nil, 200, &finishTerminal)
		if !finishTerminal.Safety {
			t.Fatal("finish settlement failure hid safety terminal")
		}
		h.must(h.s.db.QueryRow(h.ctx, `select settlement_pending,settlement_outcome from practice_work where activity_id=$1`, finishID).Scan(&pending, &outcome))
		if !pending || outcome != "safety" {
			t.Fatalf("finish settlement intent=%t/%q", pending, outcome)
		}
		if v := h.history(finishUser, finishPath); v.Status != "safety" {
			t.Fatalf("pending finish status=%s want safety", v.Status)
		}
		grades := h.grades.Load()

		bus := h.s.Practice.Bus
		h.s.Practice.Bus = events.New(h.s.Data, nil)
		defer func() { h.s.Practice.Bus = bus }()
		if err := h.s.Practice.ReplayPending(h.ctx); err == nil {
			t.Fatal("failed settlement was reported as compensated")
		}
		h.exec(`drop trigger t19_fail_activity_state on activities`)
		h.must(h.s.Practice.ReplayPending(h.ctx))
		h.ledger(u, p, "safety", 0)
		h.ledger(finishUser, finishPath, "safety", 0)
		h.must(h.s.db.QueryRow(h.ctx, `select settlement_pending from practice_work where activity_id=$1`, id).Scan(&pending))
		if pending || h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is not null`, id) != 1 {
			t.Fatal("durable terminal compensation did not settle once")
		}
		h.must(h.s.db.QueryRow(h.ctx, `select settlement_pending from practice_work where activity_id=$1`, finishID).Scan(&pending))
		if pending || h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is not null`, finishID) != 1 {
			t.Fatal("durable finish compensation did not settle once")
		}
		n := h.generations.Load()
		h.frames(u, p, key, "safety")
		if h.generations.Load() != n {
			t.Fatal("terminal message was regenerated")
		}
		h.json(finishUser.AccessToken, "POST", finishPath+"/finish", nil, 200, &finishTerminal)
		if !finishTerminal.Safety || h.grades.Load() != grades {
			t.Fatal("terminal finish was regenerated")
		}
		h.set("")
	})
	t.Run("terminal_settlement_survives_intent_write_failure", func(t *testing.T) {
		u := h.user()
		p := h.create(u, 0)
		h.send(u, p)
		id := uuid.MustParse(strings.TrimPrefix(p, "sessions/"))
		finishUser := h.user()
		finishPath := h.create(finishUser, 0)
		h.send(finishUser, finishPath)
		finishID := uuid.MustParse(strings.TrimPrefix(finishPath, "sessions/"))
		h.exec(`create or replace function t19_fail_settlement_intent() returns trigger language plpgsql as $fn$ begin raise exception 'injected settlement intent failure'; end $fn$`)
		h.exec(`drop trigger if exists t19_fail_settlement_intent on practice_work`)
		h.exec(`create trigger t19_fail_settlement_intent before update of settlement_pending on practice_work for each row when (new.settlement_pending) execute function t19_fail_settlement_intent()`)
		h.exec(`create or replace function t19_fail_terminal_refund() returns trigger language plpgsql as $fn$ begin raise exception 'injected terminal refund failure'; end $fn$`)
		h.exec(`drop trigger if exists t19_fail_terminal_refund on quota_ledger`)
		h.exec(`create trigger t19_fail_terminal_refund before update of refunded_at on quota_ledger for each row when (old.refunded_at is null and new.refunded_at is not null) execute function t19_fail_terminal_refund()`)
		t.Cleanup(func() {
			_, _ = h.s.db.Exec(context.Background(), `drop trigger if exists t19_fail_settlement_intent on practice_work`)
			_, _ = h.s.db.Exec(context.Background(), `drop trigger if exists t19_fail_terminal_refund on quota_ledger`)
			_, _ = h.s.db.Exec(context.Background(), `drop function if exists t19_fail_settlement_intent()`)
			_, _ = h.s.db.Exec(context.Background(), `drop function if exists t19_fail_terminal_refund()`)
		})

		h.set("safety")
		key := uuid.NewString()
		h.frames(u, p, key, "fragment", "fragment", "safety")
		var state string
		var pending, workerCleared bool
		var unrefunded int
		h.must(h.s.db.QueryRow(h.ctx, `select a.state,w.settlement_pending,w.worker is null,
            (select count(*) from quota_ledger where activity_id=a.id and refunded_at is null)
            from activities a join practice_work w on w.activity_id=a.id where a.id=$1`, id).Scan(&state, &pending, &workerCleared, &unrefunded))
		if state != "safety" || pending || workerCleared || unrefunded != 1 {
			t.Fatalf("fallback terminal=%s pending=%t worker-cleared=%t unrefunded=%d", state, pending, workerCleared, unrefunded)
		}
		if v := h.history(u, p); v.Status != "safety" {
			t.Fatalf("fallback message status=%s want safety", v.Status)
		}

		h.set("safety")
		var finishTerminal gateway.Terminal
		h.json(finishUser.AccessToken, "POST", finishPath+"/finish", nil, 200, &finishTerminal)
		if !finishTerminal.Safety {
			t.Fatal("finish fallback hid safety terminal")
		}
		h.must(h.s.db.QueryRow(h.ctx, `select a.state,w.settlement_pending,w.worker is null,
            (select count(*) from quota_ledger where activity_id=a.id and refunded_at is null)
            from activities a join practice_work w on w.activity_id=a.id where a.id=$1`, finishID).Scan(&state, &pending, &workerCleared, &unrefunded))
		if state != "safety" || pending || workerCleared || unrefunded != 1 {
			t.Fatalf("fallback finish terminal=%s pending=%t worker-cleared=%t unrefunded=%d", state, pending, workerCleared, unrefunded)
		}
		if v := h.history(finishUser, finishPath); v.Status != "safety" {
			t.Fatalf("fallback finish status=%s want safety", v.Status)
		}

		h.exec(`drop trigger t19_fail_settlement_intent on practice_work`)
		h.exec(`drop trigger t19_fail_terminal_refund on quota_ledger`)
		h.must(h.s.Practice.ReplayPending(h.ctx))
		h.ledger(u, p, "safety", 0)
		h.ledger(finishUser, finishPath, "safety", 0)
		var refunded, finishRefunded int
		h.must(h.s.db.QueryRow(h.ctx, `select count(*) from quota_ledger where activity_id=$1 and refunded_at is not null`, id).Scan(&refunded))
		h.must(h.s.db.QueryRow(h.ctx, `select count(*) from quota_ledger where activity_id=$1 and refunded_at is not null`, finishID).Scan(&finishRefunded))
		if refunded != 1 || finishRefunded != 1 {
			t.Fatalf("refunds=%d/%d want 1/1", refunded, finishRefunded)
		}
		h.must(h.s.Practice.ReplayPending(h.ctx))
		h.must(h.s.db.QueryRow(h.ctx, `select count(*) from quota_ledger where activity_id=$1 and refunded_at is not null`, id).Scan(&refunded))
		h.must(h.s.db.QueryRow(h.ctx, `select count(*) from quota_ledger where activity_id=$1 and refunded_at is not null`, finishID).Scan(&finishRefunded))
		if refunded != 1 || finishRefunded != 1 {
			t.Fatalf("replay refunded twice: %d/%d", refunded, finishRefunded)
		}
		n := h.generations.Load()
		h.frames(u, p, key, "safety")
		if h.generations.Load() != n {
			t.Fatal("terminal message was regenerated after intent failure")
		}
		grades := h.grades.Load()
		h.json(finishUser.AccessToken, "POST", finishPath+"/finish", nil, 200, &finishTerminal)
		if !finishTerminal.Safety || h.grades.Load() != grades {
			t.Fatal("terminal finish was regenerated after intent failure")
		}
		h.set("")
	})
	t.Run("moderation_retry_settles_original_worker_first", func(t *testing.T) {
		u := h.user()
		p := h.create(u, 0)
		h.send(u, p)
		id := uuid.MustParse(strings.TrimPrefix(p, "sessions/"))
		h.exec(`create or replace function t19_fail_moderation_intent() returns trigger language plpgsql as $fn$ begin raise exception 'injected moderation intent failure'; end $fn$`)
		h.exec(`drop trigger if exists t19_fail_moderation_intent on practice_work`)
		h.exec(`create trigger t19_fail_moderation_intent before update of settlement_pending on practice_work for each row when (new.settlement_pending) execute function t19_fail_moderation_intent()`)
		h.exec(`create or replace function t19_fail_moderation_refund() returns trigger language plpgsql as $fn$ begin raise exception 'injected moderation refund failure'; end $fn$`)
		h.exec(`drop trigger if exists t19_fail_moderation_refund on quota_ledger`)
		h.exec(`create trigger t19_fail_moderation_refund before update of refunded_at on quota_ledger for each row when (old.refunded_at is null and new.refunded_at is not null) execute function t19_fail_moderation_refund()`)
		t.Cleanup(func() {
			h.set("")
			_, _ = h.s.db.Exec(context.Background(), `drop trigger if exists t19_fail_moderation_intent on practice_work`)
			_, _ = h.s.db.Exec(context.Background(), `drop trigger if exists t19_fail_moderation_refund on quota_ledger`)
			_, _ = h.s.db.Exec(context.Background(), `drop function if exists t19_fail_moderation_intent()`)
			_, _ = h.s.db.Exec(context.Background(), `drop function if exists t19_fail_moderation_refund()`)
		})

		h.set("outage")
		key := uuid.NewString()
		h.frames(u, p, key, "fragment", "fragment", "moderation_unavailable")
		var state, attemptState string
		var pending, workerCleared bool
		var worker uuid.UUID
		var unrefunded int
		h.must(h.s.db.QueryRow(h.ctx, `select a.state,w.settlement_pending,w.worker is null,w.worker,q.state,
            (select count(*) from quota_ledger where activity_id=a.id and refunded_at is null)
            from activities a join practice_work w on w.activity_id=a.id join quota_attempts q on q.activity_id=a.id where a.id=$1`, id).Scan(&state, &pending, &workerCleared, &worker, &attemptState, &unrefunded))
		if state != "moderation_unavailable" || pending || workerCleared || attemptState != "accepted" || unrefunded != 1 {
			t.Fatalf("fallback state=%s pending=%t worker-cleared=%t attempt=%s unrefunded=%d", state, pending, workerCleared, attemptState, unrefunded)
		}
		h.exec(`update practice_work set valid_until=now()-interval '1 second' where activity_id=$1`, id)

		generations := h.generations.Load()
		h.frames(u, p, key, "moderation_unavailable")
		if h.generations.Load() != generations {
			t.Fatal("retry regenerated before worker-fenced compensation")
		}
		var retryWorker uuid.UUID
		h.must(h.s.db.QueryRow(h.ctx, `select a.state,w.worker,q.state,
            (select count(*) from quota_ledger where activity_id=a.id and refunded_at is null)
            from activities a join practice_work w on w.activity_id=a.id join quota_attempts q on q.activity_id=a.id where a.id=$1`, id).Scan(&state, &retryWorker, &attemptState, &unrefunded))
		if state != "moderation_unavailable" || retryWorker != worker || attemptState != "accepted" || unrefunded != 1 {
			t.Fatalf("failed retry changed state=%s worker=%s/%s attempt=%s unrefunded=%d", state, retryWorker, worker, attemptState, unrefunded)
		}

		h.exec(`drop trigger t19_fail_moderation_intent on practice_work`)
		h.exec(`drop trigger t19_fail_moderation_refund on quota_ledger`)
		h.must(h.s.Practice.ReplayPending(h.ctx))
		var refunded, used int
		h.must(h.s.db.QueryRow(h.ctx, `select a.state,w.worker is null,q.state,
            (select count(*) from quota_ledger where activity_id=a.id and refunded_at is not null)
            from activities a join practice_work w on w.activity_id=a.id join quota_attempts q on q.activity_id=a.id where a.id=$1`, id).Scan(&state, &workerCleared, &attemptState, &refunded))
		h.must(h.s.db.QueryRow(h.ctx, `select used from daily_quota_usage where user_id=$1 and feature='practice'`, u.UserId).Scan(&used))
		if state != "moderation_unavailable" || !workerCleared || attemptState != "moderation_unavailable" || refunded != 1 || used != 0 {
			t.Fatalf("compensation state=%s worker-cleared=%t attempt=%s refunded=%d used=%d", state, workerCleared, attemptState, refunded, used)
		}

		h.set("")
		h.frames(u, p, key, "fragment", "fragment", "reply_saved")
		h.ledger(u, p, "active", 1)
	})
	t.Run("mid_turn_budget_cap_preserves_scoreable_history", func(t *testing.T) {
		u := h.user()
		p := h.create(u, 0)
		h.send(u, p)
		id := uuid.MustParse(strings.TrimPrefix(p, "sessions/"))
		h.exec(`update practice_work set used_tokens=29990 where activity_id=$1`, id)
		h.json(u.AccessToken, "POST", p+"/messages", map[string]string{"client_message_id": uuid.NewString(), "text": "好"}, 409, nil)
		v := h.history(u, p)
		if v.Status != "capped" || len(v.Messages) != 2 || v.Messages[1].Role != "assistant" || v.Settlement.Net != 1 {
			t.Fatalf("capped history=%s/%d/net=%d", v.Status, len(v.Messages), v.Settlement.Net)
		}
		if h.number(`select used_tokens from practice_work where activity_id=$1`, id) != 29990 {
			t.Fatal("unsaved turn changed token usage")
		}
		n := h.generations.Load()
		h.json(u.AccessToken, "POST", p+"/messages", body(uuid.NewString()), 409, nil)
		if h.generations.Load() != n {
			t.Fatal("capped session accepted another turn")
		}
		var res training.Result
		h.json(u.AccessToken, "POST", p+"/finish", nil, 200, &res)
		if res.Score == nil || res.Score.TargetTurn == nil || *res.Score.TargetTurn != 1 || res.Settlement.Net != 1 {
			t.Fatal("complete history was not scoreable after cap")
		}

		u = h.user()
		p = h.create(u, 0)
		h.send(u, p)
		id = uuid.MustParse(strings.TrimPrefix(p, "sessions/"))
		h.exec(`update practice_work set used_tokens=29900 where activity_id=$1`, id)
		h.set("cap")
		h.frames(u, p, uuid.NewString(), "fragment", "fragment")
		h.set("")
		v = h.history(u, p)
		if v.Status != "capped" || len(v.Messages) != 2 || v.Settlement.Net != 1 {
			t.Fatalf("provider usage cap=%s/%d/net=%d", v.Status, len(v.Messages), v.Settlement.Net)
		}
		h.json(u.AccessToken, "POST", p+"/finish", nil, 200, &res)
		if res.Score == nil || res.Score.TargetTurn == nil || *res.Score.TargetTurn != 1 || res.Settlement.Net != 1 {
			t.Fatal("provider usage cap lost scoreable history")
		}

		u = h.user()
		p = h.create(u, 0)
		id = uuid.MustParse(strings.TrimPrefix(p, "sessions/"))
		h.exec(`update practice_work set used_tokens=29990 where activity_id=$1`, id)
		h.json(u.AccessToken, "POST", p+"/messages", map[string]string{"client_message_id": uuid.NewString(), "text": "好"}, 409, nil)
		v = h.history(u, p)
		if v.Status != "capped" || len(v.Messages) != 0 || v.Settlement.Net != 0 {
			t.Fatalf("uncharged cap=%s/%d/net=%d", v.Status, len(v.Messages), v.Settlement.Net)
		}
		h.json(u.AccessToken, "POST", p+"/finish", nil, 409, nil)
		if h.number(`select count(*) from quota_ledger where activity_id=$1 and refunded_at is null`, id) != 0 {
			t.Fatal("incomplete first turn remained charged")
		}
	})
	t.Run("caps_repractice_delivery_and_erasure", func(t *testing.T) {
		for _, level := range []int{1, 5} {
			u := h.user()
			var previous uuid.UUID
			for attempt := 0; attempt < 2; attempt++ {
				p := h.create(u, level)
				turns := 2
				if attempt == 1 && level == 5 {
					turns = 30
				}
				if attempt == 0 {
					h.set("cap")
				}
				for i := 0; i < turns; i++ {
					h.send(u, p)
				}
				h.set("")
				sid := h.history(u, p).ID
				if turns == 30 {
					h.json(u.AccessToken, "POST", p+"/messages", body(uuid.NewString()), 409, nil)
				} else if attempt == 0 {
					if h.number(`select used_tokens from practice_work where activity_id=$1`, sid) != 30000 {
						t.Fatal("reported usage lost")
					}
					h.json(u.AccessToken, "POST", p+"/messages", body(uuid.NewString()), 409, nil)
				}
				f, d := full.Load(), skill.Load()
				if attempt == 0 {
					h.set("first_score")
				} else {
					h.set("second_score")
				}
				deny.Store(level == 5)
				var res, again training.Result
				h.json(u.AccessToken, "POST", p+"/finish", nil, 200, &res)
				h.set("")
				deny.Store(false)
				h.must(h.s.Practice.ReplayPending(h.ctx))
				h.json(u.AccessToken, "POST", p+"/finish", nil, 200, &again)
				if !reflect.DeepEqual(res, again) || res.Settlement.Net != 1 {
					t.Fatal("finish replay")
				}
				if level == 1 {
					if res.Score != nil || res.Progress == nil || res.Progress.NextAction != []string{"retry_in_three_days", "pass"}[attempt] || h.number(`select count(*) from scores where activity_id=$1`, sid) != 0 || f != full.Load() || skill.Load() != d+1 {
						t.Fatal("not isolated drill")
					}
				} else {
					if res.Progress != nil || res.Score == nil || res.Score.TargetTurn == nil || *res.Score.TargetTurn != turns || full.Load() != f+1 || skill.Load() != d || h.number(`select count(*) from ai_calls where score_id=$1 and activity_id=$2`, res.Score.ID, sid) != 1 {
						t.Fatal("score not linked once")
					}
				}
				if attempt == 1 {
					var page training.Page
					h.json(u.AccessToken, "GET", "sessions", nil, 200, &page)
					if len(page.Items) != 2 || page.Items[1].ID != previous || page.Items[0].ID != sid || previous == sid || !reflect.DeepEqual(page.Items[0].Level, page.Items[1].Level) || page.Items[1].Result == nil {
						t.Fatal("prior comparison")
					}
					prior := page.Items[1].Result
					if level == 1 && (prior.Progress.Score != 15 || res.Progress.Score != 25) || level == 5 && (prior.Score.NVC.Total != 60 || res.Score.NVC.Total != 100 || prior.Score.ID == res.Score.ID) {
						t.Fatal("prior score/source not preserved")
					}
					h.exportDelete(t, u, p, sid, res)
				}
				previous = sid
			}
		}
	})
	t.Run("chat_import_export_is_isolated_metadata", func(t *testing.T) {
		owner, foreign := h.user(), h.user()
		ownerLive := uuid.MustParse(strings.TrimPrefix(h.create(owner, 0), "sessions/"))
		ownerExpired := uuid.MustParse(strings.TrimPrefix(h.create(owner, 0), "sessions/"))
		foreignLive := uuid.MustParse(strings.TrimPrefix(h.create(foreign, 0), "sessions/"))
		now := time.Now().UTC().Truncate(time.Microsecond)
		ownerLiveAt := now.Add(-time.Minute)
		ownerExpiredAt := now.Add(-24 * time.Hour)
		foreignLiveAt := now.Add(-time.Minute)
		liveSecret, expiredSecret, foreignSecret := "owner-live-ciphertext", "owner-expired-ciphertext", "other-live-ciphertext"
		h.exec(`insert into chat_imports(activity_id,received_at,original_enc) values($1,$2,$3),($4,$5,$6),($7,$8,$9)`,
			ownerLive, ownerLiveAt, []byte(liveSecret),
			ownerExpired, ownerExpiredAt, []byte(expiredSecret),
			foreignLive, foreignLiveAt, []byte(foreignSecret))

		r := h.open(owner.AccessToken, "GET", "me/export", nil, 200)
		defer r.Body.Close()
		if got := r.Header.Get("Content-Type"); got != "application/zip" {
			t.Fatalf("export content type = %q", got)
		}
		raw, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatal(err)
		}
		z, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
		if err != nil {
			t.Fatal(err)
		}
		files := make(map[string][]byte, len(z.File))
		var names []string
		for _, f := range z.File {
			rc, err := f.Open()
			if err != nil {
				t.Fatal(err)
			}
			body, err := io.ReadAll(rc)
			rc.Close()
			if err != nil {
				t.Fatal(err)
			}
			if _, exists := files[f.Name]; exists {
				t.Fatalf("duplicate ZIP entry: %s", f.Name)
			}
			files[f.Name] = body
			names = append(names, f.Name)
		}
		strict := func(name string, dst any) {
			t.Helper()
			body, ok := files[name]
			if !ok {
				t.Fatalf("missing ZIP entry %s", name)
			}
			dec := json.NewDecoder(bytes.NewReader(body))
			dec.DisallowUnknownFields()
			if err := dec.Decode(dst); err != nil {
				t.Fatalf("strict decode %s: %v", name, err)
			}
			var trailing any
			if err := dec.Decode(&trailing); err != io.EOF {
				t.Fatalf("%s has trailing JSON: %v", name, err)
			}
		}

		var manifest struct {
			Modules []string `json:"modules"`
			Files   []string `json:"files"`
		}
		strict("manifest.json", &manifest)
		if !reflect.DeepEqual(names, manifest.Files) {
			t.Fatalf("ZIP entries = %v; manifest = %v", names, manifest.Files)
		}
		wantFiles := []string{"manifest.json"}
		for _, name := range manifest.Modules {
			wantFiles = append(wantFiles, name+".json")
		}
		if !reflect.DeepEqual(manifest.Files, wantFiles) {
			t.Fatalf("manifest files = %v, want %v", manifest.Files, wantFiles)
		}
		if !slices.Contains(manifest.Modules, "training") || !slices.Contains(manifest.Modules, "chat_imports") {
			t.Fatalf("manifest modules = %v, want training and chat_imports", manifest.Modules)
		}

		type exportedSession struct {
			training.Session
			Source uuid.UUID `json:"source_id"`
		}
		var sessions []exportedSession
		strict("training.json", &sessions)
		var liveSession, expiredSession bool
		for _, session := range sessions {
			if session.Source == uuid.Nil {
				t.Fatalf("training session %s has no source_id", session.ID)
			}
			switch session.ID {
			case ownerLive:
				liveSession = true
			case ownerExpired:
				expiredSession = true
			}
		}
		if len(sessions) != 2 || !liveSession || !expiredSession {
			t.Fatalf("training export did not contain exactly the owner sessions: %+v", sessions)
		}
		if bytes.Contains(files["training.json"], []byte(`"activity_id"`)) {
			t.Fatal("training.json contains chat import metadata")
		}

		var imports []struct {
			ActivityID         uuid.UUID `json:"activity_id"`
			ReceivedAt         time.Time `json:"received_at"`
			ContentUnavailable bool      `json:"content_unavailable"`
		}
		strict("chat_imports.json", &imports)
		if len(imports) != 1 {
			t.Fatalf("chat imports = %+v, want one live owner record", imports)
		}
		if imports[0].ActivityID != ownerLive || !imports[0].ReceivedAt.Equal(ownerLiveAt) || !imports[0].ContentUnavailable {
			t.Fatalf("chat import = %+v, want live owner metadata unavailable", imports[0])
		}
		importBody := files["chat_imports.json"]
		for _, forbidden := range []string{
			ownerExpired.String(), foreignLive.String(), "original_enc", liveSecret,
			base64.StdEncoding.EncodeToString([]byte(liveSecret)),
		} {
			if bytes.Contains(importBody, []byte(forbidden)) {
				t.Fatalf("chat_imports.json leaked %q: %s", forbidden, importBody)
			}
		}
		for _, file := range files {
			t35Exclude(t, file, liveSecret, expiredSecret, foreignSecret, `"original_enc":`,
				base64.StdEncoding.EncodeToString([]byte(liveSecret)),
				base64.StdEncoding.EncodeToString([]byte(expiredSecret)),
				base64.StdEncoding.EncodeToString([]byte(foreignSecret)))
		}
	})
	t.Run("owner_only_relaunch_inputs", h.checkRelaunch)

	// Run the write-producing wire checks after the existing assertions and replays.
	t.Run("strict_utf8_create_session_entrypoint", func(t *testing.T) {
		u := h.user()
		beforeActivities, beforeGenerations := h.number(`select count(*) from activities where user_id=$1`, u.UserId), h.generations.Load()
		post := func(token string, raw []byte) *http.Response {
			t.Helper()
			req, err := http.NewRequest(http.MethodPost, h.api.URL+"/v1/sessions", bytes.NewReader(raw))
			if err != nil {
				t.Fatal(err)
			}
			if token != "" {
				req.Header.Set("Authorization", "Bearer "+token)
			}
			resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
			if err != nil {
				t.Fatal(err)
			}
			return resp
		}
		assertRejected := func(token string, raw []byte, want int) {
			t.Helper()
			resp := post(token, raw)
			defer resp.Body.Close()
			response, err := io.ReadAll(resp.Body)
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != want {
				t.Fatalf("status=%d want %d: %s", resp.StatusCode, want, response)
			}
			if strings.Contains(string(response), "合成") {
				t.Fatalf("response echoed request text: %s", response)
			}
		}

		invalid := append([]byte(`{"request_id":"`+uuid.NewString()+`","scene":"work","scenario":"合成`), 0xff)
		invalid = append(invalid, []byte(`"}`)...)
		assertRejected("", invalid, http.StatusUnauthorized)
		assertRejected(u.AccessToken, invalid, http.StatusBadRequest)
		if got := h.number(`select count(*) from activities where user_id=$1`, u.UserId); got != beforeActivities {
			t.Fatalf("invalid encoding wrote %d activities, want %d", got, beforeActivities)
		}
		if got := h.generations.Load(); got != beforeGenerations {
			t.Fatalf("invalid encoding made %d model calls, want %d", got, beforeGenerations)
		}

		id := uuid.NewString()
		scenario := "合法多字节场景 �"
		valid := []byte(`{"request_id":"` + id + `","scene":"work","scenario":"` + scenario + `"}`)
		resp := post(u.AccessToken, valid)
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			response, _ := io.ReadAll(resp.Body)
			t.Fatalf("valid UTF-8 status=%d want 200: %s", resp.StatusCode, response)
		}
		var created training.SessionSummary
		if err := json.NewDecoder(resp.Body).Decode(&created); err != nil {
			t.Fatal(err)
		}
		if created.ID.String() != id {
			t.Fatalf("created session ID=%s want %s", created.ID, id)
		}
		detail := h.history(u, "sessions/"+id)
		if detail.Setup == nil || detail.Setup.Scenario == nil || *detail.Setup.Scenario != scenario {
			t.Fatalf("stored scenario=%v want %q", detail.Setup, scenario)
		}
	})

	t.Run("strict_utf8_admin_prompt_entrypoint", func(t *testing.T) {
		token := h.adminLogin()
		beforePrompts, beforeGenerations := h.number(`select count(*) from prompt_versions where task='reply_suggestion'`), h.generations.Load()
		post := func(raw []byte, authenticated bool) *http.Response {
			t.Helper()
			req, err := http.NewRequest(http.MethodPost, h.api.URL+"/admin/v1/prompt-versions", bytes.NewReader(raw))
			if err != nil {
				t.Fatal(err)
			}
			if authenticated {
				req.Header.Set("Authorization", "Bearer "+token)
			}
			resp, err := (&http.Client{Timeout: 20 * time.Second}).Do(req)
			if err != nil {
				t.Fatal(err)
			}
			return resp
		}
		assertRejected := func(raw []byte, authenticated bool, want int) {
			t.Helper()
			resp := post(raw, authenticated)
			defer resp.Body.Close()
			response, err := io.ReadAll(resp.Body)
			if err != nil {
				t.Fatal(err)
			}
			if resp.StatusCode != want {
				t.Fatalf("status=%d want %d: %s", resp.StatusCode, want, response)
			}
			if strings.Contains(string(response), "合成") {
				t.Fatalf("response echoed template text: %s", response)
			}
		}

		invalid := append([]byte(`{"task":"reply_suggestion","template":"合成`), 0xff)
		invalid = append(invalid, []byte(`"}`)...)
		assertRejected(invalid, false, http.StatusUnauthorized)
		assertRejected(invalid, true, http.StatusBadRequest)
		if got := h.number(`select count(*) from prompt_versions where task='reply_suggestion'`); got != beforePrompts {
			t.Fatalf("invalid encoding wrote %d prompt versions, want %d", got, beforePrompts)
		}
		if got := h.generations.Load(); got != beforeGenerations {
			t.Fatalf("invalid encoding made %d model calls, want %d", got, beforeGenerations)
		}

		template := "合法多字节模板 �"
		resp := post([]byte(`{"task":"reply_suggestion","template":"`+template+`"}`), true)
		defer resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			response, _ := io.ReadAll(resp.Body)
			t.Fatalf("valid UTF-8 status=%d want 200: %s", resp.StatusCode, response)
		}
		var stored admin.PromptVersion
		h.must(json.NewDecoder(resp.Body).Decode(&stored))
		var persisted string
		if err := h.s.db.QueryRow(h.ctx, `select template from prompt_versions where id=$1`, stored.Id).Scan(&persisted); err != nil {
			t.Fatal(err)
		}
		if stored.Task != admin.TaskReplySuggestion || stored.Template != template || persisted != template {
			t.Fatalf("stored prompt=%+v persisted=%q want task=reply_suggestion template=%q", stored, persisted, template)
		}
	})
}
