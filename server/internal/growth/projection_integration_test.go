//go:build integration

package growth

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/assessment"
	"high-eq/server/internal/events"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/reviews"
	"high-eq/server/internal/scoring"
	"high-eq/server/internal/training"
)

type projectionFixture struct {
	t     *testing.T
	ctx   context.Context
	db    *pgxpool.Pool
	coord *privacy.Coordinator
	svc   *Service
	bus   *events.Bus
}

func setupProjection(t *testing.T) *projectionFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	t.Cleanup(cancel)
	db, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	o, err := redis.ParseURL(os.Getenv("LEDGER_URL"))
	if err != nil {
		t.Fatal(err)
	}
	r := redis.NewClient(o)
	t.Cleanup(func() { _ = r.Close() })
	ledger, err := privacy.BindLedger(ctx, db, r, 45)
	if err != nil {
		t.Fatal(err)
	}
	fields := testCipher(t)
	registry, err := privacy.NewRegistry([]string{"growth"}, Hooks(fields))
	if err != nil {
		t.Fatal(err)
	}
	svc := &Service{Fields: fields}
	bus := events.New(privacy.NewCoordinator(db, ledger, registry), training.Decoder(fields, reviews.Decoder(fields)))
	bus.ScoreCompleted.Subscribe(svc.Consume)
	return &projectionFixture{t: t, ctx: ctx, db: db, coord: privacy.NewCoordinator(db, ledger, registry), svc: svc, bus: bus}
}

func (f *projectionFixture) user() uuid.UUID {
	f.t.Helper()
	var id uuid.UUID
	if err := f.db.QueryRow(f.ctx, `insert into users(age_confirmed_at) values(now()) returning id`).Scan(&id); err != nil {
		f.t.Fatal(err)
	}
	return id
}

func (f *projectionFixture) score(user uuid.UUID, kind, state string, at time.Time, full scoring.Full) events.Score {
	f.t.Helper()
	v := events.Score{ScoreKey: privacy.ScoreKey{UserID: user, Kind: kind}}
	if err := f.db.QueryRow(f.ctx, `insert into activities(user_id,kind,state) values($1,$2,$3) returning id,source_id`, user, kind, state).Scan(&v.ActivityID, &v.SourceID); err != nil {
		f.t.Fatal(err)
	}
	detail := []byte("unused-source-detail")
	if kind == "practice" || kind == "review" {
		detail = sealSource(f.t, f.svc.Fields, user, v.SourceID, kind, full)
	}
	if err := f.db.QueryRow(f.ctx, `insert into scores(id,activity_id,activity_kind,detail_enc,occurred_at) values($1,$2,$3,$4,$5) returning occurred_at`, v.SourceID, v.ActivityID, kind, detail, at).Scan(&v.OccurredAt); err != nil {
		f.t.Fatal(err)
	}
	return v
}

func (f *projectionFixture) assessment(user uuid.UUID, at time.Time, percent float64) uuid.UUID {
	f.t.Helper()
	id, version := uuid.New(), "wleis-fixture"
	scores := assessment.Scores{Total: assessment.Dimension{Percent: percent}}
	raw, err := json.Marshal(scores)
	if err != nil {
		f.t.Fatal(err)
	}
	aad := []byte("assessments:scores_enc:" + user.String() + ":" + id.String() + ":" + version)
	sealed, err := f.svc.Fields.Seal(raw, aad)
	if err != nil {
		f.t.Fatal(err)
	}
	if _, err = f.db.Exec(f.ctx, `insert into assessments(id,user_id,instrument_version,answers_enc,scores_enc,completed_at) values($1,$2,$3,'answers',$4,$5)`, id, user, version, sealed, at); err != nil {
		f.t.Fatal(err)
	}
	return id
}

func (f *projectionFixture) count(source uuid.UUID) int {
	f.t.Helper()
	var n int
	if err := f.db.QueryRow(f.ctx, `select count(*) from growth_scores where score_id=$1`, source).Scan(&n); err != nil {
		f.t.Fatal(err)
	}
	return n
}

func (f *projectionFixture) reference(user uuid.UUID, now time.Time) Reference {
	f.t.Helper()
	var ref Reference
	err := pgx.BeginFunc(f.ctx, f.db, func(tx pgx.Tx) error {
		var err error
		ref, err = f.svc.Reference(f.ctx, tx, user, now)
		return err
	})
	if err != nil {
		f.t.Fatal(err)
	}
	return ref
}

func values() events.ScoreValues {
	var v events.ScoreValues
	v.NVC.Observation = 25
	v.NVC.Feeling = 25
	v.NVC.Need = 10
	v.NVC.Request = 0
	v.NVC.Total = 60
	v.Emotion.ReadOthers = 4
	v.Emotion.SelfManagement = 5
	v.Emotion.Relationship = 3
	return v
}

