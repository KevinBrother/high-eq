package main

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"high-eq/server/internal/accounts"
	"high-eq/server/internal/api/app"
	"high-eq/server/internal/events"
	"high-eq/server/internal/privacy"
	"high-eq/server/internal/scoring"
	"high-eq/server/internal/service"
	"high-eq/server/internal/training"
	"io"
	"net/http"
	"net/http/httptest"
	"time"
)

func login(subj string, existing bool) (app.Tokens, error) {
	ticket := uuid.NewString()
	must(cache.Set(ctx, "dev:ticket:apple:"+ticket, subj, time.Minute).Err())
	t := app.LoginInputAgeConfirmed(true)
	v := accounts.PolicyVersion
	return auth.Login(ctx, app.LoginInput{Credential: app.Credential{Provider: "apple", Proof: ticket}, AgeConfirmed: &t, PrivacyVersion: &v, TermsVersion: &v}, existing)
}

func reviewAAD(user, source uuid.UUID, field string) []byte {
	return []byte("review/v1/" + user.String() + "/" + source.String() + "/" + field)
}

// Use the T23 journal envelope for a completed synthetic source: its real
// export hook must decode the owner's journal as well as the numeric score.
func journalDetail(user, activity, request uuid.UUID) []byte {
	v := struct {
		Submitted app.ReviewInput `json:"submitted"`
		Phrase    string          `json:"repair_phrase"`
	}{
		app.ReviewInput{RequestId: request, Happened: "synthetic review event", MyFeeling: "synthetic feeling", TheirPossibleFeeling: "synthetic guess", MyAction: "synthetic action", NextAction: "synthetic next action"}, "synthetic approved repair",
	}
	plain, err := json.Marshal(v)
	must(err)
	enc, err := fields.Seal(plain, reviewAAD(user, activity, "journal"))
	must(err)
	return enc
}

func scoreDetail(user, source uuid.UUID) []byte {
	full := scoring.Full{
		Mode: "express",
		NVC: scoring.NVC{
			Observation: scoring.Item{Score: 15, Reason: "synthetic"},
			Feeling:     scoring.Item{Score: 0, Reason: "synthetic"},
			Need:        scoring.Item{Score: 0, Reason: "synthetic"},
			Request:     scoring.Item{Score: 5, Reason: "synthetic"},
			Total:       20,
		},
		Emotion: scoring.Emotion{
			ReadOthers:     scoring.Level{Level: 2, Reason: "synthetic"},
			SelfManagement: scoring.Level{Level: 3, Reason: "synthetic"},
			Relationship:   scoring.Level{Level: 2, Reason: "synthetic"},
		},
		BetterVersion: "synthetic",
		WhyBetter:     "synthetic",
	}
	plain, e := json.Marshal(full)
	must(e)
	sealed, e := fields.Seal(plain, reviewAAD(user, source, "score"))
	must(e)
	return sealed
}

func drillProgressAAD(user, source uuid.UUID) []byte {
	return []byte("practice/progress/" + user.String() + "/" + source.String())
}

// A completed drill must carry the same encrypted progress projection that the
// production finish path writes; export decodes this envelope before emitting it.
func drillProgress(user, source uuid.UUID) []byte {
	progress := scoring.Progress{
		TargetItem: "observation",
		Item:       scoring.Item{Score: 15, Reason: "synthetic"},
		NextAction: "retry_in_three_days",
	}
	plain, e := json.Marshal(progress)
	must(e)
	sealed, e := fields.Seal(plain, drillProgressAAD(user, source))
	must(e)
	return sealed
}

func projectionCount(source uuid.UUID) int {
	var n int
	must(db.QueryRow(ctx, `select count(*) from growth_scores where score_id=$1`, source).Scan(&n))
	return n
}

