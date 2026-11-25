//go:build integration

package service

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/fieldcrypt"
)

func setupWindowBaselineSignals(t *testing.T) *signalFixture {
	t.Helper()
	dir := os.Getenv("T32B_REVIEW_SOCKET_DIR")
	if dir == "" {
		if os.Getenv("APP_ENV") == "development" {
			return setupSignals(t)
		}
		t.Skip("set T32B_REVIEW_SOCKET_DIR or supply the development integration configuration")
	}
	var key [32]byte
	if _, err := rand.Read(key[:]); err != nil {
		t.Fatal(err)
	}
	fields, err := fieldcrypt.New(1, map[uint32][]byte{1: key[:]})
	if err != nil {
		t.Fatal(err)
	}
	query := url.Values{"host": {dir}, "sslmode": {"disable"}}
	return setupSignalsWithConfig(t, Config{
		Environment:          "development",
		DatabaseURL:          "postgres://t32b_review@/postgres?" + query.Encode(),
		DatabasePoolMaxConns: 4,
		Cache:                &redis.Options{Network: "unix", Addr: filepath.Join(dir, "cache.sock")},
		Ledger:               &redis.Options{Network: "unix", Addr: filepath.Join(dir, "ledger.sock")},
		BackupDays:           1,
		Fields:               fields,
		authMaster:           key[:],
	})
}

