#!/usr/bin/env python3
"""T33 static contract checks for the correction archive.

These tests intentionally use only local files. They separate fixed-baseline
facts from candidate evidence and keep unverified product goals marked as such.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMPLIANCE = ROOT / "docs" / "compliance"
BASELINE = "f60ace3"
CANDIDATE = "ce479034bcba174475fa8fbc156be66a3b22ba5371b5344602f29394185d638a"
OLD_BASELINE = "bd6e34e0ce8f3b96da61f7eea2e391a40cdcf70c"


def read(path: str | Path) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def compliance_corpus() -> str:
    return "\n".join(
        p.read_text(encoding="utf-8") for p in sorted(COMPLIANCE.glob("*.md"))
    )


class BaselineAndScopeContract(unittest.TestCase):
    def test_fixed_baseline_and_candidate_evidence_are_separate(self) -> None:
        docs = [ROOT / "docs/tasks/T33.md", *sorted(COMPLIANCE.glob("*.md"))]
        for path in docs:
            text = path.read_text(encoding="utf-8")
            self.assertIn(BASELINE, text, f"{path}: missing fixed baseline")
            self.assertNotIn(OLD_BASELINE, text, f"{path}: stale baseline remains")

        t33 = read("docs/tasks/T33.md")
        self.assertIn(CANDIDATE, t33)
        self.assertRegex(t33, r"候选(?:实现|证据).*ce479034bcba")
        self.assertNotIn("11 个文件", t33)
        self.assertRegex(t33, r"主会话.*(?:提取|生成).*补丁")
        self.assertRegex(t33, r"本轮.*不.*(?:生成|创建).*补丁")

    def test_cross_card_changes_are_appended_not_denied(self) -> None:
        t33 = read("docs/tasks/T33.md")
        changes = read("docs/CHANGES.md")
        self.assertRegex(t33, r"CHANGES\.md.*(?:仅)?追加")
        self.assertRegex(changes, r"T33")
        for needle in ("/v1/me/export", "/v1/me/data", "1 天", "健康权限"):
            self.assertIn(needle, changes)


class BaselineSourceFactsContract(unittest.TestCase):
    def test_android_and_ios_permissions_are_not_inflated(self) -> None:
        manifest = read("app/android/app/src/main/AndroidManifest.xml")
        permissions = re.findall(r'android:name="android\.permission\.([^"]+)"', manifest)
        self.assertEqual(permissions, ["INTERNET"])
        for forbidden in (
            "ACTIVITY_RECOGNITION",
            "READ_HEART_RATE",
            "READ_HEART_RATE_VARIABILITY",
            "READ_STEPS",
            "READ_EXERCISE",
            "RECORD_AUDIO",
        ):
            self.assertNotIn(forbidden, manifest)

        plist = read("app/ios/Runner/Info.plist")
        entitlements = read("app/ios/Runner/Runner.entitlements")
        self.assertNotIn("NSHealthShareUsageDescription", plist)
        self.assertNotIn("NSMicrophoneUsageDescription", plist)
        self.assertNotIn("com.apple.developer.healthkit", entitlements)

        corpus = compliance_corpus()
        self.assertRegex(corpus, r"Android.*Manifest.*仅.*INTERNET")
        self.assertRegex(corpus, r"iOS.*(?:没有|未包含|不存在).*NSHealthShareUsageDescription")

    def test_incremental_modules_are_not_counted_as_baseline(self) -> None:
        profile_files = {
            path.name for path in (ROOT / "server/internal/profile").glob("*.go")
        }
        for name in ("contacts.go", "feedback.go", "infer.go", "inference_request.go"):
            self.assertIn(name, profile_files, "T25 profile implementation is present")

        reply_requests = read("server/migrations/20261123000021_reply_requests.up.sql")
        reply_keys = read("server/migrations/20261123000022_reply_request_keys.up.sql")
        receipts = read("server/migrations/20261123000023_reply_outcome_receipts.up.sql")
        migrations = "\n".join((reply_requests, reply_keys, receipts))
        for table in (
            "reply_requests",
            "reply_feedback",
            "reply_request_keys",
            "reply_outcome_receipts",
        ):
            self.assertIn(f"CREATE TABLE {table}", migrations)
        self.assertIn("chat_consent_id uuid NOT NULL REFERENCES consents", reply_requests)
        self.assertIn("contacts_consent_id uuid REFERENCES consents", reply_requests)
        self.assertIn("binding.chat", read("server/internal/replies/consent.go"))
        self.assertIn("QA-33 | T21", read("docs/compliance/qa.md"))
        inventory_rows = read("docs/compliance/data-inventory.md").splitlines()
        request_row = next(line for line in inventory_rows if line.startswith("| D11 |"))
        self.assertIn("不重查原用途授权、不重读画像、不外发、不再次扣次", request_row)
        self.assertIn("每条新反馈", next(line for line in inventory_rows if line.startswith("| D12 |")))
        self.assertIn("CREATE TRIGGER reply_import_guard", reply_requests)
        self.assertIn("BEFORE INSERT OR UPDATE ON chat_imports", reply_requests)
        self.assertIn(
            "DELETE FROM chat_imports c USING activities a WHERE a.id=c.activity_id AND a.kind='reply'",
            reply_requests,
        )
        self.assertEqual(reply_requests.count("CHECK(octet_length(input_mac)=32)"), 2)
        self.assertIn("outcome_enc bytea NOT NULL", reply_requests)
        self.assertIn(
            "activity_id uuid UNIQUE REFERENCES activities ON DELETE SET NULL",
            reply_keys,
        )

        request_sql = re.search(
            r"CREATE TABLE reply_requests \((.*?)\n\);", reply_requests, re.S
        )
        feedback_sql = re.search(
            r"CREATE TABLE reply_feedback \((.*?)\n\);", reply_requests, re.S
        )
        receipt_sql = re.search(
            r"CREATE TABLE reply_outcome_receipts \((.*?)\n\);", receipts, re.S
        )
        self.assertIsNotNone(request_sql)
        self.assertIsNotNone(feedback_sql)
        self.assertIsNotNone(receipt_sql)
        for body in (request_sql.group(1), feedback_sql.group(1)):
            self.assertNotRegex(body, r"chat_text|goal|destination|input_text")
        for forbidden in (
            "outcome_enc",
            "chat_text",
            "goal",
            "destination",
            "suggestion_text",
            "effect_text",
        ):
            self.assertNotIn(forbidden, receipt_sql.group(1))

        service = read("server/internal/replies/service.go")
        feedback = read("server/internal/replies/feedback.go")
        reply_privacy = read("server/internal/replies/privacy.go")
        profile_outcome = read("server/internal/profile/outcome.go")
        http = read("server/internal/service/http.go")
        self.assertIn('"POST /v1/replies": false', http)
        self.assertIn('"POST /v1/replies/:id/feedback": false', http)
        self.assertIn('in.ChatText, in.Goal, summary', service)
        self.assertIn('s.cipher.Seal(b, aad(p.User, fid, "outcome"))', feedback)
        self.assertIn('s.cipher.Open(encrypted, aad(v.UserID, v.FeedbackID, "outcome"))', feedback)
        self.assertIn("insert into reply_outcome_receipts", profile_outcome)
        self.assertIn("does not create a profile observation", profile_outcome)
        self.assertNotIn("reply_outcome_receipts", reply_privacy)

        self_reports = feedback.split('select a.source_id,a.contact_id,f.occurred_at,f.outcome_enc', 1)
        self.assertEqual(len(self_reports), 2)
        self.assertIn("f.pending and f.self_report", self_reports[1])
        self.assertIn("s.recorder.RecordActivity", self_reports[1])
        outcome_delivery = feedback.split("func (s *Service) deliverOutcome", 1)[1]
        self.assertNotIn("RecordActivity", outcome_delivery)

        inventory = read("docs/compliance/data-inventory.md")
        for needle in (
            "T21 后端增量",
            "reply_request_keys",
            "reply_outcome_receipts",
            "服务端不持久化源文本与目的",
            "ON DELETE SET NULL",
            "32 字节带密钥 HMAC",
            "普通效果不写本人画像",
            "只有显式 `self_report`",
            "不计入 `f60ace3` 的 42 项",
        ):
            self.assertIn(needle, inventory)

        corpus = compliance_corpus()
        self.assertNotRegex(corpus, r"reply_requests[^\n]*(?:候选|待对表|不存在)")
        self.assertNotIn("T21 服务端仍未合入", corpus)
        self.assertIn("T25 后端增量", corpus)
        self.assertIn("回复类导入触发器", corpus)
        self.assertRegex(corpus, r"回复.*触发器.*禁止.*chat_imports")
        self.assertIn("notice.v1` 不能代替服务端同意", read("docs/compliance/separate-consents.md"))

    def test_practice_consent_precedes_creation_and_rechecks_after_grant(self) -> None:
        lobby = read("app/lib/features/practice/lobby.dart")
        consent = lobby.split("Future<bool> ensurePracticeConsent()", 1)[1].split("Future<void> create(", 1)[0]
        self.assertLess(consent.index("practiceConsent()"), consent.index("showDialog"))
        self.assertLess(consent.index("if (ok != true"), consent.index("grantPracticeConsent()"))
        self.assertLess(consent.index("grantPracticeConsent()"), consent.rindex("practiceConsent()"))
        create = lobby.split("Future<void> create(Json intent)", 1)[1].split("Future<void> open(", 1)[0]
        self.assertLess(create.index("if (!await ensurePracticeConsent()) return"), create.index("widget.repo.create(body)"))
        repo = read("app/lib/features/practice/repository.dart")
        self.assertIn("purpose: 'practice'", repo)
        self.assertIn("'version': 'v1', 'granted': true", repo)

    def test_t19_practice_contract_is_substantive(self) -> None:
        migration = read("server/migrations/20261122003019_practice_work.up.sql")
        down = read("server/migrations/20261122003019_practice_work.down.sql")
        for needle in (
            "REFERENCES activities ON DELETE CASCADE",
            "used_tokens integer NOT NULL DEFAULT 0 CHECK(used_tokens BETWEEN 0 AND 30000)",
            "worker uuid, valid_until timestamptz",
            "settlement_pending boolean NOT NULL DEFAULT false",
            "settlement_outcome text CHECK(settlement_outcome IN ('safety','moderation_unavailable','failed'))",
            "CHECK ((worker IS NULL) = (valid_until IS NULL))",
            "'capped'",
            "19000000-1000-4000-8000-000000000001",
        ):
            self.assertIn(needle, migration)
        self.assertIn("UPDATE activities SET state='failed' WHERE state='capped'", down)

        store = read("server/internal/training/store.go")
        self.assertIn('accounts.Granted(ctx, tx, u, "practice")', store)
        allowed = store.split("func (s *Service) allowed(", 1)[1].split("\nfunc ", 1)[0]
        self.assertRegex(allowed, re.compile(
            r'if in\.Contact != nil \{\s+if s\.Summary != nil \{.*?'
            r'accounts\.Granted\(ctx, tx, u, "contacts"\).*?return membership\.ErrForbidden'
            r'\s+\}\s+\}\s+return s\.Rights\.RequireContact\(ctx, tx, u, in\.Contact\)', re.S))
        for doc in ("data-inventory.md", "privacy-policy-draft.md", "separate-consents.md"):
            self.assertIn("T19 已接入 T25 画像摘要，选用关系人时额外检查 `contacts`", read("docs/compliance/" + doc))

        work = read("server/internal/training/work.go")
        self.assertIn(
            "worker=$3 and valid_until>clock_timestamp()",
            work,
        )
        self.assertIn("type guardedRunner struct", work)
        self.assertIn("c.Guard = r.guard", work)
        self.assertIn("return s.Accounts.WithSession(ctx, p, false", work)
        self.assertIn("return s.allowed(ctx, tx, j.user, j.input)", work)
        self.assertIn("update activities set state='capped'", work)
        self.assertIn("delete from practice_messages", work)

        privacy = read("server/internal/training/privacy.go")
        self.assertIn('case "account", "contacts", "sessions"', privacy)
        self.assertIn("join practice_work on activity_id=id", privacy)
        self.assertIn("limit 50", privacy)
        self.assertIn('json:"setup"', privacy)
        self.assertIn('json:"source_id"', privacy)

        delivery = read("server/internal/training/delivery.go")
        self.assertIn("interval '95 seconds'", read("server/internal/training/work.go"))
        self.assertIn("interval '720 hours'", delivery)

        http = read("server/internal/service/http.go")
        routes = re.search(r"var accountRoutes = map\[string\]bool\{(.*?)\n\}", http, re.S)
        self.assertIsNotNone(routes)
        route_block = routes.group(1)
        for route in (
            "GET /v1/levels",
            "GET /v1/sessions",
            "POST /v1/sessions",
            "GET /v1/sessions/:session_id",
            "POST /v1/sessions/:session_id/messages",
            "POST /v1/sessions/:session_id/exit",
            "POST /v1/sessions/:session_id/finish",
        ):
            self.assertIn(route, route_block)
        self.assertNotIn("GET /v1/me/export", route_block)
        self.assertNotIn("DELETE /v1/me/data/:kind/:id", route_block)

        inventory = read("docs/compliance/data-inventory.md")
        d38 = re.search(r"^\| D38 \|.*$", inventory, re.M)
        self.assertIsNotNone(d38, "data-inventory.md must have a D38 practice_work row")
        for phrase in (
            "practice_work",
            "used_tokens",
            "worker",
            "valid_until",
            "settlement_pending",
            "settlement_outcome",
            "capped",
            "ON DELETE CASCADE",
            "不含正文",
            "501 not_implemented",
            "42",
            "T35",
            "T19 后端增量",
        ):
            self.assertIn(phrase, d38.group(0), phrase)

        self.assertIn("TestPracticeWire", read("docs/compliance/qa.md"))

    def test_practice_setup_is_authorized_detail_only_and_contact_deletion_is_scoped(self) -> None:
        lobby = read("app/lib/features/practice/lobby.dart")
        demo = read("app/lib/features/practice/demo.dart")
        store = read("server/internal/training/store.go")
        api = read("docs/api/app.yaml")
        conversation = read("app/lib/features/practice/conversation.dart")
        inventory = read("docs/compliance/data-inventory.md")

        self.assertNotIn("started.", lobby)
        self.assertIn("_pruneDeletedContacts", demo)
        self.assertIn("..remove('setup')", demo)
        self.assertIn("contact is String && !ids.contains(contact)", demo)

        summary = store.split("type SessionSummary struct {", 1)[1].split("type Session struct {", 1)[0]
        session = store.split("type Session struct {", 1)[1].split("func (r record) summary()", 1)[0]
        self.assertNotIn("Setup", summary)
        self.assertIn("Setup *Input", session)
        self.assertIn("Items []SessionSummary `json:\"items\"`", store)
        listing = store.split("func (s *Service) List(", 1)[1]
        self.assertIn("r.summary()", listing)
        self.assertNotIn("r.Session", listing)

        summary_schema = api.split("    SessionSummary:", 1)[1].split("    Level:", 1)[0]
        detail_schema = api.split("    Session:", 1)[1].split("    SessionSummary:", 1)[0]
        list_schema = api.split("    ListSessionsResult:", 1)[1].split("    Reply:", 1)[0]
        create_endpoint = api.split("  /v1/sessions:", 1)[1].split("  /v1/sessions/{session_id}:", 1)[0]
        self.assertIn("setup:", detail_schema)
        for forbidden in ("setup:", "contact_id", "previous_id", "scenario"):
            self.assertNotIn(forbidden, summary_schema)
        self.assertIn("$ref: '#/components/schemas/SessionSummary'", create_endpoint)
        self.assertNotIn("$ref: '#/components/schemas/Session'", create_endpoint)
        self.assertIn("$ref: '#/components/schemas/SessionSummary'", list_schema)
        detail_endpoint = api.split("  /v1/sessions/{session_id}:", 1)[1].split("  /v1/sessions/{session_id}/exit:", 1)[0]
        self.assertIn("$ref: '#/components/schemas/Session'", detail_endpoint)

        create = store.split("func (s *Service) Create(", 1)[1].split("func (s *Service) Get(", 1)[0]
        self.assertIn("(out SessionSummary, e error)", create)
        self.assertIn("out = r.summary()", create)
        self.assertNotIn("out = Session{", create)

        exit_method = conversation.split("Future<void> exit() async {", 1)[1].split("Future<void> retry()", 1)[0]
        self.assertIn("current?['kind'] == 'exit'", exit_method)
        self.assertIn("current['fallback'] as Json", exit_method)
        self.assertIn("不形成嵌套退出", read("app/test/practice/finish_exit_test.dart"))

        d10 = re.search(r"^\| D10 \|.*$", inventory, re.M)
        self.assertIsNotNone(d10, "data-inventory.md must have a D10 practice row")
        for phrase in (
            "activities.content_enc",
            "SessionSummary",
            "有效登录会话",
            "归属",
            "不要求仍有有效的 `practice` 同意",
            "重练创建才复核",
            "creating",
            "practice.started",
            "外键级联",
            "跨设备",
        ):
            self.assertIn(phrase, d10.group(0), phrase)

    def test_candidate_evidence_uses_archive_hash_not_working_tree(self) -> None:
        corpus = compliance_corpus()
        self.assertNotRegex(corpus, r"工作区中[^\n]*(?:未提交|未提交实现)")
        self.assertNotRegex(corpus, r"未提交实现[^\n]*(?:已实现|静态通过)")

        for path in (
            "docs/compliance/banned-words-and-examples.md",
            "docs/compliance/sdk-model-review-checklist.md",
        ):
            text = read(path)
            self.assertIn(CANDIDATE, text, path)
            self.assertRegex(text, r"候选[^\n]*(?:待对表|不等于|不证明)", path)

    def test_generic_export_and_delete_routes_return_not_implemented(self) -> None:
        http = read("server/internal/service/http.go")
        routes = re.search(r"var accountRoutes = map\[string\]bool\{(.*?)\n\}", http, re.S)
        self.assertIsNotNone(routes)
        route_block = routes.group(1)
        self.assertNotIn("GET /v1/me/export", route_block)
        self.assertNotIn("DELETE /v1/me/data/:kind/:id", route_block)
        self.assertIn('problem(c, 501, "not_implemented"', http)

        for path in (
            "docs/compliance/README.md",
            "docs/compliance/data-inventory.md",
            "docs/compliance/qa.md",
            "docs/compliance/privacy-policy-draft.md",
            "docs/tasks/T33.md",
        ):
            text = read(path)
            self.assertIn("/v1/me/export", text, path)
            self.assertIn("/v1/me/data/:kind/:id", text, path)
            self.assertIn("501 not_implemented", text, path)

    def test_drafts_do_not_claim_unmerged_rights_or_permissions(self) -> None:
        privacy = read("docs/compliance/privacy-policy-draft.md")
        filings = read("docs/compliance/filings-and-authorizations.md")
        separate = read("docs/compliance/separate-consents.md")

        self.assertIn("20261123000021_reply_requests.up.sql", privacy)
        self.assertIn("T21 后端增量", privacy)
        self.assertNotRegex(privacy, r"服务端存在导出能力|存在单条删除")
        self.assertRegex(privacy, r"/v1/me/export[^\n]*501 not_implemented")
        self.assertRegex(privacy, r"/v1/me/data/:kind/:id[^\n]*501 not_implemented")

        self.assertRegex(filings, r"Android.*Manifest.*仅.*INTERNET")
        self.assertRegex(filings, r"iOS.*(?:没有|未包含|不存在).*NSHealthShareUsageDescription")
        self.assertNotRegex(filings, r"ACTIVITY_RECOGNITION[^\n]*Manifest 已声明")
        self.assertNotRegex(filings, r"HealthKit[^\n]*entitlement 和[^\n]*存在")
        self.assertNotRegex(filings, r"(?:9 个|九个).*(?:DNS|HTTP|不可达|未取得)")

        self.assertNotRegex(separate, r"服务端仅检查有效未撤回记录")

    def test_security_and_deletion_boundaries_remain_explicit(self) -> None:
        corpus = compliance_corpus() + "\n" + read("docs/tasks/T33.md")
        for phrase in (
            "注销冻结",
            "撤销注销",
            "健康窗口专用删除",
            "AES-GCM",
            "删除协调器",
        ):
            self.assertIn(phrase, corpus)
        self.assertRegex(corpus, r"通用.*(?:导出|删除).*(?:未接线|未接通|501 not_implemented)")


class DataLineageContract(unittest.TestCase):
    def test_source_score_growth_and_call_chain_is_complete(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        required = (
            "scores.id = activities.source_id",
            "detail_enc",
            "growth_scores",
            "ai_calls.operation_id",
            "ai_calls.id",
            "score_id",
            "LinkScoreTx",
        )
        for needle in required:
            self.assertIn(needle, inventory)
        self.assertRegex(
            inventory,
            r"(?:失败|审核).*(?:score_id|关联).*(?:空|未补|不补)|(?:空|未补).*(?:失败|审核)",
        )

    def test_daily_plans_and_drill_progress_have_distinct_delete_scopes(self) -> None:
        migration = read("server/migrations/20261121000200_training.up.sql")
        daily = re.search(r"CREATE TABLE daily_plans \((.*?)\n\);", migration, re.S)
        drill = re.search(r"CREATE TABLE drill_progress \((.*?)\n\);", migration, re.S)
        self.assertIsNotNone(daily)
        self.assertIsNotNone(drill)
        self.assertIn("REFERENCES users ON DELETE CASCADE", daily.group(1))
        self.assertNotIn("REFERENCES activities", daily.group(1))
        self.assertIn("REFERENCES activities(id,kind) ON DELETE CASCADE", drill.group(1))

        inventory = read("docs/compliance/data-inventory.md")
        self.assertRegex(inventory, r"daily_plans[^\n]*随账号删除")
        self.assertRegex(inventory, r"drill_progress[^\n]*随单项活动删除")
        self.assertNotRegex(inventory, r"daily_plans[^\n]*随账号或相关活动删除")

    def test_one_day_provider_admission_is_not_proof_of_actual_retention(self) -> None:
        admission = read("server/migrations/20261121000600_gateway_admission.up.sql")
        self.assertIn("max_retention_days >= 0", admission)
        self.assertNotRegex(admission, r"max_retention_days\s*<=\s*1")

        checklist = read("docs/compliance/sdk-model-review-checklist.md")
        qa = read("docs/compliance/qa.md")
        t33 = read("docs/tasks/T33.md")
        routing = read("server/internal/gateway/store.go")
        self.assertIn("c.Task == ProfileInference && a.retention > 1", routing)
        self.assertIn("b.retention > a.retention", routing)
        for doc in [checklist, qa]:
            self.assertIn("不证明供应商实际留存或删除", doc)
            self.assertIn("1 天", doc)
        self.assertIn("1 天", t33)


class ReviewInventoryContract(unittest.TestCase):
    def test_recovery_and_tombstone_have_separate_lifetimes(self) -> None:
        migration = read("server/migrations/20261122120023_review_requests.up.sql")
        self.assertIn("mark_id uuid REFERENCES manual_marks(id) ON DELETE SET NULL", migration)
        self.assertIn("CREATE TABLE review_tombstones", migration)
        self.assertIn("AFTER DELETE ON users", migration)
        checkpoint = read("server/internal/reviews/checkpoint.go")
        self.assertIn("generatedCheckpointTTL = 15 * time.Minute", checkpoint)
        self.assertIn("generated_at=null,generated_expired=true", checkpoint)
        self.assertIn("s.Reviews.ReplayPending(worker)", read("server/cmd/api/main.go"))
        fields = read("server/internal/reviews/privacy.go")
        self.assertIn('record["approved_repair_draft"]', fields)
        self.assertIn('record["result"]', fields)
        self.assertNotIn("generated_enc", fields)
        journal = read("server/internal/reviews/store.go")
        self.assertIn("journalInput.MarkId, journalInput.SignalEventId = nil, nil", journal)
        self.assertIn("v.Submitted.MarkId, v.Submitted.SignalEventId = r.mark, r.signal", journal)
        row = next(line for line in read("docs/compliance/data-inventory.md").splitlines() if line.startswith("| D23 |"))
        for field in ("review_tombstones", "deleted_at", "15 分钟", "后台定期清扫", "reviews.json", "501 not_implemented"):
            self.assertIn(field, row)
        self.assertIn("未审核输出不展示、不导出", read("docs/compliance/separate-consents.md"))
        self.assertIn("成功落库时起算", row)
        self.assertIn("单独的已审核短语", row)
        self.assertIn("T26 真实下游消费待验", read("docs/compliance/qa.md"))


class ProfileEvidenceContract(unittest.TestCase):
    PROMPT_ID = "b935fb60-5a85-4c12-82c0-401afd649325"

    def test_profile_evidence_schema_freezes_sources_and_binds_both_consents(self) -> None:
        migration = read("server/migrations/20261122010025_profile_evidence.up.sql")
        for needle in (
            "CREATE TABLE profile_observations",
            "subject text NOT NULL CHECK(subject IN ('contact','self'))",
            "fact_enc bytea NOT NULL",
            "FOREIGN KEY(user_id,event_id) REFERENCES signal_events(user_id,id) ON DELETE CASCADE",
            "FOREIGN KEY(user_id,activity_id) REFERENCES activities(user_id,id) ON DELETE CASCADE",
            "CREATE TABLE activity_profile_context",
            "context_enc bytea NOT NULL",
            "PRIMARY KEY(user_id,activity_id)",
            "CREATE TABLE profile_inference_requests",
            "chat_consent_id uuid NOT NULL REFERENCES consents ON DELETE CASCADE",
            "contacts_consent_id uuid NOT NULL REFERENCES consents ON DELETE CASCADE",
            "CHECK(octet_length(input_digest)=32)",
            "CHECK(state IN ('processing','complete','invalidated'))",
            "FOREIGN KEY(user_id,contact_id) REFERENCES contacts(user_id,id) ON DELETE CASCADE",
        ):
            self.assertIn(needle, migration)
        self.assertIn("digest avoids", migration)
        self.assertIn("persisting chat text", migration)
        self.assertNotRegex(migration, r"(?:chat_text|input_text|message_text)")
        self.assertIn(self.PROMPT_ID, migration)
        self.assertIn("'profile_inference'", migration)
        self.assertIn("七个整数", migration)
        self.assertIn("不复述原文", migration)

        feedback = read("server/internal/profile/feedback.go")
        self.assertIn("Direction comes from the user's explicit judgment", feedback)
        self.assertIn("func (s *Service) bindActivityContext", feedback)
        self.assertIn("freezes the source scene, including a verified null", feedback)
        self.assertIn("insert into activity_profile_context", feedback)
        self.assertIn("return \"\", membership.ErrConflict", feedback)

    def test_profile_inference_revalidates_exact_consents_and_fails_closed(self) -> None:
        contacts = read("server/internal/profile/contacts.go")
        write = contacts.split("func (s *Service) write(", 1)[1].split("\nfunc ", 1)[0]
        self.assertLess(
            write.index('consent(ctx, tx, u, "contacts")'),
            write.index("RequireContact(ctx, tx, u, id)"),
        )
        for_model = contacts.split("func (s *Service) ForModel(", 1)[1].split("\nfunc ", 1)[0]
        self.assertIn("s.write(ctx, tx, u, &id)", for_model)

        infer = read("server/internal/profile/infer.go")
        request = read("server/internal/profile/inference_request.go")
        for needle in (
            'activeConsent(ctx, tx, u, "chat_import")',
            'activeConsent(ctx, tx, u, "contacts")',
            "reserveInference(ctx, tx, u, id, in.RequestId, chatConsent, contactsConsent, digest)",
            "call.BeforeAttempt = func(attemptCtx context.Context) error",
            "checkInferenceAttempt(attemptCtx, session, u, id, in.RequestId, reserved.chatConsent, reserved.contactsConsent, digest",
            "chatConsent != reserved.chatConsent",
            "contactsConsent != reserved.contactsConsent",
            "stored.state != \"processing\"",
            "invalidateInference(ctx, tx, u, in.RequestId)",
            "if reserved.state == \"complete\"",
            "len(x.Choices) != len(axes)",
            'i == 6 && sc != "partner"',
        ):
            self.assertIn(needle, infer)
        for needle in (
            "func inputDigest(text string) []byte",
            "sha256.Sum256([]byte(text))",
            "case \"invalidated\":",
            "return inferenceReservation{}, membership.ErrConflict",
            "a later regrant must not revive it",
            "set state='invalidated'",
        ):
            self.assertIn(needle, request)

        runtime = read("server/internal/service/training_runtime.go")
        self.assertIn("Summary: s.Profiles.ForModel", runtime)
        store = read("server/internal/training/store.go")
        allowed = store.split("func (s *Service) allowed(", 1)[1].split("\nfunc ", 1)[0]
        self.assertRegex(
            allowed,
            re.compile(
                r'if s\.Summary != nil \{.*?'
                r'accounts\.Granted\(ctx, tx, u, "contacts"\).*?'
                r'membership\.ErrForbidden.*?\}\s*\}'
                r'\s+return s\.Rights\.RequireContact\(ctx, tx, u, in\.Contact\)',
                re.S,
            ),
        )

    def test_profile_inventory_docs_distinguish_feedback_from_model_material(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        d14 = re.search(r"^\| D14 \|.*$", inventory, re.M)
        d39 = re.search(r"^\| D39 \|.*$", inventory, re.M)
        d40 = re.search(r"^\| D40 \|.*$", inventory, re.M)
        self.assertIsNotNone(d14, "data-inventory.md must have D14")
        self.assertIsNotNone(d39, "data-inventory.md must have D39")
        self.assertIsNotNone(d40, "data-inventory.md must have D40")

        d14_text = d14.group(0)
        for phrase in (
            "profile_observations.fact_enc",
            "用户明确反馈",
            "不是模型推断",
            "contacts.profile_enc",
            "七个有界选项",
            "随活动、信号事件或账号",
        ):
            self.assertIn(phrase, d14_text)

        self.assertIn("关联关系人时检查 `contacts`", d14_text)
        self.assertIn("`health` 与 `voice`", d14_text)
        self.assertIn("仅导入聊天做推断时另需 `chat_import`", inventory)
        d39_text = d39.group(0)
        self.assertIn("仅回复或复盘的本人反馈", d39_text)
        self.assertIn("不单列 D39", d39_text)
        for phrase in (
            "activity_profile_context.context_enc",
            "冻结来源活动场景",
            "已验证的 null",
            "ON DELETE CASCADE",
            "42",
            "T25 后端增量",
        ):
            self.assertIn(phrase, d39_text)

        d40_text = d40.group(0)
        self.assertIn("不输出 D40 请求、同意 ID 或输入摘要", d40_text)
        self.assertIn("不改写原记录", d40_text)
        for phrase in (
            "profile_inference_requests",
            "chat_consent_id",
            "contacts_consent_id",
            "32 字节 SHA-256",
            "processing",
            "complete",
            "invalidated",
            "撤回/重授权",
            "不复活",
            "ON DELETE CASCADE",
            "501 not_implemented",
            "T35",
            "42",
        ):
            self.assertIn(phrase, d40_text)

        # The supplier register identifies the prompt/evidence, while user-facing
        # material explains consent and retention without copying internal IDs.
        self.assertIn(self.PROMPT_ID, read("docs/compliance/sdk-model-review-checklist.md"))
        self.assertIn("供应商", read("docs/compliance/privacy-policy-draft.md"))
        self.assertIn("T25", read("docs/compliance/qa.md"))

    def test_profile_delete_is_internal_and_public_rights_stay_not_implemented(self) -> None:
        profile_http = read("server/internal/service/profile_http.go")
        self.assertIn('Scope: "contacts"', profile_http)
        self.assertIn("a.profiles.Data.Delete", profile_http)

        http = read("server/internal/service/http.go")
        routes = re.search(r"var accountRoutes = map\[string\]bool\{(.*?)\n\}", http, re.S)
        self.assertIsNotNone(routes)
        route_block = routes.group(1)
        self.assertIn('"DELETE /v1/contacts/:id": false', route_block)
        self.assertNotIn("GET /v1/me/export", route_block)
        self.assertNotIn("DELETE /v1/me/data/:kind/:id", route_block)
        self.assertIn('problem(c, 501, "not_implemented"', http)

        inventory = read("docs/compliance/data-inventory.md")
        self.assertIn("D01–D42", inventory)
        self.assertRegex(inventory, r"模块内部导出/删除[^\n]*不等于[^\n]*T35")
        self.assertRegex(inventory, r"D37[^\n]*D39[^\n]*D40[^\n]*D41[^\n]*D42[^\n]*不计入")
        self.assertIn("chat_imports", inventory)
        self.assertRegex(inventory, r"chat_imports[^\n]*24 小时[^\n]*(?:待实现/验收|待验收)")

        qa = read("docs/compliance/qa.md")
        t33 = read("docs/tasks/T33.md")
        evidence = qa + "\n" + t33
        for needle in (
            "TestProfileLifecycle",
            "TestProfileInferenceReviewRegressions",
            "TestPracticeWire",
            "TestProfileReviewSourceLifecycle",
            "work",
            "null_scene",
            "build/t25/with-practice/live.log",
            "build/t25/joint-review-live.log",
            "本批后端实现不等于生产上线。",
        ):
            self.assertIn(needle, evidence)
        self.assertRegex(evidence, r"真实模型[^\n]*(?:不替代|不代表|仍待)")


class SharingHandoffContract(unittest.TestCase):
    def test_share_claim_does_not_imply_permission_to_show_text(self) -> None:
        for name in ("data-inventory.md", "privacy-policy-draft.md", "separate-consents.md"):
            text = (Path(__file__).resolve().parent / name).read_text()
            with self.subTest(name=name):
                self.assertIn("领取不要求已登录", text)
                self.assertIn("未登录时不显示正文", text)
                self.assertIn("登录后才可查看或编辑", text)
                self.assertNotIn("登录后打开「对话手记」", text)
                self.assertNotIn("登录并打开「对话手记」领取", text)

    def test_t22_share_handoff_platform_storage_is_not_flattened(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        privacy = read("docs/compliance/privacy-policy-draft.md")
        separate = read("docs/compliance/separate-consents.md")

        d37 = re.search(r"^\| D37 \|.*$", inventory, re.M)
        privacy_section = re.search(r"## 7\. 回复助手和聊天导入.*?(?=\n## 8\.)", privacy, re.S)
        c08 = re.search(r"### C08 回复助手聊天导入.*?(?=\n### C09)", separate, re.S)
        self.assertIsNotNone(d37, "data-inventory.md must have a D37 sharing-handoff row")
        self.assertIsNotNone(privacy_section, "privacy policy must describe sharing in section 7")
        self.assertIsNotNone(c08, "separate consent C08 must describe sharing handoff")

        sections = {
            "data-inventory.md D37": d37.group(0),
            "privacy-policy-draft.md section 7": privacy_section.group(0),
            "separate-consents.md C08": c08.group(0),
        }
        required = (
            "bc66e6e",
            "Android",
            "一次性内存",
            "iOS",
            "App Group",
            "Library/Caches/T22/incoming",
            "系统完整文件保护",
            "不是业务 AES-GCM",
            "写入",
            "替换",
            "领取",
            "清理",
            "10 分钟",
            "拒领",
            "不保证到点物理擦除",
            "开始分析",
            "未分析不上传",
            "提交前不上传",
            "T21",
            "后端增量",
            "服务端不持久化源文本与目的",
        )
        for name, section in sections.items():
            for phrase in required:
                self.assertIn(phrase, section, f"{name}: missing {phrase}")

        combined = "\n".join(sections.values())
        self.assertNotRegex(combined, r"(?:Android\s*(?:和|与|、)\s*iOS|两平台|均|都)[^\n]{0,80}不落盘")



class Pg17InventoryCoverageContract(unittest.TestCase):
    GAP_OBJECTS = (
        "admin_accounts",
        "admin_audit_logs",
        "admin_sessions",
        "erasure_roots_before_emotion",
        "gateway_revision",
        "prompt_releases",
        "quota_attempts",
    )

    def test_pg17_gap_objects_are_explicitly_inventoried(self) -> None:
        inventory = read("docs/compliance/data-inventory.md")
        rows = [line for line in inventory.splitlines() if line.startswith("| D")]
        rows_by_name = {
            name: next((row for row in rows if name in row), None)
            for name in self.GAP_OBJECTS
        }
        missing = [name for name, row in rows_by_name.items() if row is None]
        self.assertEqual(missing, [], f"missing inventory rows: {missing}")

        admin_row = rows_by_name["admin_accounts"]
        self.assertIsNotNone(admin_row)
        for name in ("admin_accounts", "admin_audit_logs", "admin_sessions"):
            self.assertEqual(rows_by_name[name], admin_row, name)
            self.assertIn(name, admin_row)
        self.assertIn("覆盖 42/42", inventory)
        self.assertIn("后台员工数据", admin_row)
        self.assertRegex(admin_row, r"password_hash.*token_hash.*不进入 App 用户导出")
        for column in (
            "id",
            "login",
            "password_hash",
            "role",
            "token_hash",
            "admin_id",
            "expires_at",
            "occurred_at",
            "actor_id",
            "action",
            "target",
            "result",
        ):
            self.assertIn(column, admin_row)

        view_row = rows_by_name["erasure_roots_before_emotion"]
        self.assertIsNotNone(view_row)
        for phrase in (
            "查询视图",
            "不是物理副本",
            "不另存个人数据",
            "user_id",
            "scope",
            "root_id",
            "parent_id",
        ):
            self.assertIn(phrase, view_row)

        gateway_row = rows_by_name["gateway_revision"]
        self.assertIsNotNone(gateway_row)
        for phrase in ("平台配置", "不进入 App 用户导出", "singleton", "version"):
            self.assertIn(phrase, gateway_row)

        prompt_row = rows_by_name["prompt_releases"]
        self.assertIsNotNone(prompt_row)
        for phrase in (
            "平台配置",
            "不进入 App 用户导出",
            "task",
            "model_id",
            "model_kind",
            "primary_version_id",
            "experiment_version_id",
            "experiment_percent",
        ):
            self.assertIn(phrase, prompt_row)

        quota_row = rows_by_name["quota_attempts"]
        self.assertIsNotNone(quota_row)
        for phrase in (
            "原时区自然日",
            "valid_until",
            "重连/重试",
            "随活动/账号级联",
            "不导出内部令牌",
            "activity_id",
            "token",
            "state",
            "held_day",
            "metered",
        ):
            self.assertIn(phrase, quota_row)

        admin_sql = read("server/migrations/20261121193013_admin_security.up.sql")
        self.assertIn("REFERENCES admin_accounts ON DELETE CASCADE", admin_sql)
        roots_sql = read("server/migrations/20261121233030_emotion_roots.up.sql")
        self.assertIn(
            "ALTER VIEW erasure_roots RENAME TO erasure_roots_before_emotion",
            roots_sql,
        )
        self.assertIn("SELECT * FROM erasure_roots_before_emotion UNION ALL", roots_sql)
        gateway_sql = read("server/migrations/20261121000600_gateway_admission.up.sql")
        self.assertIn("CREATE TABLE gateway_revision", gateway_sql)
        route_sql = read("server/migrations/20261121200010_task_routing.up.sql")
        self.assertIn("ON model_routes", route_sql)
        prompts_sql = read("server/migrations/20261121210011_prompt_releases.up.sql")
        self.assertIn("CREATE TABLE prompt_releases", prompts_sql)
        self.assertIn("REFERENCES model_configs(id,kind)", prompts_sql)
        self.assertIn("REFERENCES prompt_versions(task,id)", prompts_sql)
        quota_sql = read("server/migrations/20261121203006_quota_attempts.up.sql")
        self.assertIn("REFERENCES activities ON DELETE CASCADE", quota_sql)


class ConsentAndSourceRegisterContract(unittest.TestCase):
    def test_c05_is_an_actionable_microphone_prompt_draft(self) -> None:
        text = read("docs/compliance/separate-consents.md")
        section = re.search(r"### C05 .*?(?=\n### C06)", text, re.S)
        self.assertIsNotNone(section)
        c05 = section.group(0)
        required = (
            r"必要性",
            r"(?:触发时机|申请.*前|开启.*前)",
            r"本机",
            r"30 秒聚合",
            r"(?:不上传|不会上传).*(?:音频|转写)",
            r"混入他人",
            r"(?:拒绝|撤回).*(?:后果|影响|停止)",
            r"待 T29 对表",
        )
        for pattern in required:
            self.assertRegex(c05, pattern)

    def test_official_source_register_contains_verified_primary_evidence(self) -> None:
        register = read("docs/compliance/official-source-register.md")
        self.assertNotRegex(register, r"(?:9 个|九个).*(?:DNS|HTTP|不可达|未取得)")
        self.assertNotRegex(register, r"全部.*(?:DNS|未取得正文)")
        for url in (
            "https://www.cac.gov.cn/2021-08/20/c_1631050028355286.htm",
            "https://www.cac.gov.cn/2023-07/13/c_1690898327029107.htm",
            "https://developer.apple.com/app-store/review/guidelines/",
            "https://developer.android.com/health-and-fitness/health-connect/get-started",
            "https://www.gov.cn/zhengce/zhengceku/202308/content_6897341.htm",
        ):
            self.assertIn(url, register)
        self.assertIn(
            "50b62bb9868648fe0417d8757a8cff62641eba6d879403f363d771f8c6d3acff",
            register,
        )
        self.assertIn(
            "7fae988c064dde72c95e96e5727bf9abee4b3a5a1ea817606a9ca1f97ffac54b",
            register,
        )
        self.assertRegex(register, r"已读取官方正文")
        self.assertRegex(register, r"律师.*适用性")


if __name__ == "__main__":
    unittest.main(verbosity=2)