func TestCompletedScoreProjectionIsCanonicalAndIdempotent(t *testing.T) {
	f := setupProjection(t)
	user, other := f.user(), f.user()
	now := time.Now().UTC()
	practice := f.score(user, "practice", "complete", now.Add(-time.Hour), fullScore(values()))
	practice.NVC.Total = 999 // replay payload must never be trusted
	practice.Emotion.Relationship = 1
	if err := f.bus.PublishScore(f.ctx, practice); err != nil {
		t.Fatal(err)
	}
	if got := f.count(practice.SourceID); got != 1 {
		t.Fatalf("practice rows=%d", got)
	}
	var nvc, emotion []byte
	if err := f.db.QueryRow(f.ctx, `select nvc_enc,emotion_enc from growth_scores where score_id=$1`, practice.SourceID).Scan(&nvc, &emotion); err != nil {
		t.Fatal(err)
	}
	raw, err := f.svc.Fields.Open(nvc, []byte("growth_scores.nvc_enc/"+practice.SourceID.String()))
	if err != nil {
		t.Fatal(err)
	}
	var gotNVC NVCValues
	if err = json.Unmarshal(raw, &gotNVC); err != nil || gotNVC.Total != 60 {
		t.Fatalf("nvc=%+v err=%v", gotNVC, err)
	}
	raw, err = f.svc.Fields.Open(emotion, []byte("growth_scores.emotion_enc/"+practice.SourceID.String()))
	if err != nil {
		t.Fatal(err)
	}
	var gotEmotion EmotionValues
	if err = json.Unmarshal(raw, &gotEmotion); err != nil || gotEmotion.Relationship != 3 {
		t.Fatalf("emotion=%+v err=%v", gotEmotion, err)
	}
	if err = f.bus.PublishScore(f.ctx, practice); err != nil {
		t.Fatal(err)
	}
	if got := f.count(practice.SourceID); got != 1 {
		t.Fatalf("duplicate rows=%d", got)
	}

	review := f.score(user, "review", "complete", now.Add(-2*time.Hour), fullScore(values()))
	if err = f.bus.PublishScore(f.ctx, review); err != nil {
		t.Fatal(err)
	}
	if got := f.count(review.SourceID); got != 1 {
		t.Fatalf("review rows=%d", got)
	}

	bad := []events.Score{}
	wrongUser := practice
	wrongUser.UserID = other
	bad = append(bad, wrongUser)
	wrongActivity := practice
	wrongActivity.ActivityID = uuid.New()
	bad = append(bad, wrongActivity)
	wrongSource := practice
	wrongSource.SourceID = uuid.New()
	bad = append(bad, wrongSource)
	incomplete := f.score(user, "practice", "active", now.Add(-time.Hour), fullScore(values()))
	bad = append(bad, incomplete)
	future := f.score(user, "practice", "complete", now.Add(time.Hour), fullScore(values()))
	bad = append(bad, future)
	old := f.score(user, "practice", "complete", now.Add(-721*time.Hour), fullScore(values()))
	bad = append(bad, old)
	drill := f.score(user, "drill", "complete", now.Add(-time.Hour), fullScore(values()))
	bad = append(bad, drill)
	for i, v := range bad {
		before := f.count(v.SourceID)
		if err = f.bus.PublishScore(f.ctx, v); err == nil {
			t.Fatalf("invalid event %d accepted", i)
		}
		if got := f.count(v.SourceID); got != before {
			t.Fatalf("invalid event %d changed rows from %d to %d", i, before, got)
		}
	}
}