func (f *fixture) seed(key []byte) {
	enter(stageSeedSubject)
	var e error
	f.Subject = uuid.NewString()
	enter(stageSeedLoginA)
	f.A, e = login(uuid.NewString(), false)
	must(e)
	enter(stageSeedLoginB)
	f.B, e = login(f.Subject, false)
	must(e)
	enter(stageSeedPrincipal)
	principal, e := auth.Parse(f.A.AccessToken)
	must(e)
	enter(stageSeedConsentAssess)
	_, e = auth.Consent(ctx, principal, "assessment", "t34", true)
	must(e)
	enter(stageSeedConsentPractice)
	_, e = auth.Consent(ctx, principal, "practice", "t34", true)
	must(e)
	enter(stageSeedReviewA)
	f.At = time.Now().UTC().Add(-time.Minute).Truncate(time.Microsecond)
	model := uuid.New()
	exec(`insert into model_configs(id,name,endpoint,api_key_enc) values($1,'synthetic','https://unused.invalid','x')`, model)
	reviewStages := []drillStage{stageSeedReviewA, stageSeedReviewB}
	for i, u := range []uuid.UUID{f.A.UserId, f.B.UserId} {
		enter(reviewStages[i])
		a, s := uuid.New(), uuid.New()
		f.Activities[i], f.Sources[i] = a, s
		f.Requests[i] = uuid.New()
		exec(`insert into activities(id,user_id,source_id,kind,state,content_enc) values($1,$2,$3,'review','complete',$4)`, a, u, s, journalDetail(u, a, f.Requests[i]))
		exec(`insert into scores(id,activity_id,activity_kind,detail_enc,occurred_at) values($1,$2,'review',$3,$4)`, s, a, scoreDetail(u, s), f.At)
		exec(`insert into review_requests(activity_id,user_id,request_id,input_mac,score_pending) values($1,$2,$3,$4,false)`, a, u, f.Requests[i], bytes.Repeat([]byte{0x34}, 32))
		must(bus.PublishScore(ctx, events.Score{ScoreKey: privacy.ScoreKey{UserID: u, ActivityID: a, SourceID: s, Kind: "review", OccurredAt: f.At}}))
		require(projectionCount(s) == 1)
		exec(`insert into ai_calls(user_id,activity_id,score_id,model_id,task,outcome,cost_cny) values($1,$2,$3,$4,'review_analysis','ok',1)`, u, a, s, model)
	}
	enter(stageSeedAssessmentSubmit)
	result, e := assessments.Submit(ctx, principal, assessments.Bank.Version, []int{4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4})
	must(e)
	f.AssessmentID = result.ID
	enter(stageSeedAssessmentState)
	var completionPending bool
	must(db.QueryRow(ctx, `select completion_pending from assessments where id=$1`, f.AssessmentID).Scan(&completionPending))
	require(!completionPending)
	enter(stageSeedAssessmentPlan)
	var plans int
	must(db.QueryRow(ctx, `select count(*) from daily_plans where assessment_id=$1`, f.AssessmentID).Scan(&plans))
	require(plans == 1)

	enter(stageSeedDrillLevel)
	single, _, e := training.PlanLevelIDs("observation", "work")
	must(e)
	f.DrillLevel = single
	enter(stageSeedDrillCreate)
	summary, e := practice.Create(ctx, principal, training.Input{ID: uuid.New(), Level: &single})
	must(e)
	f.DrillActivity = summary.ID
	must(db.QueryRow(ctx, `select source_id from activities where id=$1`, f.DrillActivity).Scan(&f.DrillSource))
	enter(stageSeedDrillComplete)
	exec(`insert into drill_progress(activity_id,target_item,progress_enc,retry_at) values($1,'observation',$2,$3)`, f.DrillActivity, drillProgress(f.A.UserId, f.DrillSource), f.At.Add(72*time.Hour))
	exec(`update activities set state='complete' where id=$1`, f.DrillActivity)
	exec(`update practice_work set completed_at=$2 where activity_id=$1`, f.DrillActivity, f.At)
	enter(stageSeedDrillEvent)
	must(bus.PublishDrill(ctx, events.Drill{UserID: f.A.UserId, ActivityID: f.DrillActivity, LevelID: f.DrillLevel, TargetItem: "observation", Score: 15, OccurredAt: f.At}))
	enter(stageSeedDrillSchedule)
	var schedules int
	must(db.QueryRow(ctx, `select count(*) from growth_drill_schedules where activity_id=$1`, f.DrillActivity).Scan(&schedules))
	require(schedules == 1)
	enter(stageSeedSignalConsent)
	exec(`insert into consents(user_id,purpose,version,granted_at) values($1,'health','t34',now()-interval '1 day')`, f.A.UserId)
	signalStages := []drillStage{stageSeedSignal1, stageSeedSignal2}
	for i := range f.Windows {
		enter(signalStages[i])
		at := f.At.Truncate(30 * time.Second).Add(-time.Duration(i) * time.Minute)
		w := fixtureWindow(at)
		must(data.Access(ctx, f.A.UserId, func(tx pgx.Tx) error { return signals.Upload(ctx, tx, f.A.UserId, w, time.Now()) }))
		must(db.QueryRow(ctx, `select purge_id from signal_windows where user_id=$1 and starts_at=$2`, f.A.UserId, at).Scan(&f.Windows[i]))
	}
	enter(stageSeedAccountKey)
	rows, e := db.Query(ctx, `select root_id::text from erasure_roots where user_id=$1 order by root_id`, f.B.UserId)
	must(e)
	f.AccountRoots, e = pgx.CollectRows(rows, pgx.RowTo[string])
	must(e)
	require(len(f.AccountRoots) > 0)
	enter(stageSeedLedgerBinding)
	must(db.QueryRow(ctx, `select ledger_id::text || ':45' from ledger_binding`).Scan(&f.Seal))
	enter(stageSeedExpected)
	f.captureDeletionRoots(key)
	enter(stageSeedCounts)
	f.counts(true)
	enter(stageSeedExportA)
	body := export(f.A.UserId)
	require(bytes.Contains(body, []byte("synthetic approved repair")) && bytes.Contains(body, []byte(f.Sources[0].String())) && bytes.Count(body, []byte(`"window":`)) == 2)
	require(bytes.Contains(body, []byte(`"record_type":"score"`)) && bytes.Contains(body, []byte(`"record_type":"plan"`)) && bytes.Contains(body, []byte(`"record_type":"drill"`)))
	enter(stageSeedExportB)
	require(bytes.Contains(export(f.B.UserId), []byte(f.Subject)))
}
func export(u uuid.UUID) []byte {
	var b bytes.Buffer
	must(data.Export(ctx, privacy.ExportRequest{UserID: u, OperationID: uuid.New()}, &b))
	z, e := zip.NewReader(bytes.NewReader(b.Bytes()), int64(b.Len()))
	must(e)
	var all bytes.Buffer
	for _, f := range z.File {
		r, e := f.Open()
		must(e)
		_, e = io.Copy(&all, r)
		must(e)
		must(r.Close())
	}
	return all.Bytes()
}
func (f fixture) counts(before bool) {
	want := 0
	if before {
		want = 1
	}
	for i, a := range f.Activities {
		for _, query := range []string{`select count(*) from activities where id=$1`, `select count(*) from scores where activity_id=$1`, `select count(*) from review_requests where activity_id=$1`, `select count(*) from ai_calls where activity_id=$1`} {
			var n int
			must(db.QueryRow(ctx, query, a).Scan(&n))
			require(n == want)
		}
		var n int
		must(db.QueryRow(ctx, `select count(*) from growth_scores where score_id=$1`, f.Sources[i]).Scan(&n))
		require(n == want)
	}
	for _, check := range []struct {
		query string
		id    uuid.UUID
	}{
		{`select count(*) from assessments where id=$1`, f.AssessmentID},
		{`select count(*) from daily_plans where assessment_id=$1`, f.AssessmentID},
		{`select count(*) from activities where id=$1`, f.DrillActivity},
		{`select count(*) from drill_progress where activity_id=$1`, f.DrillActivity},
		{`select count(*) from growth_drill_schedules where activity_id=$1`, f.DrillActivity},
	} {
		var n int
		must(db.QueryRow(ctx, check.query, check.id).Scan(&n))
		require(n == want)
	}
	for _, q := range []string{`select count(*) from users where id=$1`, `select count(*) from login_identities where user_id=$1`, `select count(*) from auth_sessions where user_id=$1`} {
		var n int
		must(db.QueryRow(ctx, q, f.B.UserId).Scan(&n))
		require(n == want)
	}
	var bRequests, bTombstones int
	must(db.QueryRow(ctx, `select count(*) from review_requests where user_id=$1`, f.B.UserId).Scan(&bRequests))
	must(db.QueryRow(ctx, `select count(*) from review_tombstones where user_id=$1`, f.B.UserId).Scan(&bTombstones))
	require(bRequests == want && bTombstones == 0)
	for i, id := range f.Windows {
		var n int
		must(db.QueryRow(ctx, `select count(*) from signal_windows where purge_id=$1`, id).Scan(&n))
		expected := want
		if i == 1 {
			expected = 1
		}
		require(n == expected)
	}
}
func (f fixture) verify() {
	f.counts(false)
	var pending int
	must(db.QueryRow(ctx, `select count(*) from pending_erasure`).Scan(&pending))
	require(pending == 0)
	// Reverse publication order: the erased B account is replayed before the
	// erased A review. Both must be rejected by the database source, not memory.
	for i := len(f.Sources) - 1; i >= 0; i-- {
		u := []uuid.UUID{f.A.UserId, f.B.UserId}[i]
		for _, at := range []time.Time{f.At, f.At.Add(-31 * 24 * time.Hour)} {
			before := projectionCount(f.Sources[i])
			e := bus.PublishScore(ctx, events.Score{ScoreKey: privacy.ScoreKey{UserID: u, SourceID: f.Sources[i], ActivityID: f.Activities[i], OccurredAt: at, Kind: "review"}})
			require(errors.Is(e, pgx.ErrNoRows) && projectionCount(f.Sources[i]) == before)
		}
	}
	var deleted uuid.UUID
	e := db.QueryRow(ctx, `select id from assessments where id=$1`, f.AssessmentID).Scan(&deleted)
	require(errors.Is(e, pgx.ErrNoRows))
	e = db.QueryRow(ctx, `select id from activities where id=$1`, f.DrillActivity).Scan(&deleted)
	require(errors.Is(e, pgx.ErrNoRows))
	e = bus.PublishAssessment(ctx, events.Assessment{UserID: f.A.UserId, AssessmentID: f.AssessmentID})
	require(errors.Is(e, pgx.ErrNoRows))
	e = bus.PublishDrill(ctx, events.Drill{UserID: f.A.UserId, ActivityID: f.DrillActivity, LevelID: f.DrillLevel, TargetItem: "observation", Score: 15, OccurredAt: f.At})
	require(errors.Is(e, pgx.ErrNoRows))
	f.counts(false)
	f.verifyWindowReplay()
	f.proveExpiredScore()
	var retainedTombstones int
	must(db.QueryRow(ctx, `select count(*) from review_tombstones where user_id=$1 and request_id=$2`, f.A.UserId, f.Requests[0]).Scan(&retainedTombstones))
	require(retainedTombstones == 1)
	var erasedTombstones int
	must(db.QueryRow(ctx, `select count(*) from review_tombstones where user_id=$1 and request_id=$2`, f.B.UserId, f.Requests[1]).Scan(&erasedTombstones))
	require(erasedTombstones == 0)
	body := export(f.A.UserId)
	require(!bytes.Contains(body, []byte(f.Sources[0].String())) && !bytes.Contains(body, []byte(f.Requests[0].String())) && bytes.Contains(body, []byte(f.A.UserId.String())) && bytes.Count(body, []byte(`"window":`)) == 1)
	require(!bytes.Contains(body, []byte(`"record_type":"plan"`)) && !bytes.Contains(body, []byte(`"record_type":"drill"`)))
	var b bytes.Buffer
	e = data.Export(ctx, privacy.ExportRequest{OperationID: uuid.New(), UserID: f.B.UserId}, &b)
	require(errors.Is(e, pgx.ErrNoRows) && b.Len() == 0)
	p, e := auth.Parse(f.B.AccessToken)
	must(e)
	require(accounts.IsAuth(auth.CancelClosure(ctx, p)))
	_, e = auth.Refresh(ctx, f.B.RefreshToken)
	require(accounts.IsAuth(e))
	fresh, e := login(f.Subject, false)
	require(e == nil && fresh.UserId != f.B.UserId)
	exec(`delete from users where id=$1`, fresh.UserId)
	f.counts(false)
}

