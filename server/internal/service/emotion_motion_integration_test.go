//go:build integration

package service

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
)

func motionHTTPFixture(t *testing.T, root *signalFixture, server *httptest.Server) *signalFixture {
	t.Helper()
	f := signalsFor(t, root.s, root.ctx)
	f.call = func(method, path, token string, v any, want int, out any) {
		t.Helper()
		code, raw := motionRequest(t, server, method, path, token, v)
		if code != want {
			t.Fatalf("%s %s: status %d, want %d, body %s", method, path, code, want, raw)
		}
		if out != nil {
			f.must(json.Unmarshal(raw, out))
		}
	}
	return f
}

func motionRequest(t *testing.T, server *httptest.Server, method, path, token string, v any) (int, []byte) {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequestWithContext(t.Context(), method, server.URL+"/v1/"+path, bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := server.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, err = io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, raw
}

func motionUser(f *signalFixture, target time.Time) app.Tokens {
	f.Helper()
	user := f.user()
	f.member(user)
	seedMotionVoiceHistory(f, user, target)
	f.call("POST", "signal-windows", user.AccessToken, synthetic(target, "voice", true), 200, nil)
	return user
}

func seedMotionVoiceHistory(f *signalFixture, user app.Tokens, target time.Time) {
	f.Helper()
	f.consents(user.UserId)
	f.exec(`update users set timezone='UTC' where id=$1`, user.UserId)
	now := time.Now()
	f.must(f.s.Data.Access(f.ctx, user.UserId, func(tx pgx.Tx) error {
		for d := 1; d <= 7; d++ {
			first := target.Truncate(24*time.Hour).AddDate(0, 0, -d).Add(12 * time.Hour)
			for i := range 60 {
				at := first.Add(time.Duration(i) * 30 * time.Second)
				if err := f.s.Emotion.Upload(f.ctx, tx, user.UserId, synthetic(at, "voice", false), now); err != nil {
					return err
				}
			}
		}
		return nil
	}))
}

func motionEvent(target time.Time) app.ReportSignalEventJSONBody {
	return app.ReportSignalEventJSONBody{Id: uuid.New(), Kind: emotion.Rhythm, StartsAt: target}
}

func checkMotionReport(f *signalFixture, server *httptest.Server, user app.Tokens, event app.ReportSignalEventJSONBody, wantStatus, wantDelta int) {
	f.Helper()
	count := func() (all, byID, matching int) {
		f.must(f.s.db.QueryRow(f.ctx, `select count(*), count(*) filter (where id=$2), count(*) filter (where id=$2 and occurred_at=$3)
			from signal_events where user_id=$1`, user.UserId, event.Id, event.StartsAt).Scan(&all, &byID, &matching))
		return
	}
	before, oldID, oldMatch := count()
	status, body := motionRequest(f.T, server, "POST", "signal-events", user.AccessToken, event)
	after, newID, newMatch := count()
	f.Logf("POST /v1/signal-events HTTP=%d body=%s, PG total/ID/ID+slot %d/%d/%d -> %d/%d/%d",
		status, body, before, oldID, oldMatch, after, newID, newMatch)
	if status != wantStatus || after-before != wantDelta || newID-oldID != wantDelta || newMatch-oldMatch != wantDelta {
		f.Errorf("HTTP=%d, PG deltas=%d/%d/%d, want HTTP=%d and each delta=%d",
			status, after-before, newID-oldID, newMatch-oldMatch, wantStatus, wantDelta)
	}
	var result struct {
		OK   bool   `json:"ok"`
		Code string `json:"code"`
	}
	f.must(json.Unmarshal(body, &result))
	wantCode := map[int]string{200: "", 400: "invalid_argument", 403: "forbidden", 409: "conflict", 500: "internal_error"}
	if result.OK != (status == 200) || result.Code != wantCode[status] {
		f.Errorf("unexpected response for HTTP %d: %s", status, body)
	}
}

func TestT32BMotionAdmissionHTTP(t *testing.T) {
	root := setupWindowBaselineSignals(t)
	server := httptest.NewServer(root.s.Router())
	t.Cleanup(server.Close)
	target := time.Now().UTC().Truncate(30 * time.Second).Add(-10 * time.Minute)
	for _, tc := range []struct {
		name   string
		legacy bool
		status int
	}{
		{"no_production_source_no_health_windows", false, 400},
		{"no_production_source_full_legacy_apple_history", true, 400},
		{"health_withdrawn", false, 403},
		{"health_regranted_after_target", false, 403},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := motionHTTPFixture(t, root, server)
			user := motionUser(f, target)
			if tc.legacy {
				zero, seconds := 0., 30
				for slot := -3; slot <= 0; slot++ {
					w := synthetic(target.Add(time.Duration(slot)*30*time.Second), "health", false)
					w.Source = "apple_history"
					w.Cadence = &emotion.Stat{Mean: &zero, Maximum: &zero, Count: 2, Seconds: &seconds}
					f.call("POST", "signal-windows", user.AccessToken, w, 200, nil)
				}
			}
			switch tc.name {
			case "health_withdrawn", "health_regranted_after_target":
				f.call("PUT", "me/consents/health", user.AccessToken, map[string]any{"version": "v1", "granted": false}, 200, nil)
				if tc.name == "health_regranted_after_target" {
					f.call("PUT", "me/consents/health", user.AccessToken, map[string]any{"version": "v2", "granted": true}, 200, nil)
				}
			}
			checkMotionReport(f, server, user, motionEvent(target), tc.status, 0)
		})
	}

	t.Run("synthetic_motion_source", func(t *testing.T) {
		testSyntheticMotionAdmission(t, root, server, target)
	})
}

