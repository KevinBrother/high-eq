#!/usr/bin/env python3
"""Classify one exact top-level Go test from a go test -json stream."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

TERMINAL_ACTIONS = frozenset({"pass", "skip", "fail"})


@dataclass(frozen=True)
class Verdict:
    code: str
    detail: str

    @property
    def accepted(self) -> bool:
        return self.code == "pass"


def _invalid_json(line_number: int) -> Verdict:
    return Verdict(
        "invalid_json",
        f"invalid JSON at line {line_number}; refusing to infer a result",
    )


def classify(
    lines: Iterable[str], *, package: str, test: str
) -> Verdict:
    """Classify terminal events for exactly ``test`` in exactly ``package``.

    Output text is deliberately ignored. A test event without the expected
    Package does not count, and subtest names do not equal their parent name.
    """

    package_terminals: set[str] = set()
    test_terminals: set[str] = set()

    for line_number, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            return _invalid_json(line_number)
        if not isinstance(event, dict):
            return _invalid_json(line_number)

        action = event.get("Action")
        if not isinstance(action, str) or action not in TERMINAL_ACTIONS:
            continue
        if event.get("Package") != package:
            continue
        if "Test" in event:
            if event.get("Test") == test:
                test_terminals.add(action)
            continue

        package_terminals.add(action)

    if not package_terminals:
        return Verdict(
            "inconsistent",
            f"no terminal event for package {package}; result is unconfirmed",
        )
    if len(package_terminals) != 1:
        actions = ", ".join(sorted(package_terminals))
        return Verdict(
            "inconsistent",
            f"package {package} reported conflicting terminal actions: {actions}",
        )

    package_terminal = next(iter(package_terminals))
    if not test_terminals:
        if package_terminal == "fail":
            return Verdict("fail", "package failed before the exact top-level test terminated")
        return Verdict(
            "empty",
            "no terminal event for the exact top-level test; selection may be empty",
        )
    if len(test_terminals) != 1:
        actions = ", ".join(sorted(test_terminals))
        return Verdict(
            "inconsistent",
            f"exact top-level test reported conflicting terminal actions: {actions}",
        )

    test_terminal = next(iter(test_terminals))
    if test_terminal == "pass" and package_terminal == "pass":
        return Verdict("pass", "exact top-level test and package both passed")
    if test_terminal == "skip" and package_terminal == "pass":
        return Verdict(
            "skip",
            "exact top-level test was skipped; disposable storage evidence is required",
        )
    if test_terminal == "fail" and package_terminal == "fail":
        return Verdict("fail", "exact top-level test failed")

    return Verdict(
        "inconsistent",
        f"exact top-level test {test_terminal.upper()} conflicts with "
        f"package {package_terminal.upper()}",
    )


def _arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Require one exact top-level go test result from -json output."
    )
    parser.add_argument("--package", required=True)
    parser.add_argument("--test", required=True)
    parser.add_argument("log", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _arguments(argv)
    try:
        with args.log.open(encoding="utf-8") as stream:
            verdict = classify(stream, package=args.package, test=args.test)
    except (OSError, UnicodeError):
        print("cannot read go test JSON log", file=sys.stderr)
        return 1

    if verdict.accepted:
        print(f"exact top-level PASS in {args.package}")
        return 0
    print(verdict.detail, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
