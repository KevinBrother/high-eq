#!/bin/bash
set -euo pipefail
# Thin entry for the first-assessment resume journey. Reuse T27
# history_journey.py's disposable PG17, cache Redis and AOF ledger Redis setup;
# only the Go test selection and its receipts change. Requires flutter and go on
# PATH plus locked app deps.
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

TEST = "TestT17FirstAssessmentResumeJourney"
# The first Flutter process must stop before submitting; the second must
# restore the draft and submit exactly once. Both stage receipts and the page
# scores are required, so a partial Flutter run cannot pass.
REQUIRED_OBSERVATIONS = (
    "T17 probe: first Flutter process POST /v1/assessments entered count=0",
    "T17 probe: second Flutter process POST /v1/assessments entered count=1 status=200",
)
PAGE_SCORES = history.re.compile(
    r"T17 page: total=\d+ axes SEA=\d+ OEA=\d+ UOE=\d+ ROE=\d+"
)


def run_resume(go, env, log):
    active = dict(env)
    active["T17_DISPOSABLE"] = "yes"
    with history.ExitStack() as command:
        proc = history.spawn(command, [
            go, "test", "-mod=readonly", "-tags=integration,t17resume",
            "-count=1", "-timeout=10m", "-v", "-run", f"^{TEST}$",
            "./internal/service",
        ], active, log)
        try:
            status = proc.wait(timeout=600)
        except history.subprocess.TimeoutExpired:
            status = None

    lines = log.read_text(errors="replace").splitlines()
    for line in lines:
        if "T17 " in line or history.re.search(r"\b(?:PASS|FAIL|SKIP)\(", line):
            print(line.strip(), flush=True)
    if status is None:
        raise history.Failed("journey exceeded the runner deadline", stage="journey")
    if status == 0 and any(line.startswith(f"--- SKIP: {TEST} (") for line in lines):
        raise history.Skipped(f"Go skipped {TEST}", stage=history.Stage.GO_STARTUP.value)
    if status != 0:
        raise history.Failed(f"journey exited {status}", stage="journey")
    missing = [
        observation for observation in REQUIRED_OBSERVATIONS
        if not any(observation in line for line in lines)
    ]
    if missing:
        raise history.Failed(
            "missing observation: " + missing[0], stage="journey",
        )
    if not any(PAGE_SCORES.search(line) for line in lines):
        raise history.Failed("Go omitted the displayed page scores", stage="journey")
    if not any(line.startswith(f"--- PASS: {TEST} (") for line in lines):
        raise history.Failed(f"Go omitted the {TEST} pass", stage="journey")
    print("RESULT: PASS", flush=True)


history.run_test = run_resume
history.main()
PY