type syntheticMotionKey struct {
	user   uuid.UUID
	target time.Time
}

func provideRhythmMotion(runtime *Runtime) map[syntheticMotionKey]emotion.RhythmMotionEvidence {
	synthetic := make(map[syntheticMotionKey]emotion.RhythmMotionEvidence)
	runtime.Emotion.ReadRhythmMotion = func(_ context.Context, _ pgx.Tx, user uuid.UUID, target time.Time) (emotion.RhythmMotionEvidence, error) {
		return synthetic[syntheticMotionKey{user, target}], nil
	}
	return synthetic
}

func syntheticRhythmMotion(f *signalFixture, user uuid.UUID, target time.Time, cadence float64) emotion.RhythmMotionEvidence {
	f.Helper()
	var grant uuid.UUID
	f.must(f.s.db.QueryRow(f.ctx, `select id from consents where user_id=$1 and purpose='health' and withdrawn_at is null`, user).Scan(&grant))
	exercise := false
	return emotion.RhythmMotionEvidence{
		HealthGrantID: grant, CadenceFrom: target.Add(-90 * time.Second), CadenceUntil: target.Add(30 * time.Second),
		CadencePerMinute: &cadence, ExerciseFrom: target, ExerciseUntil: target.Add(30 * time.Second), Exercise: &exercise,
	}
}

func seedCooldownEvent(f *signalFixture, user uuid.UUID, at time.Time) {
	f.Helper()
	id := uuid.New()
	raw, err := json.Marshal(app.SignalEvent{Id: id, StartsAt: at, Kind: emotion.Rhythm, Confirmation: "pending"})
	f.must(err)
	enc, err := f.s.Emotion.Fields.Seal(raw, []byte("event/"+user.String()+"/"+id.String()))
	f.must(err)
	f.exec(`insert into signal_events(id,user_id,occurred_at,event_enc) values($1,$2,$3,$4)`, id, user, at, enc)
}

