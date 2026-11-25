#!/usr/bin/env bash
# T15 real-service check. Default (no arguments) runs the rollback journey: the
# shipped /prompts page rolls one published role-play prompt back to v1 over
# loopback HTTP; the same synthetic App user's next normal attempt then uses
# the older template at the synthetic upstream.
#
# Optional --dashboard is the only other choice: the shipped /metrics page
# selects task, model and prompt version for one synthetic review and the Go
# parent compares what the page rendered with persisted calls and the numeric
# projection. Both modes use fresh disposable stores only; no real provider,
# account, browser or credential, and no caller-supplied store URLs.
#
# The one-time PostgreSQL + two Redis assembly is reused in-repo from
# app/tool/t27/history_journey.py (run_services), so this entry does not copy a
# bootstrap script.
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)

prerequisite() {
  printf 'T15 verify prerequisite: %s\n' "$1" >&2
  exit 2
}

usage() {
  printf 'usage: %s [--dashboard]\n' "$(basename "$0")" >&2
  exit 2
}

# Zero arguments keep the rollback journey; exactly one argument is allowed and
# must be --dashboard. A single empty argument is not zero arguments.
if (( $# == 0 )); then
  mode=rollback
elif (( $# == 1 )) && [[ $1 == --dashboard ]]; then
  mode=dashboard
else
  usage
fi

[[ ${T15_DISPOSABLE:-} == yes ]] ||
  prerequisite 'T15_DISPOSABLE=yes is required for disposable loopback stores'
for tool in go flutter python3; do
  command -v "$tool" >/dev/null || prerequisite "$tool must be on PATH"
done
initdb_bin=$(command -v initdb) || prerequisite 'initdb (PostgreSQL 17) must be on PATH'
redis_bin=$(command -v redis-server) || prerequisite 'redis-server must be on PATH'
pg_bin=$(cd "$(dirname "$initdb_bin")" && pwd)
[[ -f $root/app/tool/t27/history_journey.py ]] ||
  prerequisite 'missing app/tool/t27/history_journey.py (store assembly to reuse)'
if [[ $mode == dashboard ]]; then
  [[ -f $root/server/internal/service/t15_dashboard_page_integration_test.go ]] ||
    prerequisite 'missing server/internal/service/t15_dashboard_page_integration_test.go'
  [[ -f $root/admin/tool/t15/dashboard_live_test.dart ]] ||
    prerequisite 'missing admin/tool/t15/dashboard_live_test.dart'
else
  [[ -f $root/server/internal/service/t15_rollback_page_integration_test.go ]] ||
    prerequisite 'missing server/internal/service/t15_rollback_page_integration_test.go'
  [[ -f $root/admin/tool/t15/rollback_live_test.dart ]] ||
    prerequisite 'missing admin/tool/t15/rollback_live_test.dart'
fi
[[ -f $root/admin/.dart_tool/package_config.json ]] ||
  prerequisite 'run flutter pub get --enforce-lockfile in admin first'
[[ -z ${DATABASE_URL:-} ]] ||
  prerequisite 'DATABASE_URL is not accepted; T15 always owns fresh disposable stores'
[[ -z ${REDIS_URL:-} ]] ||
  prerequisite 'REDIS_URL is not accepted; T15 always owns fresh disposable stores'
[[ -z ${LEDGER_URL:-} ]] ||
  prerequisite 'LEDGER_URL is not accepted; T15 always owns fresh disposable stores'

exec python3 - "$root" "$pg_bin" "$redis_bin" \
  "$(command -v go)" "$(command -v flutter)" "$mode" <<'PY'
import importlib.util
import os
import pathlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace

root, pg_bin, redis, go, flutter = (
    pathlib.Path(value) for value in sys.argv[1:6]
)
mode = sys.argv[6]
tests = {
    "rollback": ("integration,t15rollback", "TestT15AdminRollbackNextAppCall"),
    "dashboard": ("integration,t15dashboard", "TestT15DashboardRealPage"),
}
tags, test_name = tests[mode]

spec = importlib.util.spec_from_file_location(
    "t27_history_journey", root / "app/tool/t27/history_journey.py"
)
hj = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hj)


def setup(args, env):
    # Reuse the shared binary/version checks but replace its app/ Flutter-deps
    # gate: T15 drives admin/tool/t15, not the app journey.
    pg = hj.executable(args.pg_bin / "postgres", "postgres")
    initdb = hj.executable(args.pg_bin / "initdb", "initdb")
    redis_exe = hj.executable(args.redis, "redis-server")
    go_exe = hj.executable(args.go, "go")
    flutter_exe = hj.executable(args.flutter, "flutter")
    with hj.prerequisite(hj.Stage.POSTGRES_VERSION):
        version = subprocess.check_output(
            [pg, "--version"], env=env, text=True, timeout=5,
            stderr=subprocess.STDOUT,
        )
        if "17." not in version:
            raise hj.NotRun(f"expected PostgreSQL 17, got {version.strip()}")
    with hj.prerequisite(hj.Stage.GO_VERSION):
        go_version = subprocess.check_output(
            [go_exe, "version"], env=env, text=True, timeout=5,
            stderr=subprocess.STDOUT,
        )
        minor = go_version.split()[2].lstrip("go").split(".")
        if tuple(int(part) for part in minor[:2]) < (1, 26):
            raise hj.NotRun(f"expected Go 1.26 or newer, got {go_version.strip()}")
    with hj.prerequisite(hj.Stage.FLUTTER_CACHE):
        flutter_root = flutter_exe.resolve().parents[1]
        cache = flutter_root / "bin/cache"
        dart = hj.executable(cache / "dart-sdk/bin/dart", "Flutter cached Dart")
        snapshot = cache / "flutter_tools.snapshot"
        if not snapshot.is_file():
            raise hj.NotRun("Flutter tools snapshot unavailable")
    with hj.prerequisite(hj.Stage.FLUTTER_DEPENDENCIES):
        for name in ("package_config.json", "package_graph.json"):
            if not (root / "admin/.dart_tool" / name).is_file():
                raise hj.NotRun("prepare locked Flutter dependencies in admin/ first")
    env.update(
        FLUTTER_ROOT=str(flutter_root),
        FLUTTER_STORAGE_BASE_URL="http://127.0.0.1:0",
        PUB_HOSTED_URL="http://127.0.0.1:0",
    )
    return pg, initdb, redis_exe, go_exe, dart, snapshot


def run_journey(go_exe, env, log):
    test_env = dict(env)
    test_env.update(
        T15_DISPOSABLE="yes",
        PAYMENT_MODE="disabled",
        DATABASE_POOL_MAX_CONNS="20",
        WLEIS_CONFIG_PATH=str(root / "server/internal/service/testdata/t26_assessment.yaml"),
    )
    with log.open("wb") as output:
        proc = subprocess.run(
            [go_exe, "test", "-mod=readonly", "-count=1", "-timeout=10m", "-v",
             "-tags", tags,
             "-run", f"^{test_name}$", "./internal/service"],
            cwd=root / "server", env=test_env, stdout=output,
            stderr=subprocess.STDOUT,
        )
    lines = log.read_text(errors="replace").splitlines()
    print("\n".join(lines[-40:]), flush=True)
    if any(line.startswith(f"--- SKIP: {test_name}") for line in lines):
        raise hj.Skipped("the named test was skipped", stage="journey")
    if proc.returncode != 0 or not any(
        line.startswith(f"--- PASS: {test_name}") for line in lines
    ):
        raise hj.Failed(
            f"the named test exited {proc.returncode} without a PASS, see {log}",
            stage="journey",
        )
    print("RESULT: PASS", flush=True)


hj.setup = setup
args = SimpleNamespace(pg_bin=pg_bin, redis=redis, go=go, flutter=flutter)

os.umask(0o077)
with tempfile.TemporaryDirectory(prefix="t15-verify-") as directory:
    state = pathlib.Path(directory)
    logs = state / "logs"
    logs.mkdir()
    env = hj.isolated_environment(state)
    # A cold module cache is a normal prerequisite gap, not a permanent failure;
    # let the Go tool fetch rather than forcing GOPROXY=off.
    env.pop("GOPROXY", None)
    env.pop("GOSUMDB", None)
    try:
        hj.run_services(args, state, logs, env, run_journey=run_journey)
    except hj.JourneyError as error:
        status, code = {
            hj.Failed: ("FAIL", 1),
            hj.NotRun: ("NOT RUN", 2),
            hj.Skipped: ("SKIPPED", 3),
        }[type(error)]
        print(f"{status}({error.stage}): {error}", file=sys.stderr)
        sys.exit(code)
PY
