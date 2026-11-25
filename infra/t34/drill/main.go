// Offline lab tool. Built only into the drill image; no listeners or gateway,
// but it registers the same synchronous consumers as the production runtime.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/assessment"
	"high-eq/server/internal/emotion"
	"high-eq/server/internal/events"
	"high-eq/server/internal/fieldcrypt"
	"high-eq/server/internal/gateway"
	"high-eq/server/internal/growth"
	"high-eq/server/internal/marks"
	"high-eq/server/internal/membership"
	"high-eq/server/internal/payments"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/profile"
	"high-eq/server/internal/replies"
	"high-eq/server/internal/reviews"
	"high-eq/server/internal/service"
	"high-eq/server/internal/training"
	"high-eq/server/migrations"
)

var ctx context.Context
var db *pgxpool.Pool
var cache *redis.Client
var data *privacy.Coordinator
var bus *events.Bus
var auth *accounts.Service
var signals emotion.Service
var fields *fieldcrypt.Cipher
var assessments *assessment.Service
var practice *training.Service
var plans *growth.PlanService

type fixture struct {
	A, B                app.Tokens
	Subject             string
	Activities, Sources [2]uuid.UUID
	Requests            [2]uuid.UUID
	Windows             [2]uuid.UUID
	AssessmentID        uuid.UUID
	DrillActivity       uuid.UUID
	DrillSource         uuid.UUID
	DrillLevel          uuid.UUID
	At                  time.Time
	Seal                string
	Expected            []string // roots from the source database and the fixture key
	AccountRoots        []string
	WindowCutoffs       map[string]int64
	ChatImports         *chatImportFixture `json:",omitempty"`
}

