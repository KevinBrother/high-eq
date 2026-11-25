import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]


class DrillContract(unittest.TestCase):
    def test_runtime_composition_and_real_decoder_are_mirrored(self):
        main = (HERE / 'drill/main.go').read_text()
        modules = (
            'training', 'chat_imports', 'profiles', 'assessments', 'payments', 'membership',
            'accounts', 'replies', 'ai_calls', 'emotion', 'manual_marks', 'reviews',
            'growth',
        )
        hooks = (
            'payments.Hooks()', 'rights.Hooks()', 'assessment.Hooks(c.Fields)',
            'accounts.Hooks(c.Fields)', 'training.Hooks(c.Fields)', 'training.ChatImportHooks()',
            'profiles.Hooks()', 'replies.Hooks(c.Fields)', 'gateway.Hooks(key)', 'emotion.Hooks(c.Fields)', 'marks.Hooks(c.Fields)',
            'reviews.Hooks(c.Fields)', 'growth.Hooks(c.Fields, &training.Service{Fields: c.Fields})',
        )
        for module in modules:
            self.assertIn('"%s"' % module, main)
        for position, hook in enumerate(hooks):
            self.assertLess(
                main.index(hook),
                main.index(hooks[position + 1]) if position + 1 < len(hooks) else len(main),
            )
        self.assertIn('training.Decoder(c.Fields, reviews.Decoder(c.Fields))', main)
        self.assertIn('privacy.WithWindowReplayKey(key)', main)
        self.assertNotIn('func decodeScore', main)

    def test_offline_drill_registers_real_growth_and_plan_consumers(self):
        main = (HERE / 'drill/main.go').read_text()
        for evidence in (
            '"high-eq/server/internal/growth"',
            'growth.Service{Fields: c.Fields}',
            'growthConsumer := &growth.Service{Fields: c.Fields}',
            'bus.ScoreCompleted.Subscribe(growthConsumer.Consume)',
            'growth.NewPlanService(growth.PlanDependencies{',
            'bus.AssessmentCompleted.Subscribe(plans.ConsumeAssessment)',
            'bus.DrillProgressed.Subscribe(plans.ConsumeDrill)',
            'bus.ScoreCompleted.Subscribe(plans.ConsumeScore)',
            'trainingPlanLevels{}',
        ):
            with self.subTest(evidence=evidence):
                self.assertIn(evidence, main)
        self.assertNotIn('Probe', main, 'real consumers, not a synthetic delivery probe, must prove delivery')

    def test_fixture_exercises_growth_through_real_services_and_events(self):
        fixture = (HERE / 'drill/fixture.go').read_text()
        for evidence in (
            'assessments.Submit(',
            'practice.Create(',
            'training.PlanLevelIDs("observation", "work")',
            'bus.PublishDrill(',
            'bus.PublishScore(',
            'insert into activities(id,user_id,source_id,kind,state)',
            "insert into scores(id,activity_id,activity_kind,detail_enc,occurred_at)",
            'require(plans == 1)',
            'require(schedules == 1)',
        ):
            with self.subTest(evidence=evidence):
                self.assertIn(evidence, fixture)
        self.assertNotIn('insert into growth_scores', fixture.lower(),
                         'growth scores must be produced by the real growth consumer')

    def test_fixture_proves_growth_deletion_export_replay_and_source_retention(self):
        fixture = (HERE / 'drill/fixture.go').read_text()
        fixture += (HERE / 'drill/deletion_witness.go').read_text()
        for evidence in (
            'insert into review_requests',
            'review_tombstones',
            'select count(*) from activities where id=$1',
            'select count(*) from scores where activity_id=$1',
            'select count(*) from review_requests where activity_id=$1',
            'select count(*) from ai_calls where activity_id=$1',
            'select count(*) from growth_scores where score_id=$1',
            'select count(*) from daily_plans where assessment_id=$1',
            'select count(*) from drill_progress where activity_id=$1',
            'select count(*) from growth_drill_schedules where activity_id=$1',
            '{"assessments", f.AssessmentID}',
            '{"sessions", f.DrillSource}',
            '{"reviews", f.Sources[0]}',
            'f.erase("signal_windows", f.Windows[0])',
            'fields.Seal(plain, reviewAAD(user, source, "score"))',
            'for i := len(f.Sources) - 1; i >= 0; i--',
            '721 * time.Hour',
            'require(activities == 1 && scores == 1)',
            '"record_type":"score"',
            '"record_type":"plan"',
            '"record_type":"drill"',
        ):
            with self.subTest(evidence=evidence):
                self.assertIn(evidence, fixture)

    def test_score_checks_use_the_real_event_bus_and_expiry_path(self):
        main = (HERE / 'drill/main.go').read_text()
        fixture = (HERE / 'drill/fixture.go').read_text()
        self.assertIn('events.New(data,', main)
        self.assertIn('PublishScore', fixture)
        self.assertNotIn('data.ConsumeScore', fixture)
        self.assertIn("login(f.Subject, false)", fixture)
        self.assertNotIn("login(f.Subject, true)", fixture)
        self.assertIn('721', fixture, 'expiry must be proven against a still-present source')
        self.assertIn('bus.PublishScore', fixture)
        self.assertIn('bus.PublishDrill', fixture)

    def test_completed_drill_seed_persists_the_real_progress_envelope(self):
        fixture = (HERE / 'drill/fixture.go').read_text()
        seed = fixture.split('func (f *fixture) seed(key []byte)', 1)[1]
        insert = 'insert into drill_progress(activity_id,target_item,progress_enc,retry_at)'
        complete = "update activities set state='complete' where id=$1"
        self.assertIn(insert, seed)
        self.assertLess(seed.index(insert), seed.index(complete))
        self.assertLess(seed.index(insert), seed.index('bus.PublishDrill('))
        self.assertIn('scoring.Progress{', fixture)
        self.assertIn('NextAction: "retry_in_three_days"', fixture)
        self.assertIn('"practice/progress/" + user.String() + "/" + source.String()', fixture)
        self.assertIn("f.At.Add(72*time.Hour)", seed)

    def test_recovery_uses_real_http_queries_after_the_gate(self):
        main = (HERE / 'drill/main.go').read_text()
        fixture = (HERE / 'drill/fixture.go').read_text()
        release = (HERE / 'release.py').read_text()
        self.assertIn('case "httpcheck"', main)
        self.assertIn('f.httpcheck(c)', main)
        self.assertIn('service.Start(ctx, c)', fixture)
        self.assertIn('runtime.Router()', fixture)
        self.assertIn('httptest.NewRequestWithContext', fixture)
        self.assertNotIn('http://api:8080', fixture)
        self.assertIn('"/v1/me"', fixture)
        self.assertIn('"/v1/reviews/"', fixture)
        self.assertIn('== 404', fixture)
        self.assertIn('== 200', fixture)
        self.assertIn('== 401', fixture)
        self.assertIn("lab.job('drill','httpcheck',input=raw)", release)

    def test_recovery_http_probe_waits_for_real_health(self):
        fixture = (HERE / 'drill/fixture.go').read_text()
        httpcheck = fixture.split('func (f fixture) httpcheck(c service.Config)', 1)[1]
        self.assertIn('waitHealth(ctx, router)', httpcheck)
        self.assertLess(httpcheck.index('waitHealth(ctx, router)'), httpcheck.index('/v1/reviews/'))
        self.assertIn('"/v1/health"', fixture)
        self.assertIn('context.WithTimeout(parent, 30*time.Second)', fixture)
        self.assertIn('time.After', fixture)
        self.assertIn('http.StatusOK', fixture)
        self.assertNotIn('ListenAndServe', fixture)


    def test_failures_emit_only_fixed_stage_and_source_position(self):
        main = (HERE / 'drill/main.go').read_text()
        fixture = (HERE / 'drill/fixture.go').read_text()
        diagnostic = (HERE / 'drill/diagnostic.go').read_text()
        self.assertIn('safeFailureMessage(recovered, activeStage, activeSite)', main)
        self.assertIn('fmt.Fprint(os.Stderr, safeFailureMessage', main)
        self.assertNotIn('offline drill refused at', main)
        self.assertNotIn('panic(e)', main)
        self.assertNotIn('panic("assertion failed")', main)
        self.assertNotIn('debug.Stack', main + fixture + diagnostic)
        self.assertIn('offline drill refused stage=%s at=%s:%d\\n', diagnostic)
        self.assertIn('runtime.Caller(skip)', diagnostic)
        for stage in (
            'stageSeedLoginA', 'stageSeedReviewA', 'stageSeedReviewB',
            'stageSeedAssessmentSubmit', 'stageSeedAssessmentPlan',
            'stageSeedDrillCreate', 'stageSeedDrillEvent', 'stageSeedExportA',
        ):
            with self.subTest(stage=stage):
                self.assertIn(stage, fixture)
                self.assertIn(stage, diagnostic)


if __name__ == '__main__':
    unittest.main()
