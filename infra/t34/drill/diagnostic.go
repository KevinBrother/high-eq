package main

import (
	"fmt"
	"path/filepath"
	"runtime"
)

// drillStage values are compile-time constants so failure output can never
// echo argv, SQL, environment values or other request material.
type drillStage string

const (
	stageMainInit             drillStage = "main.init"
	stageMainConfig           drillStage = "main.config"
	stageMainMigrate          drillStage = "main.migrate"
	stageMainDatabase         drillStage = "main.database"
	stageMainLedger           drillStage = "main.ledger"
	stageMainMembership       drillStage = "main.membership"
	stageMainRegistry         drillStage = "main.registry"
	stageMainEvents           drillStage = "main.events"
	stageMainProviders        drillStage = "main.providers"
	stageMainAuth             drillStage = "main.auth"
	stageMainAssessmentBank   drillStage = "main.assessment_bank"
	stageMainPlanService      drillStage = "main.plan_service"
	stageMainInput            drillStage = "main.input"
	stageMainSeedOutput       drillStage = "main.seed_output"
	stageMainPreflight        drillStage = "main.preflight"
	stageMainDelete           drillStage = "main.delete"
	stageMainRestore          drillStage = "main.restore"
	stageMainHTTPCheck        drillStage = "main.httpcheck"
	stageMainInvalidPhase     drillStage = "main.invalid_phase"
	stageSeedSubject          drillStage = "seed.subject"
	stageSeedLoginA           drillStage = "seed.login_a"
	stageSeedLoginB           drillStage = "seed.login_b"
	stageSeedPrincipal        drillStage = "seed.principal"
	stageSeedConsentAssess    drillStage = "seed.consent_assessment"
	stageSeedConsentPractice  drillStage = "seed.consent_practice"
	stageSeedReviewA          drillStage = "seed.review_a"
	stageSeedReviewB          drillStage = "seed.review_b"
	stageSeedAssessmentSubmit drillStage = "seed.assessment_submit"
	stageSeedAssessmentState  drillStage = "seed.assessment_state"
	stageSeedAssessmentPlan   drillStage = "seed.assessment_plan"
	stageSeedDrillLevel       drillStage = "seed.drill_level"
	stageSeedDrillCreate      drillStage = "seed.drill_create"
	stageSeedDrillComplete    drillStage = "seed.drill_complete"
	stageSeedDrillEvent       drillStage = "seed.drill_event"
	stageSeedDrillSchedule    drillStage = "seed.drill_schedule"
	stageSeedSignalConsent    drillStage = "seed.signal_consent"
	stageSeedSignal1          drillStage = "seed.signal_1"
	stageSeedSignal2          drillStage = "seed.signal_2"
	stageSeedAccountKey       drillStage = "seed.account_key"
	stageSeedLedgerBinding    drillStage = "seed.ledger_binding"
	stageSeedExpected         drillStage = "seed.expected"
	stageSeedCounts           drillStage = "seed.counts"
	stageSeedExportA          drillStage = "seed.export_a"
	stageSeedExportB          drillStage = "seed.export_b"
	stageChatImportSeed       drillStage = "seed.chat_imports"
	stageChatImportStored     drillStage = "chat_imports.storage"
	stageChatImportProcess    drillStage = "chat_imports.process"
	stageChatImportRead       drillStage = "chat_imports.read"
	stageChatImportExport     drillStage = "chat_imports.export"
	stageChatImportRetry      drillStage = "chat_imports.retry"
)

type drillSite struct {
	file string
	line int
}

type drillFailure struct {
	stage drillStage
	site  drillSite
}

var activeStage = stageMainInit
var activeSite = drillSite{file: "main.go", line: 1}

// enter records a fixed phase boundary. It is used as the safe fallback when a
// dependency panics instead of returning an error.
func enter(stage drillStage) {
	_, file, line, ok := runtime.Caller(1)
	if !ok || file == "" {
		activeSite = drillSite{file: "main.go", line: 1}
	} else {
		activeSite = drillSite{file: filepath.Base(file), line: line}
	}
	activeStage = stage
}

// fail captures only the caller basename and line. The skip count is chosen by
// the helper so direct callers see the fixture/main call site, not the helper.
func fail(skip int) {
	_, file, line, ok := runtime.Caller(skip)
	site := drillSite{file: "main.go", line: 1}
	if ok && file != "" {
		site = drillSite{file: filepath.Base(file), line: line}
	}
	panic(drillFailure{stage: activeStage, site: site})
}

// safeFailureMessage never formats the recovered value. A dependency panic is
// represented only by the fixed stage and location recorded by enter().
func safeFailureMessage(recovered any, stage drillStage, site drillSite) string {
	failure, ok := recovered.(drillFailure)
	if !ok {
		failure = drillFailure{stage: stage, site: site}
	}
	if failure.stage == "" {
		failure.stage = stageMainInit
	}
	file := filepath.Base(failure.site.file)
	if file == "" || file == "." || file == string(filepath.Separator) {
		file = "main.go"
	}
	line := failure.site.line
	if line < 1 {
		line = 1
	}
	return fmt.Sprintf("offline drill refused stage=%s at=%s:%d\n", failure.stage, file, line)
}
