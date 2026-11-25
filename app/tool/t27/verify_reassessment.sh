#!/bin/bash
set -euo pipefail
# Thin entry for the four-week reassessment journey. Reuse history_journey.py's
# disposable PG17, cache Redis and AOF ledger Redis setup; only the Go test
# selection changes. Requires flutter and go on PATH plus locked app deps.
root=$(cd "$(dirname "$0")/../../.." && pwd)
exec python3 -B - "$root" "$@" <<'PY'
import argparse
import sys
from pathlib import Path

root = Path(sys.argv[1])
# Accept only the two inputs this journey needs. In particular, reject the
# generic launcher's --ledger-only precheck so a successful exit can never mean
# anything less than the full Flutter and Go journey.
parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
parser.add_argument("--pg-bin", type=Path, required=True)
parser.add_argument("--redis", type=Path, required=True)
known, unknown = parser.parse_known_args(sys.argv[2:])
if unknown:
    parser.error("unsupported arguments: " + " ".join(unknown))
sys.argv = [sys.argv[0], "--pg-bin", str(known.pg_bin), "--redis", str(known.redis)]
sys.path.insert(0, str(root / "app" / "tool" / "t27"))

import history_journey as history

TEST = "TestT27FourWeekReassessmentJourney"
REQUIRED = (
    "page.journey",
    "readback.assessments",
    "readback.plan-kept",
    "readback.plan-adjusted",
    "journey",
)


def run_reassessment(go, env, log):
    active = dict(env)
    active["T27_DISPOSABLE"] = "yes"
    active["WLEIS_CONFIG_PATH"] = str(
        root / "server/internal/service/testdata/t26_assessment.yaml"
    )
    with history.ExitStack() as command:
        proc = history.spawn(command, [
            go, "test", "-mod=readonly", "-tags=integration,t27reassess",
            "-count=1", "-timeout=7m", "-v", "-run", f"^{TEST}$",
            "./internal/service",
        ], active, log)
        try:
            status = proc.wait(timeout=540)
        except history.subprocess.TimeoutExpired:
            status = None

    lines = log.read_text(errors="replace").splitlines()
    for line in lines:
        if history.re.search(r"\b(?:BEGIN|PASS|FAIL|OBSERVED|NOT RUN)\(", line):
            print(line.strip(), flush=True)
    if status is None:
        raise history.Failed("journey exceeded the runner deadline", stage="journey")
    if status == 0 and any(line.startswith(f"--- SKIP: {TEST} (") for line in lines):
        raise history.Skipped(f"Go skipped {TEST}", stage=history.Stage.GO_STARTUP.value)
    if status != 0:
        raise history.Failed(f"journey exited {status}", stage="journey")
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


history.run_test = run_reassessment
history.main()
PY