func testSyntheticMotionAdmission(t *testing.T, root *signalFixture, server *httptest.Server, target time.Time) {
	t.Helper()
	motion := provideRhythmMotion(root.s)
	for _, tc := range []struct {
		name     string
		cadence  float64
		cooldown time.Duration
		status   int
		delta    int
	}{
		{name: "reader_has_no_evidence", status: 400},
		{name: "exercise_unknown", cadence: 80, status: 400},
		{name: "cadence_unknown", status: 400},
		{name: "cadence_partial", status: 400},
		{name: "exercise_partial", status: 400},
		{name: "previous_slot_stale", status: 400},
		{name: "old_grant_same_coverage", status: 400},
		{name: "grant_starts_inside_cadence", status: 403},
		{name: "membership_starts_inside_cadence", status: 403},
		{name: "withdrawal_with_cached_evidence", status: 403},
		{name: "exercise_detected", status: 400},
		{name: "non_finite_cadence", cadence: math.NaN(), status: 400},
		{name: "negative_cadence", cadence: -1, status: 400},
		{name: "measured_zero", status: 200, delta: 1},
		{name: "cadence_100", cadence: 100, status: 200, delta: 1},
		{name: "cadence_101", cadence: 101, status: 400},
		{name: "cooldown_599", cadence: 100, cooldown: 599 * time.Second, status: 409},
		{name: "cooldown_600", cadence: 100, cooldown: 600 * time.Second, status: 200, delta: 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := motionHTTPFixture(t, root, server)
			user := motionUser(f, target)
			key := syntheticMotionKey{user.UserId, target}
			evidence := syntheticRhythmMotion(f, user.UserId, target, tc.cadence)
			switch tc.name {
			case "reader_has_no_evidence":
				evidence = emotion.RhythmMotionEvidence{}
			case "exercise_unknown":
				evidence.Exercise = nil
			case "cadence_unknown":
				evidence.CadencePerMinute = nil
			case "cadence_partial":
				evidence.CadenceFrom = evidence.CadenceFrom.Add(time.Second)
			case "exercise_partial":
				evidence.ExerciseUntil = evidence.ExerciseUntil.Add(-time.Second)
			case "previous_slot_stale":
				evidence = syntheticRhythmMotion(f, user.UserId, target.Add(-30*time.Second), tc.cadence)
			case "old_grant_same_coverage":
				evidence.HealthGrantID = uuid.New()
			case "grant_starts_inside_cadence":
				f.exec(`update consents set granted_at=$2 where user_id=$1 and purpose='health'`, user.UserId, target.Add(-time.Minute))
			case "membership_starts_inside_cadence":
				f.exec(`update entitlements set starts_at=$2 where user_id=$1`, user.UserId, target.Add(-time.Minute))
			case "withdrawal_with_cached_evidence":
				f.call("PUT", "me/consents/health", user.AccessToken, map[string]any{"version": "v1", "granted": false}, 200, nil)
			case "exercise_detected":
				*evidence.Exercise = true
			}
			if tc.cooldown != 0 {
				// A 599-second offset cannot be reported by the aligned public
				// route. Seed a committed row to exercise the SQL boundary.
				seedCooldownEvent(f, user.UserId, target.Add(-tc.cooldown))
			}
			motion[key] = evidence
			checkMotionReport(f, server, user, motionEvent(target), tc.status, tc.delta)
		})
	}

	t.Run("stable_id_receipt_after_motion_disappears_and_health_withdrawal", func(t *testing.T) {
		f := motionHTTPFixture(t, root, server)
		user := motionUser(f, target)
		key := syntheticMotionKey{user.UserId, target}
		motion[key] = syntheticRhythmMotion(f, user.UserId, target, 100)
		event := motionEvent(target)
		checkMotionReport(f, server, user, event, 200, 1)
		delete(motion, key)
		checkMotionReport(f, server, user, event, 200, 0)
		f.call("PUT", "me/consents/health", user.AccessToken, map[string]any{"version": "v1", "granted": false}, 200, nil)
		checkMotionReport(f, server, user, event, 200, 0)
		checkMotionReport(f, server, user, motionEvent(target), 409, 0)
		mismatch := event
		mismatch.StartsAt = target.Add(-30 * time.Second)
		checkMotionReport(f, server, user, mismatch, 409, 0)
		f.call("PUT", "me/consents/voice", user.AccessToken, map[string]any{"version": "v1", "granted": false}, 200, nil)
		checkMotionReport(f, server, user, event, 403, 0)
	})

	t.Run("source_failure_has_no_ack", func(t *testing.T) {
		f := motionHTTPFixture(t, root, server)
		user := motionUser(f, target)
		reader := root.s.Emotion.ReadRhythmMotion
		t.Cleanup(func() { root.s.Emotion.ReadRhythmMotion = reader })
		evidence := syntheticRhythmMotion(f, user.UserId, target, 100)
		root.s.Emotion.ReadRhythmMotion = func(context.Context, pgx.Tx, uuid.UUID, time.Time) (emotion.RhythmMotionEvidence, error) {
			return evidence, errors.New("synthetic source failure")
		}
		checkMotionReport(f, server, user, motionEvent(target), 500, 0)
	})
}
