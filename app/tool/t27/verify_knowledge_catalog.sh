#!/bin/bash
set -euo pipefail
# Thin entry for the knowledge catalog read/completion journey. Reuse
# history_journey.py's disposable PG17, cache Redis and AOF ledger Redis setup;
# only the Go test selection changes. Requires flutter and go on PATH plus
# locked app deps.
root=$(cd "$(dirname "$0")/../../.." && pwd)
exec python3 -B - "$root" "$@" <<'PY'
import argparse
import sys
from pathlib import Path

root = Path(sys.argv[1])
parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
parser.add_argument("--pg-bin", type=Path)
parser.add_argument("--redis", type=Path)
parser.add_argument("--classify-log", type=Path)
parser.add_argument("--status", type=int, default=1)
known, unknown = parser.parse_known_args(sys.argv[2:])
if unknown:
    parser.error("unsupported arguments: " + " ".join(unknown))
if known.classify_log is None and (known.pg_bin is None or known.redis is None):
    parser.error("--pg-bin and --redis are required for the full journey")
sys.argv = [sys.argv[0]]
if known.pg_bin is not None and known.redis is not None:
    sys.argv += ["--pg-bin", str(known.pg_bin), "--redis", str(known.redis)]

sys.path.insert(0, str(root / "app" / "tool" / "t27"))

import history_journey as history

TEST = "TestT27KnowledgeCatalogJourney"
REQUIRED = (
    "service.catalog",
    "page.browse-last-card",
    "page.read-no-complete",
    "page.plan-card-complete",
    "page.growth-tab",
    "page.growth-home",
    "service.after",
    "journey",
)
STAGE_LINE = history.re.compile(r"T27_STAGE ([a-z.-]+)")
RUN_LINE = history.re.compile(r"=== RUN\s+" + history.re.escape(TEST) + r"$")


def last_stage(lines):
    stage = None
    for line in lines:
        match = STAGE_LINE.fullmatch(line.strip())
        if match:
            stage = match[1]
    return stage


def raise_for_failure(lines, status, log):
    """Classify a non-zero Go run from real named markers.

    A named test that actually started is an entered behavior failure even when
    the last visible marker is a behavior stage with no FAIL(...) line. Only a
    run with no ``=== RUN``/``--- FAIL`` marker is "not entered".
    """
    failed_stage = next(
        (
            match[1]
            for line in lines
            if (match := history.PHASE_FAILURE.fullmatch(line.strip()))
        ),
        None,
    )
    if failed_stage is not None:
        raise history.Failed(
            f"journey failed at {failed_stage}, see {log}", stage=failed_stage
        )
    if status == 0:
        return
    entered = any(RUN_LINE.search(line.strip()) for line in lines) or any(
        f"--- FAIL: {TEST}" in line for line in lines
    )
    if not entered:
        raise history.NotRun(
            f"Go did not enter {TEST} (exit {status}), see {log}",
            stage=history.Stage.GO_STARTUP.value,
        )
    stage = last_stage(lines)
    if stage is None:
        stage = next(
            (
                match[1]
                for line in reversed(lines)
                if (match := history.PHASE_PASS.fullmatch(line.strip()))
            ),
            "journey",
        )
    raise history.Failed(
        f"journey entered {TEST} and exited {status} after stage {stage}, see {log}",
        stage=stage,
    )


def run_catalog(go, env, log):
    active = dict(env)
    active["T27_DISPOSABLE"] = "yes"
    active["WLEIS_CONFIG_PATH"] = str(
        root / "server/internal/service/testdata/t26_assessment.yaml"
    )
    with history.ExitStack() as command:
        proc = history.spawn(command, [
            go, "test", "-mod=readonly", "-tags=integration,t27knowledge",
            "-count=1", "-timeout=10m", "-v", "-run", f"^{TEST}$",
            "./internal/service",
        ], active, log)
        try:
            status = proc.wait(timeout=660)
        except history.subprocess.TimeoutExpired:
            status = None

    lines = log.read_text(errors="replace").splitlines()
    for line in lines:
        if history.re.search(r"\b(?:BEGIN|PASS|FAIL|OBSERVED|NOT RUN)\(", line) or "T27_STAGE " in line:
            print(line.strip(), flush=True)
    if status is None:
        raise history.Failed("journey exceeded the runner deadline", stage="journey")
    if status == 0 and any(line.startswith(f"--- SKIP: {TEST} (") for line in lines):
        raise history.Skipped(f"Go skipped {TEST}", stage=history.Stage.GO_STARTUP.value)
    raise_for_failure(lines, status, log)
    passed = {
        match[1]
        for line in lines
        if (match := history.PHASE_PASS.fullmatch(line.strip()))
    }
    missing = [phase for phase in REQUIRED if phase not in passed]
    if missing:
        raise history.Failed(
            "missing " + ", ".join(f"PASS({phase})" for phase in missing),
            stage=missing[0],
        )
    if not any(line.startswith(f"--- PASS: {TEST} (") for line in lines):
        raise history.Failed(f"Go omitted the {TEST} pass", stage="journey")
    print("RESULT: PASS", flush=True)


def report(error):
    status, exit_code = {
        history.Failed: ("FAIL", 1),
        history.NotRun: ("NOT RUN", 2),
        history.Skipped: ("SKIPPED", 3),
    }[type(error)]
    print(f"{status}({error.stage}): {error}", file=sys.stderr)
    print(f"{history.STAGE_PREFIX}{error.stage}", file=sys.stderr)
    return exit_code


if known.classify_log is not None:
    lines = known.classify_log.read_text(errors="replace").splitlines()
    error = None
    if any(line.startswith(f"--- SKIP: {TEST} (") for line in lines) and known.status == 0:
        error = history.Skipped(
            f"Go skipped {TEST}", stage=history.Stage.GO_STARTUP.value
        )
    else:
        try:
            raise_for_failure(lines, known.status, known.classify_log)
        except history.JourneyError as caught:
            error = caught
    if error is not None:
        sys.exit(report(error))
    print("RESULT: PASS", flush=True)
    sys.exit(0)

history.run_test = run_catalog
try:
    history.main()
except history.JourneyError as error:
    sys.exit(report(error))
PY
