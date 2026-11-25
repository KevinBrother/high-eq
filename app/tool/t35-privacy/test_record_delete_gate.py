"""Check the selected-record runner's private receipt lifecycle."""

import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

import record_delete_journey as journey


class RecordDeleteGateTest(unittest.TestCase):
    def test_default_receipts_exist_during_journey_and_are_removed_on_exit(self):
        for fail in (False, True):
            with self.subTest(fail=fail), TemporaryDirectory() as temp:
                states = []

                def run_services(_args, state, _logs, env, *, run_journey):
                    states.append(state)
                    receipts = Path(env["T35_RECORD_EXPORT_RECEIPT_DIR"])
                    self.assertEqual(receipts.parent, state)
                    self.assertEqual(receipts.stat().st_mode & 0o777, 0o700)
                    (receipts / "synthetic.zip").write_bytes(b"private")
                    self.assertIs(run_journey, journey.run_delete_test)
                    if fail:
                        raise journey.native.Failed("synthetic failure")

                args = ["record_delete_journey.py", "--pg-bin", temp, "--redis", temp]
                with (
                    patch.object(sys, "argv", args),
                    patch.object(journey.signal, "signal"),
                    patch.object(journey.os, "umask"),
                    patch.object(journey.native, "run_services", side_effect=run_services),
                    patch("builtins.print") as messages,
                ):
                    if fail:
                        with self.assertRaises(journey.native.Failed):
                            journey.main()
                        messages.assert_not_called()
                    else:
                        journey.main()
                        messages.assert_called_once_with("T35_RECORD_RESULT=PASS", flush=True)
                self.assertEqual(len(states), 1)
                self.assertFalse(states[0].exists())

    def test_failed_go_diagnostics_stay_in_private_receipts(self):
        with TemporaryDirectory() as temp:
            directory = Path(temp)
            log = directory / "raw.jsonl"
            private = "selected-record synthetic-private-output-must-not-escape"

            def spawn(_stack, _args, _env, logfile):
                event = {
                    "Action": "output", "Package": journey.PACKAGE, "Test": journey.TEST,
                    "Output": private,
                }
                logfile.write_text(json.dumps(event), encoding="utf-8")
                command.return_value.wait.return_value = 1
                return command.return_value

            with (
                patch.object(journey.native, "spawn", side_effect=spawn) as command,
                patch("builtins.print") as messages,
                self.assertRaises(journey.native.Failed),
            ):
                journey.run_delete_test("go", {"T35_RECORD_EXPORT_RECEIPT_DIR": temp}, log)
            messages.assert_not_called()
            self.assertEqual((directory / "go.test.log").read_bytes(), log.read_bytes())