func must(e error) {
	if e != nil {
		fail(2)
	}
}
func require(v bool) {
	if !v {
		fail(2)
	}
}
func main() {
	// Never emit payloads, argv, environment values, SQL params, raw backend
	// errors or stacks. The recovery path prints only a fixed stage and source
	// basename:line captured by enter/fail.
	defer func() {
		if recovered := recover(); recovered != nil {
			fmt.Fprint(os.Stderr, safeFailureMessage(recovered, activeStage, activeSite))
			os.Exit(1)
		}
	}()
	enter(stageMainConfig)
	require(len(os.Args) == 2)
	op := os.Args[1]
	timeout := 90 * time.Second
	if op == "retention-process" {
		timeout = 2 * time.Minute
	}
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), timeout)
	defer cancel()
	c, e := service.LoadConfig()
	must(e)
	require(c.BackupDays == 45)
	enter(stageMainMigrate)
	if op == "seed" || op == "seed-d13" {
		must(migrations.Up(ctx, c.DatabaseURL))
	}
	enter(stageMainDatabase)
	db, e = pgxpool.New(ctx, c.DatabaseURL)
	must(e)
	defer db.Close()
	key, e := base64.StdEncoding.DecodeString(os.Getenv("FIELD_KEY_BASE64"))
	must(e)
	fields = c.Fields
	if op == "restore-plan" {
		enter(stageMainRestore)
		var f fixture
		must(json.NewDecoder(os.Stdin).Decode(&f))
		must(json.NewEncoder(os.Stdout).Encode(f.windowReplayPlan(key)))
		return
	}
	cache = redis.NewClient(c.Cache)
	defer cache.Close()
	if op == "restore" {
		// The driver populated a verified replay copy in DB 1. Resume can
		// remark roots there without changing the authoritative DB 0 deadlines.
		c.Ledger.DB = 1
	}
	r := redis.NewClient(c.Ledger)
	defer r.Close()
	enter(stageMainLedger)
	l, e := privacy.BindLedger(ctx, db, r, c.BackupDays)
	must(e)
	enter(stageMainMembership)
	rights, e := membership.New(cache)
	must(e)
	profiles := &profile.Service{Fields: c.Fields, Rights: rights}
	// Keep this manifest and hook order identical to service/runtime.go. The host
	// validates the runtime source before building this offline helper.
	enter(stageMainRegistry)
	registry, e := privacy.NewRegistry(
		[]string{"training", "chat_imports", "profiles", "assessments", "payments", "membership", "accounts", "replies", "ai_calls", "emotion", "manual_marks", "reviews", "growth"},
		payments.Hooks(), rights.Hooks(), assessment.Hooks(c.Fields), accounts.Hooks(c.Fields),
		training.Hooks(c.Fields), training.ChatImportHooks(), profiles.Hooks(), replies.Hooks(c.Fields), gateway.Hooks(key),
		emotion.Hooks(c.Fields), marks.Hooks(c.Fields), reviews.Hooks(c.Fields),
		growth.Hooks(c.Fields, &training.Service{Fields: c.Fields}),
	)
	must(e)
	data = privacy.NewCoordinator(db, l, registry, privacy.WithWindowReplayKey(key))
	enter(stageMainEvents)
	bus = events.New(data, training.Decoder(c.Fields, reviews.Decoder(c.Fields)))
	enter(stageMainProviders)
	sms, ex, e := accounts.DevelopmentProviders(c.Environment, cache)
	must(e)
	enter(stageMainAuth)
	auth, e = accounts.New(db, data, c.Fields, key, sms, ex)
	must(e)
	profiles.Data = data
	enter(stageMainAssessmentBank)
	bank, e := assessment.Load(c.InstrumentPath)
	must(e)
	assessments = assessment.New(bank, auth, c.Fields, bus, db)
	practice = &training.Service{
		Accounts: auth, Rights: rights, Fields: c.Fields,
		Data: data, DB: db, Bus: bus,
	}
	growthConsumer := &growth.Service{Fields: c.Fields}
	bus.ScoreCompleted.Subscribe(growthConsumer.Consume)
	enter(stageMainPlanService)
	plans, e = growth.NewPlanService(growth.PlanDependencies{
		Fields:     c.Fields,
		Results:    assessments,
		Levels:     trainingPlanLevels{},
		Activities: practice,
		Profiles:   profiles,
		Membership: rights,
	})
	must(e)
	bus.AssessmentCompleted.Subscribe(plans.ConsumeAssessment)
	bus.DrillProgressed.Subscribe(plans.ConsumeDrill)
	bus.ScoreCompleted.Subscribe(plans.ConsumeScore)
	signals = emotion.Service{Fields: c.Fields, DB: db, Data: data}
	var f fixture
	if op == "seed" || op == "seed-d13" {
		f.seed(key)
		if op == "seed-d13" {
			f.ChatImports = seedChatImports()
		}
		enter(stageMainSeedOutput)
		must(json.NewEncoder(os.Stdout).Encode(f))
		return
	}
	enter(stageMainInput)
	must(json.NewDecoder(os.Stdin).Decode(&f))
	switch op {
	case "preflight":
		enter(stageMainPreflight)
		f.counts(true)
		require(len(export(f.A.UserId)) > 0)
	case "delete":
		enter(stageMainDelete)
		receipt := f.delete(r)
		f.verify()
		must(json.NewEncoder(os.Stdout).Encode(receipt))
	case "restore":
		enter(stageMainRestore)
		must(json.NewEncoder(os.Stdout).Encode(f.restore(r, key)))
	case "httpcheck":
		enter(stageMainHTTPCheck)
		f.httpcheck(c)
	case "retention-process":
		enter(stageChatImportProcess)
		require(f.ChatImports != nil)
		f.ChatImports.checkProcess(f)
	default:
		enter(stageMainInvalidPhase)
		fail(1)
	}
}
func exec(q string, args ...any) {
	_, e := db.Exec(ctx, q, args...)
	if e != nil {
		fail(2)
	}
}
func (f fixture) erase(scope string, id uuid.UUID) {
	must(data.Delete(ctx, privacy.Deletion{UserID: f.A.UserId, SourceID: id, OperationID: uuid.New(), Scope: scope}))
}

type trainingPlanLevels struct{}

func (trainingPlanLevels) PlanLevels(
	_ context.Context, _ pgx.Tx, _ uuid.UUID,
	focus, scene string,
) (growth.LevelIDs, error) {
	single, full, err := training.PlanLevelIDs(focus, scene)
	return growth.LevelIDs{Single: single, Full: full}, err
}
