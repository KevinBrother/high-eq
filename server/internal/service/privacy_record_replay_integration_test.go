//go:build integration

package service

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
)

func TestDeletionReplayWindowWithinAndExpired(t *testing.T) {
	f := newDeletionHTTPFixture(t)
	for _, tc := range []struct {
		name    string
		closure bool
	}{{"review deletion", false}, {"account closure purge", true}} {
		t.Run(tc.name, func(t *testing.T) {
			subject := uuid.NewString()
			owner := f.register(t, subject)
			var purgeID uuid.UUID
			requireDeletionFixture(t, f.db.QueryRow(f.ctx, `select purge_id from users where id=$1`, owner.UserId).Scan(&purgeID))

			now := time.Now().UTC().Truncate(time.Microsecond)
			within := seedReplayReview(t, f, owner.UserId, now.Add(-29*24*time.Hour))
			expired := seedReplayReview(t, f, owner.UserId, now.Add(-31*24*time.Hour))
			publish := func(key privacy.ScoreKey) error {
				return f.Bus.PublishScore(f.ctx, events.Score{ScoreKey: key})
			}
			requireDeletionFixture(t, publish(within.ScoreKey))

			if !tc.closure {
				f.request(t, "PUT", "/v1/me/consents/assessment", owner.AccessToken, map[string]any{
					"version": "v1", "granted": true,
				}, 200)
				var instrument app.GetInstrumentResult
				requireDeletionFixture(t, json.Unmarshal(f.request(t, "GET", "/v1/assessments/instrument", owner.AccessToken, nil, 200), &instrument))
				f.request(t, "POST", "/v1/assessments", owner.AccessToken, app.SubmitAssessmentInput{
					Version: instrument.Version,
					Answers: []int{4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4},
				}, 200)
				assertReplayGrowth(t, f, owner.AccessToken, 1)
				before := t35Download(t, f.Router(), owner.AccessToken)
				if !bytes.Contains(t35Part(t, before, "reviews"), []byte(within.ActivityID.String())) {
					t.Fatal("review missing from export before deletion")
				}
				if !bytes.Contains(t35Part(t, before, "growth"), []byte(within.SourceID.String())) {
					t.Fatal("projection missing from export before deletion")
				}
				for _, sample := range []privacy.ScoreSource{within, expired} {
					path := "/v1/me/data/reviews/" + sample.ActivityID.String()
					f.request(t, "DELETE", path, owner.AccessToken, nil, 200)
					f.request(t, "DELETE", path, owner.AccessToken, nil, 404)
				}
			} else {
				f.request(t, "POST", "/v1/me/closure", owner.AccessToken, map[string]any{"proof": f.proof(t, subject)}, 200)
				f.exec(t, `update users set closure_requested_at=clock_timestamp()-interval '361 hours' where id=$1`, owner.UserId)
				requireDeletionFixture(t, f.Accounts.PurgeDue(f.ctx))
			}

			// The live database must stay erased across both original deliveries.
			for _, sample := range []privacy.ScoreSource{within, expired} {
				if err := publish(sample.ScoreKey); !errors.Is(err, pgx.ErrNoRows) {
					t.Fatalf("delivery for erased review = %v, want no canonical source", err)
				}
			}
			var active, reviewsExist, scoresExist, projectionsExist bool
			sources := []uuid.UUID{within.SourceID, expired.SourceID}
			requireDeletionFixture(t, f.db.QueryRow(f.ctx, `select exists(select from users where id=$1),
				exists(select from activities where source_id=any($2::uuid[])),
				exists(select from scores where id=any($2::uuid[])),
				exists(select from growth_scores where score_id=any($2::uuid[]))`, owner.UserId, sources).
				Scan(&active, &reviewsExist, &scoresExist, &projectionsExist))
			if active == tc.closure || reviewsExist || scoresExist || projectionsExist {
				t.Fatalf("unexpected rows after replay: user=%t reviews=%t scores=%t projections=%t", active, reviewsExist, scoresExist, projectionsExist)
			}
			if tc.closure {
				f.request(t, "GET", "/v1/me/export", owner.AccessToken, nil, 401)
				err := f.Data.Export(f.ctx, privacy.ExportRequest{UserID: owner.UserId, OperationID: uuid.New()}, io.Discard)
				if !errors.Is(err, pgx.ErrNoRows) {
					t.Fatalf("export for erased account = %v, want no account", err)
				}
			} else {
				assertReplayGrowth(t, f, owner.AccessToken, 0)
				after := t35Download(t, f.Router(), owner.AccessToken)
				t35Exclude(t, t35Part(t, after, "reviews"), within.ActivityID.String(), expired.ActivityID.String())
				t35Exclude(t, t35Part(t, after, "growth"), within.SourceID.String(), expired.SourceID.String())
			}

			// Restore synthetic canonical source rows without projections. The
			// independent ledger must still fence a fresh delivery, and age
			// must fence an expired delivery even once the ledger entries expire.
			t.Cleanup(func() { f.exec(t, `delete from users where id=$1`, owner.UserId) })
			requireDeletionFixture(t, pgx.BeginFunc(f.ctx, f.db, func(tx pgx.Tx) error {
				if tc.closure {
					if _, err := tx.Exec(f.ctx, `insert into users(id,purge_id,age_confirmed_at) values($1,$2,clock_timestamp())`, owner.UserId, purgeID); err != nil {
						return err
					}
				}
				for _, sample := range []privacy.ScoreSource{within, expired} {
					if err := insertReplayScore(f, tx, sample, nil); err != nil {
						return err
					}
				}
				return nil
			}))
			for range 2 {
				if err := publish(within.ScoreKey); !errors.Is(err, privacy.ErrHidden) {
					t.Fatalf("in-window replay against restored source = %v, want deletion barrier", err)
				}
			}
			tombstones := append([]uuid.UUID(nil), sources...)
			if tc.closure {
				tombstones = append(tombstones, purgeID)
			}
			for _, id := range tombstones {
				key := "deleted:" + id.String()
				value, err := f.registryRedis.Get(f.ctx, key).Result()
				requireDeletionFixture(t, err)
				ttl, err := f.registryRedis.PTTL(f.ctx, key).Result()
				requireDeletionFixture(t, err)
				if value != "" || ttl < f.minimumTombstoneRetention-time.Minute {
					t.Fatalf("expected an empty tombstone covering retention, got empty=%t TTL=%v", value == "", ttl)
				}
				changed, err := f.registryRedis.PExpireAt(f.ctx, key, time.Unix(1, 0)).Result()
				requireDeletionFixture(t, err)
				if !changed {
					t.Fatal("failed to simulate expiration of synthetic tombstone")
				}
			}
			for range 2 {
				if err := publish(expired.ScoreKey); !errors.Is(err, pgx.ErrNoRows) {
					t.Fatalf("expired replay against restored source = %v, want no eligible source", err)
				}
			}
			requireDeletionFixture(t, f.db.QueryRow(f.ctx, `select exists(select from growth_scores where score_id=any($1::uuid[]))`, sources).Scan(&projectionsExist))
			if projectionsExist {
				t.Fatal("replay restored a growth projection")
			}
		})
	}
}

