"""The real-export gate requires the named test and every journey phase."""

import json
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from pathlib import Path
from unittest.mock import patch

from export_journey import run_export_test
from history_journey import Failed


PACKAGE = "high-eq/server/internal/service"
TEST = "TestT35FormalAccountExportJourney"
PRIVATE = "synthetic-private-output-must-not-escape"
PHASES = (
    "service.runtime", "service.seed",
    "page.account-a.before", "page.account-a.delete", "page.account-a.after",
    "page.account-b.before", "page.account-b.after",
    "receive.wire-and-inventory", "receive.selected-mark-diff",
    "receive.account-isolation",
)


class ExportGateTest(unittest.TestCase):
    def run_result(self, *, phases=PHASES, result="pass", package="pass", exit_code=0):
        def event(action, name=TEST, **extra):
            return {"Action": action, "Package": PACKAGE,
                    **({"Test": name} if name else {}), **extra}

        events = [event("output", Output=PRIVATE + "\n")]
        events.extend(event("output", Output=f"    fixture.go:15: PASS({phase})\n")
                      for phase in phases)
        if result:
            events.append(event(result))
        events.extend((event("pass", name=TEST+"/unrelated"), event(package, name=None)))
        payload = "\n".join(map(json.dumps, events))
        with (
            patch("export_journey.native.spawn") as command,
            patch("builtins.print") as messages,
        ):
            def write_receipt(_stack, args, _env, log):
                self.assertIn("-json", args)
                self.assertIn(f"^{TEST}$", args)
                log.write_text(payload, encoding="utf-8")
                command.return_value.wait.return_value = exit_code
                return command.return_value

            command.side_effect = write_receipt
            with TemporaryDirectory() as temp:
                log = Path(temp) / "result.jsonl"
                if (phases, result, package, exit_code) == (PHASES, "pass", "pass", 0):
                    run_export_test(Path(sys.executable), {}, log)
                    for phase in PHASES:
                        self.assertIn(f"PASS({phase})", str(messages.call_args_list))
                else:
                    with self.assertRaises(Failed):
                        run_export_test(Path(sys.executable), {}, log)
                self.assertNotIn(PRIVATE, str(messages.call_args_list))

    def test_requires_every_phase_and_exact_successful_exit(self):
        for case in ({}, {"phases": PHASES[:-1]}, {"phases": PHASES[::-1]},
                     {"phases": PHASES + (PHASES[-1],)}, {"result": "skip"},
                     {"result": None}, {"package": "fail"}, {"exit_code": 1}):
            with self.subTest(case=case):
                self.run_result(**case)

    def test_missing_provisioning_is_not_green(self):
        with TemporaryDirectory() as temp:
            runner = Path(__file__).with_name("export_journey.py")
            result = subprocess.run([
                sys.executable, "-B", str(runner), "--pg-bin", temp,
                "--redis", str(Path(temp) / "redis-server"),
            ], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr.strip(), "NOT RUN(postgres.binary)")
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