// status calls the production router in-process. It never opens a listener or
// prints response bodies, bearer material or account data.
func status(parent context.Context, handler http.Handler, path, token string) int {
	req := httptest.NewRequestWithContext(parent, http.MethodGet, "http://drill.local"+path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	code := rec.Code
	rec.Body.Reset()
	return code
}

// waitHealth is bounded by the caller and accepts only the real production
// health handler returning 200. Startup races therefore fail closed.
func waitHealth(parent context.Context, handler http.Handler) error {
	wait, cancel := context.WithTimeout(parent, 30*time.Second)
	defer cancel()
	for {
		if status(wait, handler, "/v1/health", "") == http.StatusOK {
			return nil
		}
		select {
		case <-wait.Done():
			return errors.New("restored health unavailable")
		case <-time.After(250 * time.Millisecond):
		}
	}
}

// httpcheck exercises the restored service through the production router and
// account checks, but without an external API container or maintenance loop.
func (f fixture) httpcheck(c service.Config) {
	runtime, e := service.Start(ctx, c)
	must(e)
	defer runtime.Close()
	router := runtime.Router()
	must(waitHealth(ctx, router))
	require(status(ctx, router, "/v1/reviews/"+f.Activities[0].String(), f.A.AccessToken) == 404)
	require(status(ctx, router, "/v1/me", f.A.AccessToken) == 200)
	require(status(ctx, router, "/v1/me", f.B.AccessToken) == 401)
}

func (f fixture) proveExpiredScore() {
	activity, source := uuid.New(), uuid.New()
	at := time.Now().UTC().Add(-721 * time.Hour).Truncate(time.Microsecond)
	exec(`insert into activities(id,user_id,source_id,kind,state) values($1,$2,$3,'review','complete')`, activity, f.A.UserId, source)
	exec(`insert into scores(id,activity_id,activity_kind,detail_enc,occurred_at) values($1,$2,'review',$3,$4)`, source, activity, scoreDetail(f.A.UserId, source), at)
	defer exec(`delete from activities where id=$1`, activity)
	before := projectionCount(source)
	e := bus.PublishScore(ctx, events.Score{ScoreKey: privacy.ScoreKey{UserID: f.A.UserId, ActivityID: activity, SourceID: source, Kind: "review", OccurredAt: at}})
	require(errors.Is(e, pgx.ErrNoRows) && projectionCount(source) == before)
	var activities, scores int
	must(db.QueryRow(ctx, `select count(*) from activities where id=$1`, activity).Scan(&activities))
	must(db.QueryRow(ctx, `select count(*) from scores where id=$1 and occurred_at=$2`, source, at).Scan(&scores))
	require(activities == 1 && scores == 1)
}
