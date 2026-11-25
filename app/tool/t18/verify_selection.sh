#!/bin/bash
set -euo pipefail
# Thin entry for T18's real-use selection journey. Reuse history_journey.py's
# disposable PG17, cache Redis and AOF ledger Redis setup; only the Go test
# selection changes. Requires initdb/postgres, redis-server, go and flutter on
# PATH plus locked app dependencies. Callers cannot pass an existing database
# or Redis URL: the runner builds its own disposable storage.
root=$(cd "$(dirname "$0")/../../.." && pwd)
initdb=$(command -v initdb) || { echo "initdb must be on PATH" >&2; exit 2; }
redis=$(command -v redis-server) || { echo "redis-server must be on PATH" >&2; exit 2; }
pg_bin=$(dirname "$initdb")
exec python3 -B - "$root" "$pg_bin" "$redis" "$@" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
pg_bin = Path(sys.argv[2])
redis = Path(sys.argv[3])
if len(sys.argv) != 4:
    sys.exit("unsupported arguments; sources and binaries come from the checkout and PATH")
# Reject the generic launcher's --ledger-only precheck so a successful exit can
# never mean anything less than the full Flutter and Go journey.
sys.argv = [sys.argv[0], "--pg-bin", str(pg_bin), "--redis", str(redis)]
sys.path.insert(0, str(root / "app" / "tool" / "t27"))

import history_journey as history

TEST = "TestT18SelectionRenewalJourney"
PHASES = ("service.recent-use", "page.journey", "go.journey")
RECEIPT = re.compile(
    r"stage=complete fixture_expire_editable=1 fixture_renew_editable=2 selection_requests=1"
)


def run_selection(go, env, log):
    active = dict(env)
    active["T18_DISPOSABLE"] = "yes"
    with history.ExitStack() as command:
        proc = history.spawn(command, [
            go, "test", "-mod=readonly", "-tags=integration,t18selection",
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
    if not any(line.startswith(f"--- PASS: {TEST} (") for line in lines):
        raise history.Failed(f"Go omitted the {TEST} pass", stage="journey")
    passed = {
        match[1]
        for line in lines
        if (match := history.PHASE_PASS.fullmatch(line.strip()))
    }
    missing = [phase for phase in PHASES if phase not in passed]
    if missing:
        raise history.Failed(
            "missing " + ", ".join(f"PASS({phase})" for phase in missing),
            stage=missing[0],
        )
    if not any(RECEIPT.search(line) for line in lines):
        raise history.Failed("missing the stage=complete selection receipt", stage="journey")
    print("RESULT: PASS", flush=True)


history.run_test = run_selection
history.main()
PY
