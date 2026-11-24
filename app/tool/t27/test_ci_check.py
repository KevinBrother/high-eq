"""Offline receipt regressions using the T27 command-line boundaries."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import history_journey


CI = Path(__file__).with_name("ci_check.py")
CLIENT_TEST = "提交后丢回执，列表即使已空仍可只读核对并重建离线成长"
PRIVATE = "synthetic-private-value"
GO_PASSES = (
    "service.runtime", "service.seed", "service.order-and-cursor",
    "service.reference-before", "service.contact-summary-before",
    "page.runner", "service.delete-cascade", "service.contact-summary-after",
    "journey",
)
FLUTTER_PASSES = (
    "page.fixture", "page.lobby-order-and-back", "page.growth-history",
    "page.offline-without-deletion", "page.contact-deleted", "page.deleted-cache",
    "page.growth-recovery", "page.account-isolation", "page.journey",
)


def flutter_test(name, *, skipped=False, result="success", hidden=False):
    return [
        {"type": "testStart", "test": {"id": 1, "name": name}},
        {"type": "testDone", "testID": 1, "result": result,
         "skipped": skipped, "hidden": hidden},
        {"type": "done", "success": result == "success"},
    ]


class CiReceiptTests(unittest.TestCase):
    def check_cli(self, mode, output, child_exit, status, exit_code, stage=None):
        with tempfile.TemporaryDirectory() as directory:
            github_output = Path(directory) / "github-output"
            result = subprocess.run(
                [sys.executable, "-B", str(CI), mode, sys.executable, "-c",
                 f"print({output!r}); raise SystemExit({child_exit})"],
                env={**os.environ, "GITHUB_OUTPUT": str(github_output)},
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, exit_code, result.stderr)
            self.assertTrue(github_output.exists(), result.stderr)
            expected = f"receipt={status}\n"
            if stage is not None:
                expected += f"stage={stage}\n"
                self.assertEqual(result.stdout, f"{status}\nStage: {stage}\n")
            self.assertEqual(github_output.read_text(), expected)
            self.assertNotIn(PRIVATE, result.stdout + result.stderr)

    def check_flutter(self, events, child_exit, status, exit_code, mode="client"):
        raw = "\n".join([PRIVATE, *(json.dumps(event) for event in events)])
        self.check_cli(mode, raw, child_exit, status, exit_code)

    def test_contact_recovery_requires_its_own_pass(self):
        self.check_flutter(flutter_test(CLIENT_TEST), 0, "PASS", 0)
        self.check_flutter(flutter_test("another test"), 0, "NOT RUN", 2)

    def test_contact_recovery_distinguishes_skip_and_failure(self):
        self.check_flutter(flutter_test(CLIENT_TEST, skipped=True), 0, "SKIPPED", 3)
        self.check_flutter(flutter_test(CLIENT_TEST, result="failure"), 1, "FAIL", 1)

    def test_flutter_hidden_loader_and_incomplete_stream_do_not_pass(self):
        self.check_flutter(flutter_test(CLIENT_TEST, hidden=True), 0, "NOT RUN", 2)
        self.check_flutter(flutter_test(CLIENT_TEST)[:-1], 0, "FAIL", 1)

    def test_flutter_crash_after_entering_required_test_fails(self):
        self.check_flutter(flutter_test(CLIENT_TEST)[:1], 1, "FAIL", 1)

    def test_legacy_requires_the_actual_live_test(self):
        name = "real T27 app ↔ T26 HTTP: assessment, first plan, completion and reopen"
        self.check_flutter(flutter_test(name), 0, "PASS", 0, mode="legacy")
        self.check_flutter(flutter_test(name, skipped=True), 0, "SKIPPED", 3, mode="legacy")
        self.check_flutter([], 1, "NOT RUN", 2, mode="legacy")

    def test_history_cli_requires_success_receipt_and_preserves_exit_categories(self):
        self.check_cli("history", f"{PRIVATE}\nRESULT: PASS", 0, "PASS", 0)
        self.check_cli("history", PRIVATE, 0, "FAIL", 1, "unknown")
        self.check_cli("history", PRIVATE, 1, "FAIL", 1, "unknown")
        self.check_cli("history", PRIVATE, 2, "NOT RUN", 2, "unknown")
        self.check_cli("history", PRIVATE, 3, "SKIPPED", 3, "unknown")

    def test_history_cli_exports_a_fixed_stage_and_omits_child_diagnostics(self):
        self.check_cli("history", f"NOT RUN(prerequisite): {PRIVATE}\n"
                       "T27_HISTORY_STAGE=redis.cache-startup", 2, "NOT RUN", 2,
                       "redis.cache-startup")
        self.check_cli("history", f"FAIL(page.growth-history): {PRIVATE}\n"
                       "T27_HISTORY_STAGE=page.growth-history", 1, "FAIL", 1,
                       "page.growth-history")
        self.check_cli("history", "T27_HISTORY_STAGE=postgres.initdb\nRESULT: PASS",
                       0, "PASS", 0)
        self.check_cli("history", "T27_HISTORY_STAGE=go.startup\nRESULT: PASS",
                       2, "NOT RUN", 2, "go.startup")

    def test_ledger_durability_failure_is_a_fixed_prerequisite(self):
        self.check_cli("history", f"NOT RUN(redis.ledger-durability): {PRIVATE}\n"
                       "T27_HISTORY_STAGE=redis.ledger-durability", 2, "NOT RUN", 2,
                       "redis.ledger-durability")

    def test_contact_delete_failure_exposes_only_fixed_http_evidence(self):
        stage = "T27_HISTORY_STAGE=page.contact-deleted"
        ack = "OBSERVED(page.delete-ack): DELETE returned 200 with ok=true"
        for receipts, expected in (
            (ack, "acknowledged"),
            ("OBSERVED(page.delete-http): 500", "http-500"),
            ("OBSERVED(page.delete-http): 503", "http-503"),
            ("OBSERVED(page.delete-http): 403", "http-403"),
            ("OBSERVED(page.delete-http): unacknowledged", "unacknowledged"),
            (f"{ack} {PRIVATE}", "unobserved"),
            (f"{ack}\n{ack}", "multiple"),
        ):
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                github_output = Path(directory) / "github-output"
                raw = f"{PRIVATE}\n{receipts}\n{stage}"
                result = subprocess.run(
                    [sys.executable, "-B", str(CI), "history", sys.executable, "-c",
                     f"print({raw!r}); raise SystemExit(1)"],
                    env={**os.environ, "GITHUB_OUTPUT": str(github_output)},
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout, f"FAIL\nStage: page.contact-deleted\nDelete HTTP: {expected}\n")
                self.assertEqual(result.stderr, "")
                self.assertEqual(github_output.read_text(),
                                 f"receipt=FAIL\nstage=page.contact-deleted\ndelete_http={expected}\n")

    def test_history_cli_rejects_unknown_decorated_and_multiple_stage_receipts(self):
        for output in (f"T27_HISTORY_STAGE={PRIVATE}",
                       f"T27_HISTORY_STAGE=postgres.initdb {PRIVATE}",
                       "prefix T27_HISTORY_STAGE=postgres.initdb",
                       "T27_HISTORY_STAGE=postgres.initdb\nT27_HISTORY_STAGE=redis.cache-startup"):
            with self.subTest(output=output):
                self.check_cli("history", output, 2, "NOT RUN", 2, "unknown")


class HistoryPrerequisiteTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root / "server").mkdir()
        patcher = patch.object(history_journey, "ROOT", self.root)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tool(self, name, command):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"#!/bin/sh\n{command}\n")
        path.chmod(0o700)
        return path

    def setup_tools(self):
        postgres = self.tool("pg17/postgres", "echo 'postgres (PostgreSQL) 17.9'")
        self.tool("pg17/initdb", "exit 0")
        go = self.tool("go", "echo 'go version go1.26.0 linux/amd64'")
        redis = self.tool("redis-server", "exit 0")
        sdk_flutter = self.tool("sdk/bin/flutter", "exit 0")
        flutter = self.root / "flutter"
        flutter.symlink_to(sdk_flutter)
        self.tool("sdk/bin/cache/dart-sdk/bin/dart", "exit 0")
        (self.root / "sdk/bin/cache/flutter_tools.snapshot").touch()
        packages = self.root / "app/.dart_tool"
        packages.mkdir(parents=True)
        for name in ("package_config.json", "package_graph.json"):
            (packages / name).touch()
        return SimpleNamespace(pg_bin=postgres.parent, redis=redis, go=go, flutter=flutter)

    def test_redis_multicall_executable_keeps_its_invocation_name(self):
        binary = self.tool("redis-check-rdb", '[ "${0##*/}" = redis-server ] || exit 2')
        redis = binary.with_name("redis-server")
        redis.symlink_to(binary.name)

        invocation = history_journey.executable(redis, "redis-server")
        result = subprocess.run([invocation, "-"], check=False)
        self.assertEqual(result.returncode, 0, invocation)

    def test_flutter_link_locates_sdk_cache_and_reports_missing_snapshot(self):
        args = self.setup_tools()
        directory_alias = self.root / "tmp-alias"
        directory_alias.symlink_to(".", target_is_directory=True)
        args.flutter = directory_alias / "flutter"
        sdk_root = (directory_alias / "sdk").resolve(strict=True)
        env = {}
        *_, dart, snapshot = history_journey.setup(args, env)
        self.assertEqual(env["FLUTTER_ROOT"], str(sdk_root))
        self.assertEqual(dart, sdk_root / "bin/cache/dart-sdk/bin/dart")
        self.assertEqual(snapshot, sdk_root / "bin/cache/flutter_tools.snapshot")
        snapshot.unlink()
        with self.assertRaises(history_journey.NotRun) as failure:
            history_journey.setup(args, {})
        self.assertEqual(failure.exception.stage, "flutter.sdk-cache")

    def test_postgres_version_rejects_a_non_17_binary(self):
        args = self.setup_tools()
        self.tool("pg17/postgres", "echo 'postgres (PostgreSQL) 16.9'")
        with self.assertRaises(history_journey.NotRun) as failure:
            history_journey.setup(args, {})
        self.assertEqual(failure.exception.stage, "postgres.version")

    def test_owned_startup_failures_identify_initdb_postgres_and_each_redis(self):
        args = self.setup_tools()
        pg_version = 'if [ "$1" = --version ]; then echo "postgres (PostgreSQL) 17.9"; exit; fi\n'
        ready_pg = pg_version + 'echo "database system is ready to accept connections"\nexec sleep 30'
        ready_cache_only = ('while IFS= read -r line; do\n'
                            '  case "$line" in "appendonly yes") exit 2;; esac\n'
                            'done\necho "Ready to accept connections"\nexec sleep 30')
        cases = (
            ("postgres.initdb", "exit 2", ready_pg, "exit 2"),
            ("postgres.startup", "exit 0", pg_version + "exit 2", "exit 2"),
            ("redis.cache-startup", "exit 0", ready_pg, "exit 2"),
            ("redis.ledger-startup", "exit 0", ready_pg, ready_cache_only),
        )
        for stage, initdb, postgres, redis in cases:
            with self.subTest(stage=stage), tempfile.TemporaryDirectory(dir=self.root) as directory:
                self.tool("pg17/initdb", initdb)
                self.tool("pg17/postgres", postgres)
                self.tool("redis-server", redis)
                listeners = [SimpleNamespace(getsockname=lambda port=port: ("127.0.0.1", port),
                                             close=lambda: None) for port in (10001, 10002, 10003)]
                state = Path(directory)
                with (
                    patch.object(history_journey, "reserve", side_effect=listeners),
                    redirect_stdout(io.StringIO()),
                    self.assertRaises(history_journey.NotRun) as failure,
                ):
                    history_journey.run_services(args, state, state, {"PATH": os.defpath})
                self.assertEqual(failure.exception.stage, stage)
                self.assertFalse((state / "initdb-password").exists())

    def test_owned_ledger_must_acknowledge_disk_before_go_starts(self):
        args = self.setup_tools()
        self.tool("pg17/postgres", 'if [ "$1" = --version ]; then echo "postgres (PostgreSQL) 17.9"; exit; fi\n'
                  'echo "database system is ready to accept connections"\nexec sleep 30')
        self.tool("redis-server", 'echo "Ready to accept connections"\nexec sleep 30')
        listeners = [SimpleNamespace(getsockname=lambda port=port: ("127.0.0.1", port),
                                     close=lambda: None) for port in (10001, 10002, 10003)]
        with (
            tempfile.TemporaryDirectory(dir=self.root) as directory,
            patch.object(history_journey, "reserve", side_effect=listeners),
            patch.object(history_journey.socket, "create_connection") as connect,
            patch.object(history_journey, "run_test") as go_test,
            redirect_stdout(io.StringIO()),
        ):
            state = Path(directory)
            connection = connect.return_value.__enter__.return_value
            connection.makefile.return_value.__enter__.return_value = io.BytesIO(
                b"+OK\r\n+OK\r\n-ERR unknown command 'WAITAOF'\r\n"
            )
            with self.assertRaises(history_journey.NotRun) as failure:
                history_journey.run_services(args, state, state, {"PATH": os.defpath})
            self.assertEqual(failure.exception.stage, "redis.ledger-durability")
            connect.assert_called_once_with(("127.0.0.1", 10003), timeout=5)
            go_test.assert_not_called()

    def test_launcher_reports_missing_postgres_stage_through_ci(self):
        launcher = self.root / "app/tool/t27/history_journey.py"
        launcher.parent.mkdir(parents=True)
        shutil.copyfile(history_journey.__file__, launcher)
        github_output = self.root / "github-output"
        result = subprocess.run(
            [sys.executable, "-B", str(CI), "history", sys.executable, str(launcher),
             "--pg-bin", str(self.root / PRIVATE), "--redis", str(self.root / "redis-server")],
            env={**os.environ, "GITHUB_OUTPUT": str(github_output)},
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "NOT RUN\nStage: postgres.binary\n")
        self.assertEqual(result.stderr, "")
        self.assertEqual(github_output.read_text(), "receipt=NOT RUN\nstage=postgres.binary\n")


class LedgerDurabilityTests(unittest.TestCase):
    def check_responses(self, durability_reply, *, cleanup_reply=b":1\r\n"):
        with patch.object(history_journey.socket, "create_connection") as connect:
            connection = connect.return_value.__enter__.return_value
            connection.makefile.return_value.__enter__.return_value = io.BytesIO(
                b"+OK\r\n+OK\r\n" + durability_reply + cleanup_reply
            )
            with redirect_stdout(io.StringIO()) as receipt:
                try:
                    history_journey.verify_ledger(12345, "synthetic-secret")
                    stage = None
                except history_journey.NotRun as error:
                    stage = error.stage
            connect.assert_called_once_with(("127.0.0.1", 12345), timeout=5)
            sent = [call.args[0] for call in connection.sendall.call_args_list]
        self.assertEqual(sent[:3], [
            b"*2\r\n$4\r\nAUTH\r\n$16\r\nsynthetic-secret\r\n",
            b"*3\r\n$3\r\nSET\r\n$20\r\nt27:durability-probe\r\n$1\r\n1\r\n",
            b"*4\r\n$7\r\nWAITAOF\r\n$1\r\n1\r\n$1\r\n0\r\n$4\r\n3000\r\n",
        ])
        return stage, receipt.getvalue(), sent[3:]

    def test_same_connection_requires_local_fsync_then_removes_probe_key(self):
        stage, receipt, remaining = self.check_responses(b"*2\r\n:1\r\n:0\r\n")
        self.assertIsNone(stage)
        self.assertEqual(receipt, "PASS(redis.ledger-durability)\n")
        self.assertEqual(remaining, [b"*2\r\n$3\r\nDEL\r\n$20\r\nt27:durability-probe\r\n"])

    def test_no_fsync_or_wrong_reply_is_rejected_without_retry(self):
        for reply in (b"*2\r\n:0\r\n:0\r\n", b"+OK\r\n", b"*1\r\n:1\r\n"):
            with self.subTest(reply=reply):
                self.assertEqual(self.check_responses(reply), ("redis.ledger-durability", "", []))

    def test_probe_must_be_removed_before_returning_a_pass(self):
        stage, receipt, sent = self.check_responses(b"*2\r\n:1\r\n:0\r\n", cleanup_reply=b":0\r\n")
        self.assertEqual(stage, "redis.ledger-durability")
        self.assertEqual(receipt, "")
        self.assertEqual(len(sent), 1)


class HistoryReceiptTests(unittest.TestCase):
    def run_go_transcript(self, transcript, status=0):
        with tempfile.TemporaryDirectory() as directory, redirect_stdout(io.StringIO()) as output:
            root = Path(directory)
            go = root / "go"
            go.write_text(f"#!{sys.executable}\nprint({transcript!r})\nraise SystemExit({status})\n")
            go.chmod(0o700)
            history_journey.run_test(go, os.environ.copy(), root / "journey.log")
            return output.getvalue()

    def transcript(self, omitted=None):
        return "\n".join([
            "=== RUN   TestT27HistoryJourney",
            "    growth_history_journey_integration_test.go:44: BEGIN(service.runtime)",
            *(f"    growth_history_journey_integration_test.go:58: PASS({phase})"
              for phase in GO_PASSES if phase != omitted),
            *(f"PASS({phase})" for phase in FLUTTER_PASSES if phase != omitted),
            "--- PASS: TestT27HistoryJourney (1.00s)",
        ])

    def test_full_history_receipt_passes(self):
        self.assertIn("RESULT: PASS", self.run_go_transcript(self.transcript()))

    def test_each_missing_summary_or_history_stage_fails(self):
        for phase in ("service.contact-summary-before", "service.contact-summary-after",
                      "service.order-and-cursor", "page.growth-history", "page.growth-recovery"):
            with self.subTest(phase=phase), self.assertRaisesRegex(history_journey.Failed, phase):
                self.run_go_transcript(self.transcript(omitted=phase))

    def test_diagnostic_text_ending_in_pass_is_not_a_stage_receipt(self):
        phase = "service.delete-cascade"
        output = self.transcript(omitted=phase) + f"\nserver diagnostic quotes PASS({phase})"
        with self.assertRaisesRegex(history_journey.Failed, phase):
            self.run_go_transcript(output)

    def test_unentered_journey_and_failing_journey_exit_differ(self):
        with self.assertRaises(history_journey.NotRun) as failure:
            self.run_go_transcript("testing: warning: no tests to run")
        self.assertEqual(failure.exception.stage, "go.startup")
        with self.assertRaises(history_journey.Failed):
            self.run_go_transcript(self.transcript(), status=1)

    def test_entered_journey_reports_widget_startup_or_the_first_failed_phase(self):
        entered = "    growth_history_journey_integration_test.go:44: BEGIN(service.runtime)\n"
        with self.assertRaises(history_journey.NotRun) as failure:
            self.run_go_transcript(entered + "    journey.go:305: NOT RUN(page.startup): missing widget", status=1)
        self.assertEqual(failure.exception.stage, "page.startup")

        with self.assertRaises(history_journey.Failed) as failure:
            self.run_go_transcript(entered + f"FAIL(page.growth-history) after 3ms: {PRIVATE}\n"
                                   "    journey.go:101: FAIL(page.runner): exit status 1", status=1)
        self.assertEqual(failure.exception.stage, "page.growth-history")

    def test_go_skip_is_distinct_from_an_unentered_journey(self):
        with self.assertRaises(history_journey.Skipped):
            self.run_go_transcript("--- SKIP: TestT27HistoryJourney (0.00s)")


if __name__ == "__main__":
    unittest.main()
