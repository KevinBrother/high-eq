//go:build integration

package events

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"

	"high-eq/server/internal/privacy"
)

// A failed second subscriber must roll back the first subscriber's SQL write.
func TestPublishAfterCommit(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	db, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	o, e := redis.ParseURL(os.Getenv("LEDGER_URL"))
	if e != nil {
		t.Fatal(e)
	}
	r := redis.NewClient(o)
	defer r.Close()
	l, e := privacy.BindLedger(ctx, db, r, 45)
	if e != nil {
		t.Fatal(e)
	}
	reg, e := privacy.NewRegistry(nil)
	if e != nil {
		t.Fatal(e)
	}
	bus := New(privacy.NewCoordinator(db, l, reg), nil)
	var user, id uuid.UUID
	if e = db.QueryRow(ctx, `insert into users(age_confirmed_at) values(now()) returning id`).Scan(&user); e != nil {
		t.Fatal(e)
	}
	if e = db.QueryRow(ctx, `insert into assessments(user_id,instrument_version,answers_enc,scores_enc) values($1,'test','a','s') returning id`, user).Scan(&id); e != nil {
		t.Fatal(e)
	}
	bus.AssessmentCompleted.Subscribe(func(ctx context.Context, tx pgx.Tx, v Assessment) error {
		_, e := tx.Exec(ctx, `insert into daily_plans(user_id,plan_day,plan_enc) values($1,current_date,'p') on conflict do nothing`, v.UserID)
		return e
	})
	fail := true
	injected := errors.New("subscriber unavailable")
	bus.AssessmentCompleted.Subscribe(func(context.Context, pgx.Tx, Assessment) error {
		if fail {
			return injected
		}
		return nil
	})
	v := Assessment{UserID: user, AssessmentID: id, OccurredAt: time.Now()}
	if e := bus.PublishAssessment(ctx, v); !errors.Is(e, injected) {
		t.Fatal(e)
	}
	count := func(want int) {
		t.Helper()
		var n int
		if e := db.QueryRow(ctx, `select count(*) from daily_plans where user_id=$1`, user).Scan(&n); e != nil || n != want {
			t.Fatalf("count %d want %d: %v", n, want, e)
		}
	}
	count(0)
	fail = false
	if e := bus.PublishAssessment(ctx, v); e != nil {
		t.Fatal(e)
	}
	count(1)
}

func TestScoreAndFeedbackBoundaries(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	db, e := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	if e != nil {
		t.Fatal(e)
	}
	defer db.Close()
	o, e := redis.ParseURL(os.Getenv("LEDGER_URL"))
	if e != nil {
		t.Fatal(e)
	}
	r := redis.NewClient(o)
	defer r.Close()
	l, e := privacy.BindLedger(ctx, db, r, 45)
	if e != nil {
		t.Fatal(e)
	}
	reg, e := privacy.NewRegistry(nil)
	if e != nil {
		t.Fatal(e)
	}
	bus := New(privacy.NewCoordinator(db, l, reg), func(src privacy.ScoreSource) (ScoreValues, error) {
		var val ScoreValues
		if string(src.Detail) != "canonical" {
			return val, errors.New("not from DB")
		}
		val.NVC.Total = 60
		return val, nil
	})
	var v Score
	var contact, other uuid.UUID
	mustQuery := func(query string, args []any, out ...any) {
		t.Helper()
		if e = db.QueryRow(ctx, query, args...).Scan(out...); e != nil {
			t.Fatal(e)
		}
	}
	mustQuery(`insert into users(age_confirmed_at) values(now()) returning id`, nil, &v.UserID)
	for _, ptr := range []*uuid.UUID{&contact, &other} {
		mustQuery(`insert into contacts(user_id,profile_enc) values($1,'profile') returning id`, []any{v.UserID}, ptr)
	}
	v.Kind = "review"
	mustQuery(`insert into activities(user_id,kind,state,contact_id) values($1,'review','complete',$2) returning id,source_id`, []any{v.UserID, contact}, &v.ActivityID, &v.SourceID)
	mustQuery(`insert into scores values($1,$2,'review','canonical',now()) returning occurred_at`, []any{v.SourceID, v.ActivityID}, &v.OccurredAt)
	v.NVC.Total = 999
	seen := false
	bus.ScoreCompleted.Subscribe(func(_ context.Context, _ pgx.Tx, s Score) error {
		seen = true
		if s.NVC.Total != 60 {
			return errors.New("trusted replay")
		}
		return nil
	})
	if e = bus.PublishScore(ctx, v); e != nil || !seen {
		t.Fatal(e)
	}
	feedback := Feedback{FeedbackID: uuid.New(), UserID: v.UserID, SourceID: v.SourceID, SourceKind: "review", Subject: "contact", ContactID: &other, OccurredAt: time.Now()}
	called := false
	bus.ProfileFeedback.Subscribe(func(context.Context, pgx.Tx, Feedback) error { called = true; return nil })
	if e = bus.PublishFeedback(ctx, feedback); e == nil || called {
		t.Fatal("misattributed feedback")
	}
	feedback.ContactID = &contact
	if e = bus.PublishFeedback(ctx, feedback); e != nil || !called {
		t.Fatal(e)
	}
}