func assertReplayGrowth(t *testing.T, f deletionHTTPFixture, token string, count int) {
	t.Helper()
	var got app.GetGrowthResult
	requireDeletionFixture(t, json.Unmarshal(f.request(t, "GET", "/v1/growth", token, nil, 200), &got))
	if got.ValidBehaviorCount != count || got.WleisPercent == nil {
		t.Fatalf("growth sources after replay = %+v, want %d behavior scores and an assessment", got, count)
	}
	if count == 0 {
		if got.TrainingReference != nil {
			t.Fatalf("reference retained deleted score: %v", *got.TrainingReference)
		}
		return
	}
	want := (float64(*got.WleisPercent) + 85) / 2
	if got.TrainingReference == nil || math.Abs(float64(*got.TrainingReference)-want) > 1e-6 {
		t.Fatalf("growth reference = %+v, want %v", got, want)
	}
}

func seedReplayReview(t *testing.T, f deletionHTTPFixture, user uuid.UUID, at time.Time) privacy.ScoreSource {
	t.Helper()
	sample := privacy.ScoreSource{ScoreKey: privacy.ScoreKey{
		UserID: user, ActivityID: uuid.New(), SourceID: uuid.New(), Kind: "review", OccurredAt: at,
	}}
	item, level := scoring.Item{Score: 25}, scoring.Level{Level: 3}
	full, err := json.Marshal(scoring.Full{
		Mode: "full", NVC: scoring.NVC{Observation: item, Feeling: item, Need: item, Request: item, Total: 100},
		Emotion: scoring.Emotion{ReadOthers: level, SelfManagement: level, Relationship: level},
	})
	requireDeletionFixture(t, err)
	aad := "review/v1/" + user.String() + "/"
	sample.Detail, err = f.Fields.Seal(full, []byte(aad+sample.SourceID.String()+"/score"))
	requireDeletionFixture(t, err)
	content, err := f.Fields.Seal([]byte(`{"submitted":{"happened":"synthetic review"},"repair_phrase":"synthetic repair"}`), []byte(aad+sample.ActivityID.String()+"/journal"))
	requireDeletionFixture(t, err)
	requireDeletionFixture(t, pgx.BeginFunc(f.ctx, f.db, func(tx pgx.Tx) error {
		if err := insertReplayScore(f, tx, sample, content); err != nil {
			return err
		}
		_, err := tx.Exec(f.ctx, `insert into review_requests(activity_id,user_id,request_id,input_mac) values($1,$2,$3,$4)`, sample.ActivityID, user, uuid.New(), make([]byte, 32))
		return err
	}))
	return sample
}

func insertReplayScore(f deletionHTTPFixture, tx pgx.Tx, sample privacy.ScoreSource, content []byte) error {
	if _, err := tx.Exec(f.ctx, `insert into activities(id,user_id,source_id,kind,state,content_enc)
		values($1,$2,$3,'review','complete',$4)`, sample.ActivityID, sample.UserID, sample.SourceID, content); err != nil {
		return err
	}
	_, err := tx.Exec(f.ctx, `insert into scores(id,activity_id,activity_kind,detail_enc,occurred_at)
		values($1,$2,'review',$3,$4)`, sample.SourceID, sample.ActivityID, sample.Detail, sample.OccurredAt)
	return err
}