func TestReferenceRecalculatesAndDeletionCannotBeReplayed(t *testing.T) {
	f := setupProjection(t)
	user, other := f.user(), f.user()
	now := time.Now().UTC().Truncate(time.Microsecond)
	f.assessment(user, now.Add(-24*time.Hour), 80)
	lowValues := events.ScoreValues{}
	lowValues.Emotion.ReadOthers = 1
	lowValues.Emotion.SelfManagement = 1
	lowValues.Emotion.Relationship = 1
	highValues := events.ScoreValues{}
	highValues.NVC.Observation = 25
	highValues.NVC.Feeling = 25
	highValues.NVC.Need = 25
	highValues.NVC.Request = 25
	highValues.NVC.Total = 100
	highValues.Emotion.ReadOthers = 5
	highValues.Emotion.SelfManagement = 5
	highValues.Emotion.Relationship = 5
	low := f.score(user, "practice", "complete", now.Add(-2*time.Hour), fullScore(lowValues))
	high := f.score(user, "review", "complete", now.Add(-time.Hour), fullScore(highValues))
	foreign := f.score(other, "practice", "complete", now.Add(-time.Hour), fullScore(highValues))
	for _, v := range []events.Score{low, high, foreign} {
		if err := f.bus.PublishScore(f.ctx, v); err != nil {
			t.Fatal(err)
		}
	}
	ref := f.reference(user, now)
	if ref.ValidBehaviorCount != 2 || ref.WLEISPercent == nil || *ref.WLEISPercent != 80 || ref.TrainingReference == nil || *ref.TrainingReference != 65 {
		t.Fatalf("initial reference=%+v", ref)
	}

	if err := f.coord.Delete(f.ctx, privacy.Deletion{OperationID: uuid.New(), UserID: user, Scope: "reviews", SourceID: high.SourceID}); err != nil {
		t.Fatal(err)
	}
	ref = f.reference(user, now)
	if ref.ValidBehaviorCount != 1 || ref.TrainingReference == nil || *ref.TrainingReference != 40 {
		t.Fatalf("after review deletion reference=%+v", ref)
	}
	if got := f.count(high.SourceID); got != 0 {
		t.Fatalf("deleted review projection rows=%d", got)
	}
	if err := f.bus.PublishScore(f.ctx, high); err == nil {
		t.Fatal("replayed deleted review")
	}
	if got := f.count(high.SourceID); got != 0 {
		t.Fatalf("replayed projection rows=%d", got)
	}

	if err := f.coord.Delete(f.ctx, privacy.Deletion{OperationID: uuid.New(), UserID: user, Scope: "sessions", SourceID: low.SourceID}); err != nil {
		t.Fatal(err)
	}
	ref = f.reference(user, now)
	if ref.ValidBehaviorCount != 0 || ref.TrainingReference != nil || ref.WLEISPercent == nil {
		t.Fatalf("after practice deletion reference=%+v", ref)
	}

	exported := f.export(user)
	if bytes.Contains(exported, []byte(high.SourceID.String())) || bytes.Contains(exported, []byte(low.SourceID.String())) {
		t.Fatalf("deleted source leaked: %s", exported)
	}
	if bytes.Contains(exported, []byte(foreign.SourceID.String())) {
		t.Fatalf("other account leaked: %s", exported)
	}
}

func TestAccountDeletionRemovesProjection(t *testing.T) {
	f := setupProjection(t)
	user := f.user()
	v := f.score(user, "practice", "complete", time.Now().UTC().Add(-time.Hour), fullScore(values()))
	if err := f.bus.PublishScore(f.ctx, v); err != nil {
		t.Fatal(err)
	}
	if got := f.count(v.SourceID); got != 1 {
		t.Fatalf("projection rows=%d", got)
	}
	if err := f.coord.Delete(f.ctx, privacy.Deletion{OperationID: uuid.New(), UserID: user, Scope: "account"}); err != nil {
		t.Fatal(err)
	}
	if got := f.count(v.SourceID); got != 0 {
		t.Fatalf("account projection rows=%d", got)
	}
	if err := f.bus.PublishScore(f.ctx, v); err == nil {
		t.Fatal("replayed closed account")
	}
	if got := f.count(v.SourceID); got != 0 {
		t.Fatalf("replayed account projection rows=%d", got)
	}
}

func (f *projectionFixture) export(user uuid.UUID) []byte {
	f.t.Helper()
	var b bytes.Buffer
	if err := f.coord.Export(f.ctx, privacy.ExportRequest{OperationID: uuid.New(), UserID: user}, &b); err != nil {
		f.t.Fatal(err)
	}
	z, err := zip.NewReader(bytes.NewReader(b.Bytes()), int64(b.Len()))
	if err != nil {
		f.t.Fatal(err)
	}
	part, err := z.Open("growth.json")
	if err != nil {
		f.t.Fatal(err)
	}
	defer part.Close()
	raw, err := io.ReadAll(part)
	if err != nil {
		f.t.Fatal(err)
	}
	if !json.Valid(raw) {
		f.t.Fatalf("invalid growth.json: %s", raw)
	}
	return raw
}

func TestExportContainsOnlyOwnedNumericProjection(t *testing.T) {
	f := setupProjection(t)
	user, other := f.user(), f.user()
	full := fullScore(values())
	full.NVC.Observation.Reason = "private source reason"
	own := f.score(user, "practice", "complete", time.Now().UTC().Add(-time.Hour), full)
	foreign := f.score(other, "practice", "complete", time.Now().UTC().Add(-time.Hour), fullScore(values()))
	for _, v := range []events.Score{own, foreign} {
		if err := f.bus.PublishScore(f.ctx, v); err != nil {
			t.Fatal(err)
		}
	}
	raw := f.export(user)
	if !bytes.Contains(raw, []byte(own.SourceID.String())) || !bytes.Contains(raw, []byte(`"total":60`)) {
		t.Fatalf("missing owned projection: %s", raw)
	}
	if bytes.Contains(raw, []byte(foreign.SourceID.String())) || bytes.Contains(raw, []byte("private source reason")) {
		t.Fatalf("export leaked unrelated or source detail: %s", raw)
	}
	if err := f.coord.Export(f.ctx, privacy.ExportRequest{OperationID: uuid.New()}, io.Discard); err == nil {
		t.Fatal("invalid export accepted")
	}
}
