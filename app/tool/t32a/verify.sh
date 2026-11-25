#!/usr/bin/env bash
# T32A archived journey: a thin entry over T27's already-audited disposable
# assembly (app/tool/t27/history_journey.py). That module supplies the minimal
# environment, throwaway PostgreSQL 17 and two Redis 8.2 children, per-child
# cleanup, and loopback ports. This entry only changes the Go test it runs to
# TestT32AMarkReviewJourney and keeps its net one-debit and no-skip guards.
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
[[ ${T32A_DISPOSABLE:-} == yes ]] || {
  printf 'T32A verify prerequisite: T32A_DISPOSABLE=yes is required\n' >&2
  exit 2
}

exec python3 -I -B - "$root" <<'PY'
import importlib.util
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import types

root = pathlib.Path(sys.argv[1]).resolve()
test_name = "TestT32AMarkReviewJourney"
net_debit = re.compile(
    r"stage=complete marks=[1-9]\d* reviews=1 remaining=0 used=3 ledger=1"
)

module_path = root / "app/tool/t27/history_journey.py"
if not module_path.is_file():
    print("T32A verify prerequisite: T27 disposable assembly is missing", file=sys.stderr)
    sys.exit(2)
spec = importlib.util.spec_from_file_location("t27_history_journey", module_path)
t27 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t27)


def tool(name):
    path = shutil.which(name)
    if not path:
        raise t27.NotRun(f"{name} must be on PATH", stage="prerequisite")
    return pathlib.Path(path)


def run_journey(go, env, log):
    # The assembly built this environment from a fixed allowlist; add only the
    # T32A test's own switch and fixture path, never host store settings.
    env.update(
        T32A_DISPOSABLE="yes",
        PAYMENT_MODE="disabled",
        DATABASE_POOL_MAX_CONNS="20",
        WLEIS_CONFIG_PATH=str(root / "server/internal/service/testdata/t26_assessment.yaml"),
    )
    with t27.ExitStack() as command:
        proc = t27.spawn(command, [
            str(go), "test", "-mod=readonly", "-tags", "integration,t32ajourney",
            "-count=1", "-timeout=15m", "-v",
            "-run", f"^{test_name}$", "./internal/service",
        ], env, log)
        try:
            status = proc.wait(timeout=960)
        except subprocess.TimeoutExpired:
            raise t27.Failed("T32A journey exceeded the runner deadline", stage="journey")
    lines = log.read_text(errors="replace").splitlines()
    if any(line.startswith(f"--- SKIP: {test_name}") for line in lines):
        raise t27.Skipped(f"Go skipped {test_name}", stage="journey")
    if not any(line.startswith(f"--- PASS: {test_name} ") for line in lines):
        tail = "\n".join(lines[-20:])
        raise t27.Failed(f"{test_name} did not run to PASS (exit {status})\n{tail}",
                         stage="journey")
    if status != 0:
        raise t27.Failed(f"{test_name} exited {status}", stage="journey")
    if "T32A_STAGE complete" not in "\n".join(lines):
        raise t27.Failed("missing the Flutter journey completion receipt", stage="journey")
    receipt = next((line.strip() for line in reversed(lines) if net_debit.search(line)), None)
    if receipt is None:
        raise t27.Failed("missing the net one-debit service readback", stage="journey")
    print(f"T32A verify: {receipt}", flush=True)
    print(f"T32A verify: PASS {test_name}", flush=True)


def main():
    args = types.SimpleNamespace(
        pg_bin=tool("postgres").parent,
        redis=tool("redis-server"),
        go=tool("go"),
        flutter=tool("flutter"),
    )
    state_root = pathlib.Path(tempfile.mkdtemp(prefix="t32a-verify."))
    try:
        state = state_root / "state"
        logs = state_root / "logs"
        state.mkdir()
        logs.mkdir()
        env = t27.isolated_environment(state)
        t27.run_services(args, state, logs, env, run_journey=run_journey)
    finally:
        shutil.rmtree(state_root, ignore_errors=True)


try:
    main()
except t27.JourneyError as error:
    status, exit_code = {
        t27.Failed: ("FAIL", 1),
        t27.NotRun: ("NOT RUN", 2),
        t27.Skipped: ("SKIPPED", 3),
    }[type(error)]
    print(f"{status}({error.stage}): {error}", file=sys.stderr)
    print(f"{t27.STAGE_PREFIX}{error.stage}", file=sys.stderr)
    sys.exit(exit_code)
PY
