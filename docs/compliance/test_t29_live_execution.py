#!/usr/bin/env python3
"""Offline execution contracts for the T29 hosted live-test entry point."""

from __future__ import annotations

import unittest

try:
    from .t29_live_probe import LiveProbeResult, run_t29_live_probe
except ImportError:  # pragma: no cover - direct discovery from docs/compliance.
    from t29_live_probe import LiveProbeResult, run_t29_live_probe  # type: ignore[no-redef]


class T29LiveExecutionContract(unittest.TestCase):
    def test_live_script_reaches_the_live_dart_test(self) -> None:
        result = run_t29_live_probe()
        self.assertIsInstance(result, LiveProbeResult)
        self.assertEqual(result.returncode, 0, result.describe())
        self.assertTrue(result.reached_live_test, result.describe())

    def test_live_script_propagates_the_live_dart_failure(self) -> None:
        result = run_t29_live_probe(flutter_exit=37)
        self.assertEqual(result.returncode, 37, result.describe())
        self.assertTrue(result.reached_live_test, result.describe())

    def test_live_probe_rejects_an_entry_exit_zero_mutation(self) -> None:
        result = run_t29_live_probe(
            live_source=run_t29_live_probe.source.replace(
                "set -euo pipefail\n",
                "set -euo pipefail\nexit 0\n",
                1,
            )
        )
        self.assertEqual(result.returncode, 0, result.describe())
        self.assertFalse(result.reached_live_test, result.describe())
        self.assertTrue(
            any("live_test.dart was not invoked" in item for item in result.violations),
            result.describe(),
        )


if __name__ == "__main__":
    unittest.main()
