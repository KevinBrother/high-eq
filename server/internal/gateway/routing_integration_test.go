//go:build integration

package gateway

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"high-eq/server/internal/privacy"
)

// One rolled-back PG transaction, no vendor, customer data or live tariffs.
func TestRoutingStore(t *testing.T) {
	ctx := context.Background()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	db, err := pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
	must(err)
	defer db.Close()
	tx, err := db.Begin(ctx)
	must(err)
	defer tx.Rollback(ctx)
	exec := func(sql string, args ...any) { t.Helper(); _, err := tx.Exec(ctx, sql, args...); must(err) }
	mk := func(kind string) uuid.UUID {
		id := uuid.New()
		ref := id.String()
		exec(`insert into provider_admissions values($1,'fixture','https://test.invalid','*',$2,'fixture',ARRAY['model','messages.role','messages.content','stream','response_format.type'],'CN','CN',false,0,'auto','synthetic')`, ref, kind)
		exec(`insert into model_configs(id,name,provider,endpoint,api_key_enc,admission_ref,model_name,kind,enabled,input_cny_per_million,output_cny_per_million) values($1,'fixture','fixture','https://test.invalid',decode(repeat('11',48),'hex'),$2,'fixture',$3,true,2,5)`, id, ref, kind)
		return id
	}
	primary, backup, canary, mod := mk("model"), mk("model"), mk("model"), mk("moderation")
	c := Call{Task: Scoring, Scope: Scope{User: uuid.New(), Activity: uuid.New(), PromptVersion: uuid.New(), Operation: uuid.New()}}
	score := uuid.New()
	exec(`insert into users(id,age_confirmed_at)values($1,now())`, c.User)
	exec(`insert into activities(id,user_id,kind,source_id)values($1,$2,'practice',$3)`, c.Activity, c.User, score)
	exec(`insert into prompt_versions(id,task,version,template) values($1,$2,2147483647,'fixture')`, c.PromptVersion, c.Task)
	store := routingStore{func(_ context.Context, user uuid.UUID, f func(pgx.Tx) error) error {
		if user != c.User {
			t.Fatal("missing account guard")
		}
		return f(tx)
	}}
	for _, task := range []Task{RolePlay, ReplySuggestion, Scoring, ProfileInference, ReviewAnalysis, ContentGeneration, Classification} {
		exec(`insert into model_routes(task,primary_model,fallback_model,canary_model,canary_percent,moderation_model)values($1,$2,$3,$4,100,$5)`, task, primary, backup, canary, mod)
		probe := c
		probe.Task = task
		probe.PromptVersion = uuid.Nil
		p, err := store.load(ctx, probe)
		must(err)
		if p.primary.id != canary || p.backup.id != backup || p.moderator.id != mod || p.rev == uuid.Nil {
			t.Fatal("incorrect route")
		}
	}
	exec(`update model_routes set canary_percent=0 where task=$1`, c.Task)
	exec(`update provider_admissions set max_retention_days=1 where ref=$1`, backup.String())
	p, err := store.load(ctx, c)
	must(err)
	if p.primary.id != primary || p.backup.id != uuid.Nil {
		t.Fatal("weaker backup accepted")
	}
	exec(`update provider_admissions set max_retention_days=0 where ref=$1`, backup.String())
	p, err = store.load(ctx, c)
	must(err)
	if p.backup.id != backup {
		t.Fatal("eligible backup missing")
	}
	// Imported chat has a stricter <=24h retention boundary than other tasks.
	profileCall := c
	profileCall.Task = ProfileInference
	profileCall.PromptVersion = uuid.Nil
	exec(`update model_routes set canary_percent=0 where task=$1`, ProfileInference)
	exec(`update provider_admissions set max_retention_days=2 where ref=$1`, backup.String())
	p, err = store.load(ctx, profileCall)
	must(err)
	if p.primary.id != primary || p.backup.id != uuid.Nil {
		t.Fatal("profile inference accepted a >24h backup")
	}
	exec(`update provider_admissions set max_retention_days=1 where ref=$1`, backup.String())
	p, err = store.load(ctx, profileCall)
	must(err)
	if p.backup.id != uuid.Nil {
		t.Fatal("one-day fallback is weaker than a zero-day primary")
	}
	exec(`update provider_admissions set max_retention_days=1 where ref=$1`, primary.String())
	p, err = store.load(ctx, profileCall)
	must(err)
	if p.backup.id != backup {
		t.Fatal("profile inference rejected a 24h backup with an equally strict primary")
	}
	exec(`update provider_admissions set max_retention_days=2 where ref=$1`, primary.String())
	if _, err = store.load(ctx, profileCall); !errors.Is(err, ErrConfig) {
		t.Fatalf("profile inference accepted a >24h primary: %v", err)
	}
	exec(`update provider_admissions set max_retention_days=0 where ref=$1`, primary.String())
	exec(`update provider_admissions set max_retention_days=2 where ref=$1`, mod.String())
	p, err = store.load(ctx, profileCall)
	must(err)
	if p.moderator.id != uuid.Nil {
		t.Fatal("profile inference accepted a >24h moderator")
	}
	exec(`update provider_admissions set max_retention_days=0 where ref=$1`, mod.String())
	// Restore the original scoring route before exercising accounting below.
	exec(`update provider_admissions set max_retention_days=0 where ref=$1`, backup.String())
	p, err = store.load(ctx, c)
	must(err)
	now := time.Now()
	id := uuid.New()
	must(store.record(ctx, c, attemptStat{uuid.New(), p.primary, now, 30 * time.Millisecond, Result{}, "failed"}))
	must(store.record(ctx, c, attemptStat{id, p.backup, now, 20 * time.Millisecond, Result{UsageKnown: true, InputTokens: 4, OutputTokens: 2}, "ok"}))
	exec(`insert into scores(id,activity_id,activity_kind,detail_enc) values($1,$2,'practice','private-fixture-reason')`, score, c.Activity)
	must(LinkScoreTx(ctx, tx, c.User, id, c.Activity, score))
	var groups []Metric
	f := Filter{From: now.Add(-time.Second), Until: now.Add(time.Second), Task: c.Task, PromptVersion: c.PromptVersion}
	metrics := func() {
		groups = nil
		must(readMetrics(ctx, tx, f, func(m Metric) error { groups = append(groups, m); return nil }))
	}
	metrics()
	if len(groups) != 2 {
		t.Fatal(groups)
	}
	f.Model = backup
	metrics()
	if len(groups) != 1 || groups[0].KnownCostCNY != "0.00001800" || groups[0].Calls != 1 || groups[0].InputTokens != 4 || groups[0].Failures != 0 || *groups[0].PromptVersion != c.PromptVersion {
		t.Fatal(groups)
	}
	f.Model = primary
	metrics()
	if len(groups) != 1 || groups[0].Unpriced != 1 || groups[0].Failures != 1 || groups[0].FailureRate != 1 {
		t.Fatal(groups)
	}
	exported := 0
	var operationGroup uuid.UUID
	must(Hooks([]byte("synthetic export key")).Export(ctx, tx, privacy.ExportRequest{UserID: c.User}, func(v any) error {
		b, err := json.Marshal(v)
		if strings.Contains(string(b), "fixture") || strings.Contains(string(b), c.Operation.String()) {
			t.Fatal("private content exported")
		}
		group, ok := v.(map[string]any)["operation_id"].(uuid.UUID)
		if !ok || group.Version() != 8 || (exported > 0 && group != operationGroup) {
			t.Fatalf("inconsistent group for stored primary and fallback attempts: %v", group)
		}
		operationGroup = group
		exported++
		return err
	}))
	if exported != 2 {
		t.Fatal(exported)
	}
	exec(`delete from activities where id=$1`, c.Activity)
	f.Model = uuid.Nil
	metrics()
	if len(groups) != 0 {
		t.Fatal("source erasure left traces")
	}
}
