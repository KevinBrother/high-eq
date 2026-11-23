#!/usr/bin/env bash
# D13 only. Use disposable loopback PostgreSQL 17 and two independent Redis
# instances. Never source .env or reuse a development/production endpoint.
set -euo pipefail

if (( $# > 1 )); then
  echo 'usage: d13-integration.sh [--check-targets-only]' >&2
  exit 2
fi
mode=run
case ${1:-} in
  '') ;;
  --check-targets-only) mode=check ;;
  *)
    echo 'usage: d13-integration.sh [--check-targets-only]' >&2
    exit 2
    ;;
esac

if [[ -z ${D13_DATABASE_URL:-} ]]; then
  echo 'D13_DATABASE_URL is required (export a disposable loopback PostgreSQL URL)' >&2
  exit 2
fi
if [[ -z ${D13_REDIS_URL:-} ]]; then
  echo 'D13_REDIS_URL is required (export the disposable ordinary Redis URL)' >&2
  exit 2
fi
if [[ -z ${D13_LEDGER_URL:-} ]]; then
  echo 'D13_LEDGER_URL is required (export the separate disposable ledger Redis URL)' >&2
  exit 2
fi
export D13_DATABASE_URL D13_REDIS_URL D13_LEDGER_URL

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
cd "$repo_root/server"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/d13-integration.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

# pgx also reads libpq PG* settings. Remove every inherited variable that can
# alter the connection and replace the passfile with an empty archive-local file.
while IFS= read -r name; do
  if [[ $name == PG* ]]; then
    unset "$name"
  fi
done < <(compgen -e)
empty_pgpass="$work_dir/empty.pgpass"
printf '' >"$empty_pgpass"
export PGPASSFILE="$empty_pgpass"

target_helper="$work_dir/d13targets"
if ! go build -o "$target_helper" ./tests/d13targets; then
  echo 'D13 target validator could not be built' >&2
  exit 1
fi
if ! "$target_helper"; then
  echo 'D13 target validation failed; no integration test was started' >&2
  exit 2
fi
if [[ $mode == check ]]; then
  echo 'OK: D13 targets validated without opening any connection'
  exit 0
fi

# Fixed synthetic test configuration only. Connection URLs always come from the
# required D13_* variables above and have already passed driver-level validation.
export APP_ENV=development
export BACKUP_RETENTION_DAYS=30
export PAYMENT_MODE=disabled
export DATABASE_URL="$D13_DATABASE_URL"
export REDIS_URL="$D13_REDIS_URL"
export LEDGER_URL="$D13_LEDGER_URL"
export FIELD_KEY_BASE64='QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI='

log_dir="$work_dir/logs"
mkdir -p "$log_dir"

run_required_tests() {
  local package=$1
  local pattern=$2
  shift 2
  local log="$log_dir/$(printf '%s' "$package" | tr '/.' '__').jsonl"

  if ! go test -count=1 -json -p 1 -timeout=4m -tags integration \
    ./"$package" -run "$pattern" 2>&1 | tee "$log"; then
    echo "D13 integration command failed: $package" >&2
    exit 1
  fi

  python3 - "$log" "$@" <<'PY'
import json
import sys

path = sys.argv[1]
expected = set(sys.argv[2:])
passed = set()
problems = []
with open(path, encoding='utf-8') as stream:
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        action = event.get('Action')
        test = event.get('Test')
        package = event.get('Package', '')
        if action == 'skip':
            problems.append(f'SKIP is not PASS: {test or package}')
        elif action == 'fail':
            problems.append(f'FAIL: {test or package}')
        elif action == 'pass' and test in expected:
            passed.add(test)

missing = sorted(expected - passed)
if missing:
    problems.append('missing exact PASS event: ' + ', '.join(missing))
if problems:
    for problem in problems:
        print(problem, file=sys.stderr)
    raise SystemExit(1)
print('PASS ' + ', '.join(sorted(expected)))
PY
}

run_required_tests cmd/api '^TestChatImportCleanupProcess$' \
  TestChatImportCleanupProcess
run_required_tests internal/training \
  '^TestChatImportsExpireAtBoundaryAndRetryAcrossPoolRestart$' \
  TestChatImportsExpireAtBoundaryAndRetryAcrossPoolRestart
run_required_tests internal/service '^TestReplyLifecycle$' TestReplyLifecycle

echo 'OK: all D13 integration tests produced exact PASS results; no SKIP or FAIL'
