"""Offline receipt regressions using the T27 command-line boundaries."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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
    def check_cli(self, mode, output, child_exit, status, exit_code):
        with tempfile.TemporaryDirectory() as directory:
            github_output = Path(directory) / "github-output"
            result = subprocess.run(
                [sys.executable, str(CI), mode, sys.executable, "-c",
                 f"print({output!r}); raise SystemExit({child_exit})"],
                env={**os.environ, "GITHUB_OUTPUT": str(github_output)},
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, exit_code, result.stderr)
            self.assertTrue(github_output.exists(), result.stderr)
            self.assertEqual(github_output.read_text(), f"receipt={status}\n")
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
        self.check_cli("history", PRIVATE, 0, "FAIL", 1)
        self.check_cli("history", PRIVATE, 1, "FAIL", 1)
        self.check_cli("history", PRIVATE, 2, "NOT RUN", 2)
        self.check_cli("history", PRIVATE, 3, "SKIPPED", 3)


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
        with self.assertRaises(history_journey.NotRun):
            self.run_go_transcript("testing: warning: no tests to run")
        with self.assertRaises(history_journey.Failed):
            self.run_go_transcript(self.transcript(), status=1)

    def test_go_skip_is_distinct_from_an_unentered_journey(self):
        with self.assertRaises(history_journey.Skipped):
            self.run_go_transcript("--- SKIP: TestT27HistoryJourney (0.00s)")


if __name__ == "__main__":
    unittest.main()
