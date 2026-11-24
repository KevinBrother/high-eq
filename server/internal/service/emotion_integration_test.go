//go:build integration

package service

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/events"
	"high-eq/server/internal/privacy"
)

type signalFixture struct {
	*testing.T
	s    *Runtime
	call func(method, path, token string, v any, status int, out any)
	ctx  context.Context
}

func setupSignals(t *testing.T) *signalFixture {
	t.Helper()
	cfg, e := LoadConfig()
	if e != nil {
		t.Fatal(e)
	}
	return setupSignalsWithConfig(t, cfg)
}

func setupSignalsWithConfig(t *testing.T, cfg Config) *signalFixture {
	t.Helper()
	ctx := context.Background()
	s, e := Start(ctx, cfg)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(s.Close)
	return signalsFor(t, s, ctx)
}

func signalsFor(t *testing.T, s *Runtime, ctx context.Context) *signalFixture {
	r := s.Router()
	return &signalFixture{T: t, s: s, ctx: ctx, call: func(method, path, token string, v any, status int, out any) {
		t.Helper()
		b, e := json.Marshal(v)
		if e != nil {
			t.Fatal(e)
		}
		req := httptest.NewRequest(method, "/v1/"+path, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != status {
			t.Fatalf("%s %s: %d want %d: %s", method, path, w.Code, status, w.Body)
		}
		if out != nil {
			if e := json.Unmarshal(w.Body.Bytes(), out); e != nil {
				t.Fatal(e)
			}
		}
	}}
}
func (f *signalFixture) must(e error) {
	f.Helper()
	if e != nil {
		f.Fatal(e)
	}
}
func (f *signalFixture) user() app.Tokens {
	f.Helper()
	ticket := uuid.NewString()
	f.must(f.s.cache.Set(f.ctx, "dev:ticket:apple:"+ticket, uuid.NewString(), time.Minute).Err())
	var a app.Tokens
	f.call("POST", "auth/login", "", map[string]any{"credential": map[string]string{"provider": "apple", "proof": ticket}, "age_confirmed": true, "privacy_version": "2026-11", "terms_version": "2026-11"}, 200, &a)
	return a
}
func (f *signalFixture) exec(q string, args ...any) {
	f.Helper()
	_, e := f.s.db.Exec(f.ctx, q, args...)
	f.must(e)
}
func (f *signalFixture) member(a app.Tokens) {
	f.exec(`with o as (insert into orders(user_id,platform,transaction_hmac,product_code,amount_fen,state) values($1,'apple',$2,'fixture',1,'paid') returning id,user_id) insert into entitlements select id,user_id,now()-interval '181 days',now()+interval '1 day' from o`, a.UserId, []byte(uuid.NewString()))
}
func (f *signalFixture) consents(u uuid.UUID) {
	f.exec(`insert into consents(user_id,purpose,version,granted_at) select $1,p,'v1',now()-interval '181 days' from unnest(array['voice','health']) p`, u)
}
func (f *signalFixture) export(u uuid.UUID) []byte {
	f.Helper()
	var b bytes.Buffer
	f.must(f.s.Data.Export(f.ctx, privacy.ExportRequest{OperationID: uuid.New(), UserID: u}, &b))
	z, e := zip.NewReader(bytes.NewReader(b.Bytes()), int64(b.Len()))
	f.must(e)
	file, e := z.Open("emotion.json")
	f.must(e)
	defer file.Close()
	p, e := io.ReadAll(file)
	f.must(e)
	return p
}
func synthetic(at time.Time, k string, high bool) emotion.Window {
	ex := false
	secs := 30
	stat := func(v float64) *emotion.Stat { return &emotion.Stat{Mean: &v, Maximum: &v, Count: 2, Seconds: &secs} }
	w := emotion.Window{At: at, Exercise: &ex, Channel: k, Duration: 30}
	if k == "health" {
		w.Source = "watch_live"
		v := 80.
		if high {
			v = 112
		}
		w.Heart = stat(v)
	} else {
		w.Voiced = &secs
		w.SpeechRateUnit = emotion.SpeechRateUnitCharactersPerSecond
		if high {
			w.Speech = stat(6)
			w.Volume = stat(-20)
		} else {
			w.Speech = stat(4)
			w.Volume = stat(-40)
		}
	}
	return w
}
func TestEmotionErasureAndExpiry(t *testing.T) {
	f := setupSignals(t)
	a, b := f.user(), f.user()
	now := time.Now().UTC().Truncate(30 * time.Second)
	at := now.Add(-time.Minute)
	w := synthetic(at, "health", false)
	path := "signal-windows"
	del := path + "?channel=health&starts_at=" + url.QueryEscape(at.Format(time.RFC3339))
	f.call("POST", path, "", w, 401, nil)
	f.call("POST", path, a.AccessToken, w, 403, nil)
	f.member(a)
	f.call("POST", path, a.AccessToken, w, 403, nil)
	f.consents(a.UserId)
	// Simulate a new verified period after a lapse: old buffered data stays rejected.
	f.exec(`update entitlements set starts_at=$2 where user_id=$1`, a.UserId, at.Add(time.Second))
	f.call("POST", path, a.AccessToken, w, 403, nil)
	f.exec(`update entitlements set starts_at=now()-interval '181 days' where user_id=$1`, a.UserId)
	f.call("POST", path, a.AccessToken, w, 200, nil)
	f.call("POST", path, a.AccessToken, w, 200, nil)
	f.call("POST", path, a.AccessToken, synthetic(at, "health", true), 409, nil)
	f.call("DELETE", del, b.AccessToken, nil, 404, nil)
	f.member(b)
	f.consents(b.UserId)
	f.call("POST", path, b.AccessToken, w, 200, nil)
	f.call("POST", path, a.AccessToken, synthetic(now, "health", true), 200, nil)
	var key uuid.UUID
	var enc []byte
	f.must(f.s.db.QueryRow(f.ctx, `select purge_id,stats_enc from signal_windows where user_id=$1 and starts_at=$2`, a.UserId, at).Scan(&key, &enc))
	check := func(u uuid.UUID, n int) {
		t.Helper()
		data := f.export(u)
		if bytes.Count(data, []byte(`"window":`)) != n || bytes.Contains(data, []byte(key.String())) || bytes.Contains(data, []byte("purge_id")) {
			t.Fatalf("unexpected export: %s", data)
		}
	}
	check(a.UserId, 2)
	f.call("DELETE", del, a.AccessToken, nil, 200, nil)
	check(a.UserId, 1)
	// Restore this exact pre-delete SQL row, *without* restoring the independent ledger.
	f.exec(`insert into signal_windows(user_id,starts_at,channel,purge_id,stats_enc) values($1,$2,'health',$3,$4)`, a.UserId, at, key, enc)
	if e := f.s.Data.Export(f.ctx, privacy.ExportRequest{OperationID: uuid.New(), UserID: a.UserId}, io.Discard); !errors.Is(e, privacy.ErrHidden) {
		t.Fatalf("restored source visible: %v", e)
	}
	f.must(f.s.Data.Resume(f.ctx))
	check(a.UserId, 1)
	check(b.UserId, 1)
	var base emotion.Baselines
	f.call("GET", "signal-baselines", a.AccessToken, nil, 200, &base)
	if base.Heart.Today != 30 {
		t.Fatalf("deleted duration retained: %+v", base)
	}
	// Preload a once-valid window exactly at the retention boundary. Reads filter
	// before maintenance; sweep must still physically remove its row and event.
	old := now.Add(-180 * 24 * time.Hour)
	f.must(f.s.Data.Access(f.ctx, a.UserId, func(tx pgx.Tx) error {
		return f.s.Emotion.Upload(f.ctx, tx, a.UserId, synthetic(old, "health", false), old)
	}))
	id := uuid.New()
	f.exec(`insert into signal_events(id,user_id,occurred_at,event_enc) values($1,$2,$3,'expired')`, id, a.UserId, old)
	check(a.UserId, 1)
	f.must(f.s.Emotion.PurgeDue(f.ctx, now))
	var gone bool
	f.must(f.s.db.QueryRow(f.ctx, `select not exists(select from signal_windows where user_id=$1 and starts_at=$2) and not exists(select from signal_events where id=$3)`, a.UserId, old, id).Scan(&gone))
	if !gone {
		t.Fatal("expired sources retained")
	}
	check(b.UserId, 1)
	f.exec(`update consents set withdrawn_at=now() where user_id=$1 and purpose='health'`, a.UserId)
	f.call("POST", path, a.AccessToken, w, 403, nil)
	f.exec(`insert into consents(user_id,purpose,version) values($1,'health','v2')`, a.UserId)
	f.call("POST", path, a.AccessToken, w, 403, nil)
	f.exec(`update entitlements set ends_at=now() where user_id=$1`, a.UserId)
	f.call("GET", "signal-baselines", a.AccessToken, nil, 403, nil)
	f.call("DELETE", path+"?channel=health&starts_at="+url.QueryEscape(now.Format(time.RFC3339)), a.AccessToken, nil, 200, nil)
	check(a.UserId, 0)
}

func TestEmotionFeedbackIsExplicit(t *testing.T) {
	f := setupSignals(t)
	a := f.user()
	f.member(a)
	f.consents(a.UserId)
	now := time.Now().UTC()
	at := now.Truncate(30 * time.Second).Add(-11 * time.Minute)
	selfAt := at.Add(10 * time.Minute)
	u := a.UserId
	f.exec(`update users set timezone='UTC' where id=$1`, u)
	// A ready synthetic history, without HRV: both channels have 7 independent valid days.
	f.must(f.s.Data.Access(f.ctx, u, func(tx pgx.Tx) error {
		upload := func(at time.Time, k string, hi bool) error {
			return f.s.Emotion.Upload(f.ctx, tx, u, synthetic(at, k, hi), now)
		}
		for d := 1; d <= 7; d++ {
			day := now.Truncate(24*time.Hour).AddDate(0, 0, -d).Add(12 * time.Hour)
			for i := 0; i < 60; i++ {
				for _, k := range []string{"health", "voice"} {
					if e := upload(day.Add(time.Duration(i)*30*time.Second), k, false); e != nil {
						return e
					}
				}
			}
		}
		for _, k := range []string{"health", "voice"} {
			if e := upload(at, k, k == "voice"); e != nil {
				return e
			}
			if e := upload(selfAt, k, true); e != nil {
				return e
			}
		}
		return nil
	}))
	event := func(at time.Time, k string) app.ReportSignalEventJSONBody {
		return app.ReportSignalEventJSONBody{Id: uuid.New(), StartsAt: at, Kind: app.ReportSignalEventJSONBodyKind(k)}
	}
	rh := event(at, emotion.Rhythm)
	p := "signal-events"
	f.call("POST", p, a.AccessToken, rh, 200, nil)
	f.call("POST", p, a.AccessToken, rh, 200, nil)
	f.call("PATCH", p+"/"+rh.Id.String(), a.AccessToken, map[string]any{"scene": "work"}, 200, nil)
	f.call("PATCH", p+"/"+rh.Id.String(), a.AccessToken, map[string]any{"confirmation": "yes"}, 400, nil)
	self := event(selfAt, emotion.Self)
	f.call("POST", p, a.AccessToken, self, 403, nil)
	f.must(f.s.Data.Access(f.ctx, u, func(tx pgx.Tx) error { return f.s.Emotion.Report(f.ctx, tx, u, self, now, true) })) // test-only released Watch input; production policy unchanged
	delivered := 0
	var first events.Feedback
	f.s.Bus.ProfileFeedback.Subscribe(func(ctx context.Context, tx pgx.Tx, v events.Feedback) error {
		r, e := f.s.Emotion.Confirmed(ctx, tx, v.UserID, v.SourceID)
		if e != nil {
			return e
		}
		if r.Confirmation != "no" || v.Subject != "self" || v.SourceID != self.Id || v.FeedbackID == uuid.Nil || v.ContactID != nil {
			t.Fatal("misattributed feedback")
		}
		if first.FeedbackID == uuid.Nil {
			first = v
			return errors.New("synthetic subscriber temporarily unavailable")
		}
		if first.FeedbackID != v.FeedbackID || !first.OccurredAt.Equal(v.OccurredAt) {
			t.Fatal("replay changed feedback identity")
		}
		delivered++
		return nil
	})
	f.must(f.s.Emotion.ReplayPending(f.ctx))
	if delivered != 0 {
		t.Fatal("unconfirmed evidence")
	}
	patch := func() {
		f.call("PATCH", p+"/"+self.Id.String(), a.AccessToken, map[string]any{"confirmation": "no"}, 200, nil)
	}
	var before, after emotion.Baselines
	f.call("GET", "signal-baselines", a.AccessToken, nil, 200, &before)
	patch()
	patch()
	f.call("GET", "signal-baselines", a.AccessToken, nil, 200, &after)
	if !after.Heart.Ready || math.Abs(*after.Heart.Threshold-1.05**before.Heart.Threshold) > 1e-8 {
		t.Fatal("repeated annotation changed the threshold twice")
	}
	day := now.Truncate(24*time.Hour).AddDate(0, 0, -7).Add(12 * time.Hour)
	f.call("DELETE", "signal-windows?channel=health&starts_at="+url.QueryEscape(day.Format(time.RFC3339)), a.AccessToken, nil, 200, nil)
	f.call("GET", "signal-baselines", a.AccessToken, nil, 200, &after)
	if after.Heart.Ready || after.Heart.Threshold != nil || after.Heart.Days != 6 || !after.Speech.Ready {
		t.Fatal("single-window deletion did not invalidate only the affected baseline")
	}

	if f.s.Emotion.ReplayPending(f.ctx) == nil {
		t.Fatal("lost failed delivery")
	}
	f.must(f.s.Emotion.ReplayPending(f.ctx))
	f.must(f.s.Emotion.ReplayPending(f.ctx))
	if delivered != 1 {
		t.Fatal(delivered)
	}
	var page emotion.Page
	f.call("GET", p+"?limit=1", a.AccessToken, nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != self.Id || page.Next == nil {
		t.Fatal(page)
	}
	f.call("GET", p+"?cursor="+*page.Next, a.AccessToken, nil, 200, &page)
	if len(page.Items) != 1 || page.Items[0].Id != rh.Id || page.Next != nil {
		t.Fatal(page)
	}
	foreign := f.user()
	f.member(foreign)
	f.consents(foreign.UserId)
	foreignAt := at.Add(-30 * time.Second)
	f.call("POST", "signal-windows", foreign.AccessToken, synthetic(foreignAt, "health", true), 200, nil)
	var purgeID uuid.UUID
	f.must(f.s.db.QueryRow(f.ctx, "select purge_id from signal_windows where user_id=$1 and starts_at=$2 and channel='voice'", u, at).Scan(&purgeID))
	router := f.s.Router()
	body := t35Part(t, t35Download(t, router, a.AccessToken), "emotion")
	t35Exclude(t, body, purgeID.String(), `"purge_id":`, `"feedback_pending":`, `"stats_enc":`,
		`"raw_samples":`, `"pcm":`, `"transcript":`)
	var rows []struct {
		Window   *emotion.Window    `json:"window"`
		Event    *app.SignalEvent   `json:"event"`
		Baseline *emotion.Baselines `json:"baselines"`
	}
	t35Decode(t, body, &rows)
	var health, voice, rhythm, confirmed, baseline bool
	for _, row := range rows {
		if w := row.Window; w != nil {
			if w.At.Equal(foreignAt) {
				t.Fatal("emotion.json contains a foreign window")
			}
			health = health || w.At.Equal(at) && w.Channel == "health" && w.Duration == 30 &&
				w.Heart != nil && w.Heart.Mean != nil && *w.Heart.Mean == 80
			voice = voice || w.At.Equal(at) && w.Channel == "voice" && w.Duration == 30 &&
				w.Speech != nil && w.Speech.Mean != nil && *w.Speech.Mean == 6 &&
				w.SpeechRateUnit == emotion.SpeechRateUnitCharactersPerSecond
		}
		if event := row.Event; event != nil {
			rhythm = rhythm || event.Id == rh.Id && event.StartsAt.Equal(at) &&
				string(event.Kind) == emotion.Rhythm && event.Scene != nil && *event.Scene == "work"
			confirmed = confirmed || event.Id == self.Id && event.StartsAt.Equal(selfAt) &&
				string(event.Kind) == emotion.Self && event.Confirmation == "no"
		}
		if b := row.Baseline; b != nil {
			baseline = !b.Heart.Ready && b.Heart.Days == after.Heart.Days &&
				b.Speech.Ready && b.Speech.Days == after.Speech.Days && b.Speech.Threshold != nil &&
				after.Speech.Threshold != nil && *b.Speech.Threshold == *after.Speech.Threshold
		}
	}
	if !health || !voice || !rhythm || !confirmed || !baseline {
		t.Fatalf("emotion.json missing health/voice/rhythm/confirmation/baselines: %t/%t/%t/%t/%t",
			health, voice, rhythm, confirmed, baseline)
	}
	foreignData := t35Part(t, t35Download(t, router, foreign.AccessToken), "emotion")
	t35Exclude(t, foreignData, rh.Id.String(), self.Id.String())
}
