#!/usr/bin/env python3
"""Offline regression tests for the exact top-level go test result parser."""

from __future__ import annotations

import io
import json
import unittest
from pathlib import Path

import t19_wire_result


PACKAGE = "high-eq/server/internal/service"
TEST = "TestPracticeWire"
FIXTURES = Path(__file__).resolve().parent / "testdata" / "t19_wire_result"


def classify_fixture(name: str) -> t19_wire_result.Verdict:
    with (FIXTURES / name).open(encoding="utf-8") as stream:
        return t19_wire_result.classify(stream, package=PACKAGE, test=TEST)


class ExactTopLevelResultTests(unittest.TestCase):
    def assert_code(self, fixture: str, code: str) -> None:
        verdict = classify_fixture(fixture)
        self.assertEqual(verdict.code, code, verdict.detail)

    def test_pass_requires_exact_test_and_package_pass(self) -> None:
        verdict = classify_fixture("pass.jsonl")
        self.assertEqual(verdict.code, "pass", verdict.detail)
        self.assertTrue(verdict.accepted)

    def test_output_cannot_turn_skip_into_pass(self) -> None:
        self.assert_code("skip.jsonl", "skip")

    def test_output_cannot_hide_fail(self) -> None:
        self.assert_code("fail.jsonl", "fail")

    def test_empty_selection_is_not_pass(self) -> None:
        self.assert_code("empty_selection.jsonl", "empty")

    def test_same_leaf_subtest_is_not_top_level(self) -> None:
        self.assert_code("same_leaf_subtest.jsonl", "empty")

    def test_test_in_another_package_is_not_accepted(self) -> None:
        self.assert_code("wrong_package.jsonl", "empty")

    def test_pass_test_and_fail_package_is_rejected(self) -> None:
        self.assert_code("inconsistent_terminal.jsonl", "inconsistent")

    def test_conflicting_test_terminals_are_rejected(self) -> None:
        self.assert_code("conflicting_test_terminal.jsonl", "inconsistent")

    def test_malformed_json_is_rejected_without_echoing_content(self) -> None:
        verdict = classify_fixture("malformed.jsonl")
        self.assertEqual(verdict.code, "invalid_json")
        self.assertIn("line 3", verdict.detail)
        self.assertNotIn("Action", verdict.detail)

    def test_non_object_json_is_rejected(self) -> None:
        verdict = t19_wire_result.classify(
            io.StringIO(json.dumps(["not", "an", "event"]) + "\n"),
            package=PACKAGE,
            test=TEST,
        )
        self.assertEqual(verdict.code, "invalid_json")

    def test_missing_package_terminal_is_rejected(self) -> None:
        data = "\n".join(
            [
                json.dumps({"Action": "run", "Package": PACKAGE, "Test": TEST}),
                json.dumps({"Action": "pass", "Package": PACKAGE, "Test": TEST}),
            ]
        )
        verdict = t19_wire_result.classify(io.StringIO(data + "\n"), package=PACKAGE, test=TEST)
        self.assertEqual(verdict.code, "inconsistent")


if __name__ == "__main__":
    unittest.main()