// Run against the isolated development integration services or host Unix sockets.
func TestT32BWindowBaselinePostgres(t *testing.T) {
	fixture := setupWindowBaselineSignals(t)
	now := time.Now().UTC()
	target := now.Truncate(24 * time.Hour).Add(-16*time.Hour + 30*time.Second)
	windowQuery := func(at time.Time) string {
		return "signal-baselines?for_window=" + url.QueryEscape(at.Format(time.RFC3339Nano))
	}
	newUser := func(f *signalFixture) app.Tokens {
		f.Helper()
		user := f.user()
		f.member(user)
		f.consents(user.UserId)
		f.exec(`update users set timezone='UTC' where id=$1`, user.UserId)
		return user
	}
	voice := func(at time.Time, speech, volume float64) emotion.Window {
		w := synthetic(at, "voice", false)
		w.Speech.Mean, w.Speech.Maximum = &speech, &speech
		w.Volume.Mean, w.Volume.Maximum = &volume, &volume
		return w
	}
	for _, tc := range []struct {
		name              string
		lastDay           int
		newerFirst        bool
		wantReport        int
		wantCurrentVolume float64
	}{
		{"same_slot_after_commit", 60, false, 200, -29.985748218527316},
		{"seventh_day_after_commit", 59, false, 400, -29.985714285714288},
		{"late_with_newer_history", 60, true, 200, -29.942992874109262},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := signalsFor(t, fixture.s, fixture.ctx)
			user := newUser(f)
			f.must(f.s.Data.Access(f.ctx, user.UserId, func(tx pgx.Tx) error {
				for d := 6; d >= 0; d-- {
					n := 60
					if d == 0 {
						n = tc.lastDay
					}
					first := target.AddDate(0, 0, -d).Add(-30 * time.Minute)
					for i := range n {
						w := voice(first.Add(time.Duration(i)*30*time.Second), 4, -36)
						if err := f.s.Emotion.Upload(f.ctx, tx, user.UserId, w, now); err != nil {
							return err
						}
					}
				}
				return nil
			}))
			if tc.newerFirst {
				f.call("POST", "signal-windows", user.AccessToken, voice(target.Add(30*time.Second), 4, -12), 200, nil)
			}
			f.call("GET", windowQuery(target), user.AccessToken, nil, 404, nil)
			var current emotion.Baselines
			readCurrent := func() {
				f.call("GET", "signal-baselines", user.AccessToken, nil, 200, &current)
				if !current.Volume.Ready || current.Volume.Days != 7 || current.Volume.Today != 0 ||
					current.Volume.Threshold == nil || math.Abs(*current.Volume.Threshold-tc.wantCurrentVolume) > 1e-10 {
					t.Fatalf("ordinary GET volume = %+v, want ready with threshold %v and no seconds today", current.Volume, tc.wantCurrentVolume)
				}
			}
			if tc.newerFirst {
				readCurrent()
			}
			f.call("POST", "signal-windows", user.AccessToken, voice(target, 5, -30), 200, nil)
			var committed bool
			f.must(f.s.db.QueryRow(f.ctx, `select exists(select from signal_windows where user_id=$1 and starts_at=$2 and channel='voice')`,
				user.UserId, target).Scan(&committed))
			if !committed {
				t.Fatal("target missing after upload response")
			}
			if !tc.newerFirst {
				readCurrent()
			}
			var scoped emotion.Baselines
			f.call("GET", windowQuery(target), user.AccessToken, nil, 200, &scoped)
			for _, want := range []struct {
				name      string
				progress  emotion.Progress
				base      float64
				threshold float64
			}{
				{"speech", scoped.Speech, 4, 5},
				{"volume", scoped.Volume, -36, -30},
			} {
				p := want.progress
				if tc.lastDay == 59 {
					if p.Ready || p.Days != 6 || p.Today != 1770 || p.Threshold != nil || p.Baseline != nil {
						t.Fatalf("target completed its own seventh day for %s: %+v", want.name, p)
					}
				} else if !p.Ready || p.Days != 7 || p.Today != 1800 || p.Baseline == nil || *p.Baseline != want.base ||
					p.Threshold == nil || *p.Threshold != want.threshold {
					t.Fatalf("window %s progress = %+v, want base %v and threshold %v", want.name, p, want.base, want.threshold)
				}
			}
			report := app.ReportSignalEventJSONBody{Id: uuid.New(), StartsAt: target, Kind: emotion.Rhythm}
			f.call("POST", "signal-events", user.AccessToken, report, tc.wantReport, nil)
			var persisted bool
			f.must(f.s.db.QueryRow(f.ctx, `select exists(select from signal_events where id=$1 and user_id=$2 and occurred_at=$3)`,
				report.Id, user.UserId, target).Scan(&persisted))
			if persisted != (tc.wantReport == 200) {
				t.Fatalf("event persisted = %t, want report status %d", persisted, tc.wantReport)
			}
			if persisted {
				report.Id = uuid.New()
				f.call("POST", "signal-events", user.AccessToken, report, 409, nil)
				f.call("GET", windowQuery(target), user.AccessToken, nil, 200, nil)
			}
			if tc.name == "same_slot_after_commit" {
				motionAt := target.Add(11 * time.Minute)
				health := synthetic(motionAt, "health", false)
				exercise := true
				health.Exercise = &exercise
				f.call("POST", "signal-windows", user.AccessToken, health, 200, nil)
				f.call("POST", "signal-windows", user.AccessToken, voice(motionAt, 6, -20), 200, nil)
				f.call("GET", windowQuery(motionAt), user.AccessToken, nil, 200, &scoped)
				if !scoped.Speech.Ready || !scoped.Volume.Ready {
					t.Fatalf("movement changed readiness of historical baselines: %+v", scoped)
				}
				report.Id, report.StartsAt = uuid.New(), motionAt
				f.call("POST", "signal-events", user.AccessToken, report, 400, nil)

				t.Run("feedback_units_and_cutoff", func(t *testing.T) {
					f := signalsFor(t, fixture.s, fixture.ctx)
					// Seed confirmed records as stored by T30, including one from before
					// events carried a unit. Current GET includes confirmation at target.
					for _, row := range []struct {
						at, confirmed time.Time
						unit          string
						triggers      []string
					}{
						{target.Add(-3 * time.Hour), target.Add(-time.Hour), "", []string{"speech_rate", "volume"}},
						{target.Add(-2 * time.Hour), target.Add(-time.Minute), emotion.SpeechRateUnitCharactersPerSecond, []string{"speech_rate"}},
						{target.Add(-time.Hour), target, emotion.SpeechRateUnitCharactersPerSecond, []string{"speech_rate"}},
					} {
						id := uuid.New()
						payload := map[string]any{
							"id": id, "starts_at": row.at, "kind": emotion.Self, "confirmation": "no",
							"triggers": row.triggers, "confirmed_at": row.confirmed,
						}
						if row.unit != "" {
							payload["speech_rate_unit"] = row.unit
						}
						raw, err := json.Marshal(payload)
						f.must(err)
						enc, err := f.s.Emotion.Fields.Seal(raw, []byte("event/"+user.UserId.String()+"/"+id.String()))
						f.must(err)
						f.exec(`insert into signal_events(id,user_id,occurred_at,event_enc) values($1,$2,$3,$4)`, id, user.UserId, row.at, enc)
					}
					checkThreshold := func(name string, p emotion.Progress, want float64) {
						t.Helper()
						if p.Threshold == nil || math.Abs(*p.Threshold-want) > 1e-10 {
							t.Fatalf("%s threshold = %+v, want %v", name, p, want)
						}
					}
					var b emotion.Baselines
					f.call("GET", windowQuery(target), user.AccessToken, nil, 200, &b)
					checkThreshold("as of window speech", b.Speech, 5.25)
					checkThreshold("as of window volume", b.Volume, -29.7)
					f.call("GET", "signal-baselines", user.AccessToken, nil, 200, &b)
					// Only the committed target contributes one extra sample at 5 chars/s.
					checkThreshold("current speech", b.Speech, (4+1.0/421)*1.25*1.05*1.05)
					checkThreshold("current volume", b.Volume, tc.wantCurrentVolume+0.3)
				})
			}
		})
	}

	t.Run("short_membership_retention_boundary", func(t *testing.T) {
		f := signalsFor(t, fixture.s, fixture.ctx)
		owner := newUser(f)
		f.exec(`update entitlements set starts_at=$2 where user_id=$1`, owner.UserId, now.Add(-30*24*time.Hour))
		boundary := now.Truncate(30 * time.Second).Add(-180 * 24 * time.Hour)
		beforeMembership := now.Truncate(30 * time.Second).Add(-31 * 24 * time.Hour)
		for _, tc := range []struct {
			name   string
			at     time.Time
			token  string
			status int
			code   string
		}{
			{"outside_retention_before_membership", boundary, owner.AccessToken, 400, "invalid_argument"},
			{"inside_retention_before_membership", beforeMembership, owner.AccessToken, 403, "forbidden"},
			{"outside_retention_anonymous", boundary, "", 401, "unauthenticated"},
		} {
			t.Run(tc.name, func(t *testing.T) {
				f := signalsFor(t, fixture.s, fixture.ctx)
				var problem app.Error
				f.call("GET", windowQuery(tc.at), tc.token, nil, tc.status, &problem)
				if problem.Code != tc.code {
					t.Fatalf("error code = %q, want %q", problem.Code, tc.code)
				}
			})
		}
		f.exec(`update entitlements set ends_at=now() where user_id=$1`, owner.UserId)
		f.call("GET", windowQuery(boundary), owner.AccessToken, nil, 403, nil)
		f.call("GET", windowQuery(target.Add(time.Second)), owner.AccessToken, nil, 403, nil)
	})

	t.Run("query_validation_and_access", func(t *testing.T) {
		f := signalsFor(t, fixture.s, fixture.ctx)
		owner, other := newUser(f), newUser(f)
		f.call("POST", "signal-windows", owner.AccessToken, synthetic(target, "health", false), 200, nil)
		f.call("GET", windowQuery(target), owner.AccessToken, nil, 404, nil)
		f.call("POST", "signal-windows", owner.AccessToken, voice(target, 5, -30), 200, nil)
		f.call("GET", windowQuery(target), "", nil, 401, nil)
		f.call("GET", windowQuery(target), other.AccessToken, nil, 404, nil)
		f.call("GET", windowQuery(target.In(time.FixedZone("", 8*3600))), owner.AccessToken, nil, 200, nil)
		for _, value := range []string{
			"", "not-an-instant", target.Format("2006-01-02T15:04:05"), target.Format(time.DateOnly) + "T8:00:30Z",
			target.Format(time.DateOnly) + "T08:00:30+08:60", target.Format(time.DateOnly) + "T08:00:30,0Z",
			target.Format(time.DateOnly) + "T08:00:30.0000000001Z", target.Add(time.Second).Format(time.RFC3339),
			now.Truncate(30 * time.Second).Add(time.Minute).Format(time.RFC3339),
			now.Truncate(30 * time.Second).Add(-180 * 24 * time.Hour).Format(time.RFC3339),
		} {
			t.Run(fmt.Sprintf("invalid=%q", value), func(t *testing.T) {
				f := signalsFor(t, fixture.s, fixture.ctx)
				f.call("GET", "signal-baselines?for_window="+url.QueryEscape(value), owner.AccessToken, nil, 400, nil)
			})
		}
		f.call("GET", "signal-baselines?for_window=%ZZ", owner.AccessToken, nil, 400, nil)
		f.call("GET", windowQuery(target)+"&for_window="+url.QueryEscape(target.Format(time.RFC3339)), owner.AccessToken, nil, 400, nil)
		f.exec(`update consents set withdrawn_at=now() where user_id=$1 and purpose='voice'`, owner.UserId)
		f.call("GET", windowQuery(target), owner.AccessToken, nil, 403, nil)
		f.call("GET", "signal-baselines", owner.AccessToken, nil, 200, nil)
		f.exec(`insert into consents(user_id,purpose,version) values($1,'voice','v2')`, owner.UserId)
		f.call("GET", windowQuery(target), owner.AccessToken, nil, 403, nil)
		f.exec(`update consents set granted_at=$2 where user_id=$1 and purpose='voice' and withdrawn_at is null`, owner.UserId, target)
		f.call("POST", "signal-windows", other.AccessToken, voice(target, 5, -30), 200, nil)
		f.call("DELETE", "signal-windows?channel=voice&starts_at="+url.QueryEscape(target.Format(time.RFC3339)), owner.AccessToken, nil, 200, nil)
		f.call("GET", windowQuery(target), owner.AccessToken, nil, 404, nil)
		f.call("GET", windowQuery(target), other.AccessToken, nil, 200, nil)
		f.call("POST", "signal-windows", owner.AccessToken, voice(target, 5, -30), 409, nil)
		f.exec(`update entitlements set starts_at=$2 where user_id=$1`, owner.UserId, target.Add(time.Second))
		f.call("GET", windowQuery(target), owner.AccessToken, nil, 403, nil)
		f.exec(`update entitlements set ends_at=now() where user_id=$1`, owner.UserId)
		f.call("GET", windowQuery(target), owner.AccessToken, nil, 403, nil)
	})
}
