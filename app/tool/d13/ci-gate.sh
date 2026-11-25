#!/usr/bin/env bash
# Dedicated D13 CI runner glue. Every invocation creates a fresh PG/Redis set.
set +x +v
set -euo pipefail
umask 077

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

usage() {
  echo 'usage: ci-gate.sh [--check-only] {strict|d13flutter|profile-fence|reply-cancellation|t35-reentry|t35-service|t35-export-ownership}' >&2
  exit 2
}

fail() {
  printf 'D13 CI FAIL: %s\n' "$1" >&2
  exit 1
}

check_only=no
if [[ ${1:-} == --check-only ]]; then
  check_only=yes
  shift
fi
(( $# == 1 )) || usage
gate=$1
case $gate in
  strict|d13flutter|profile-fence|reply-cancellation|t35-reentry|t35-service|t35-export-ownership) ;;
  *) usage ;;
esac

required_commands=(bash docker openssl python3 git go)
if [[ $gate == d13flutter ]]; then
  required_commands+=(flutter)
fi
for command_name in "${required_commands[@]}"; do
  command -v "$command_name" >/dev/null 2>&1 || fail "missing command: $command_name"
done
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 is required'
bash -n app/tool/d13/ci-gate.sh
bash -n server/tests/d13-integration.sh
bash -n app/tool/t35-privacy/gate.sh
[[ -f docker-compose.yml ]] || fail 'docker-compose.yml is missing'

if [[ $check_only == yes ]]; then
  printf 'OK: D13 CI wiring dependencies available for %s\n' "$gate"
  exit 0
fi

scratch=$(mktemp -d)
logs=$scratch/logs
mkdir -p "$logs"

pg_password=$(openssl rand -hex 16)
field_key=$(openssl rand -base64 32)
project="d13-ci-${gate//[^a-zA-Z0-9]/-}-$(openssl rand -hex 6)"
cat >"$scratch/ports.yml" <<'YAML'
services:
  db: {ports: ['127.0.0.1::5432']}
  cache: {ports: ['127.0.0.1::6379']}
  ledger: {ports: ['127.0.0.1::6379']}
YAML

compose_env=(env -i PATH="$PATH" HOME="${HOME:-/tmp}" HEQ_PG_PASSWORD="$pg_password"
  HEQ_FIELD_KEY="$field_key" HEQ_PORT=0)
if [[ -n ${DOCKER_HOST:-} ]]; then
  compose_env+=(DOCKER_HOST="$DOCKER_HOST")
fi
if [[ -n ${DOCKER_CONTEXT:-} ]]; then
  compose_env+=(DOCKER_CONTEXT="$DOCKER_CONTEXT")
fi
if [[ -n ${DOCKER_CONFIG:-} ]]; then
  compose_env+=(DOCKER_CONFIG="$DOCKER_CONFIG")
fi
compose=(docker compose --env-file /dev/null --project-name "$project"
  -f docker-compose.yml -f "$scratch/ports.yml")

compose_run() {
  "${compose_env[@]}" "${compose[@]}" "$@"
}

cleanup() {
  local status=$?
  if ! compose_run down --volumes --remove-orphans >"$scratch/cleanup.log" 2>&1; then
    echo 'D13 CI FAIL: disposable storage cleanup failed' >&2
    if (( status == 0 )); then status=1; fi
  fi
  rm -rf -- "$scratch"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compose_run up --detach --no-build --wait --wait-timeout 90 db cache ledger \
  >"$scratch/startup.log" 2>&1 || fail 'could not start disposable PostgreSQL and Redis stores'

# The Flutter-to-Go test intentionally uses this fixed synthetic database role.
if ! printf "%s\n" "CREATE ROLE synthetic LOGIN SUPERUSER PASSWORD 'synthetic';" |
  compose_run exec -T db psql -v ON_ERROR_STOP=1 -U postgres -d postgres -q >"$scratch/pg-role.log" 2>&1; then
  fail 'could not create the synthetic CI database role'
fi

published_endpoint() {
  local binding
  binding=$(compose_run port "$1" "$2" 2>"$scratch/port.stderr") || fail "could not resolve $1 port"
  [[ $binding =~ ^127\.0\.0\.1:([1-9][0-9]{0,4})$ ]] || fail "invalid loopback binding for $1"
  (( BASH_REMATCH[1] <= 65535 )) || fail "invalid loopback port for $1"
  printf '%s\n' "$binding"
}

pg=$(published_endpoint db 5432)
cache=$(published_endpoint cache 6379)
ledger=$(published_endpoint ledger 6379)
[[ $pg != "$cache" && $pg != "$ledger" && $cache != "$ledger" ]] || \
  fail 'PostgreSQL, cache and ledger must use distinct loopback ports'

export APP_ENV=development
export BACKUP_RETENTION_DAYS=30
export PAYMENT_MODE=disabled
export T35_PRIVACY_DISPOSABLE=yes
export DATABASE_URL="postgres://postgres:${pg_password}@${pg}/postgres?sslmode=disable"
export REDIS_URL="redis://${cache}/0"
export LEDGER_URL="redis://${ledger}/0"
export FIELD_KEY_BASE64="$field_key"
export D13_DATABASE_URL="$DATABASE_URL"
export D13_REDIS_URL="$REDIS_URL"
export D13_LEDGER_URL="$LEDGER_URL"
export D13_REPLY_PG_PORT=${pg##*:}
export D13_REPLY_CACHE_PORT=${cache##*:}
export D13_REPLY_LEDGER_PORT=${ledger##*:}

summarize_go_log() {
  local log=$1
  python3 -B - "$log" <<'PY'
import json
import sys

terminal = []
with open(sys.argv[1], encoding='utf-8', errors='replace') as stream:
    for line in stream:
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            continue
        action = event.get('Action')
        test = event.get('Test')
        package = event.get('Package', '')
        if action in {'fail', 'skip'} and (test or package):
            terminal.append(f"{action}: {test or package}")
for item in terminal[-20:]:
    print(item, file=sys.stderr)
PY
}

run_go_tests() {
  local label=$1 tags=$2 pattern=$3 race=$4
  shift 4
  local -a expected=("$@")
  local -a flags=()
  local log=$logs/$label.go.jsonl
  local stderr_log=$logs/$label.go.stderr
  local status=0 receipt=0 test_name
  if [[ $race == yes ]]; then
    flags+=(-race)
  fi

  (cd server && go test ${flags[@]+"${flags[@]}"} -mod=readonly -tags "$tags" -count=1 \
    -json -timeout=8m -run "$pattern" ./internal/service) >"$log" 2>"$stderr_log" || status=$?
  if ! python3 -B - "$log" <<'PY'
import json
import sys

problems = []
with open(sys.argv[1], encoding='utf-8', errors='replace') as stream:
    for line in stream:
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            continue
        if not isinstance(event, dict):
            continue
        if event.get('Package') != 'high-eq/server/internal/service':
            continue
        action = event.get('Action')
        if action in {'skip', 'fail'}:
            problems.append(f"{action}: {event.get('Test') or event.get('Package')}")
if problems:
    print('selected package has non-pass terminal events: ' + ', '.join(problems), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    summarize_go_log "$log"
    fail "required Go receipt contains skip or fail: $label"
  fi
  for test_name in "${expected[@]}"; do
    if ! python3 -B server/tests/t19_wire_result.py \
      --package high-eq/server/internal/service --test "$test_name" "$log" >/dev/null; then
      receipt=1
    fi
  done
  if (( status != 0 || receipt != 0 )); then
    summarize_go_log "$log"
    fail "required Go receipt was not an exact PASS: $label"
  fi
  for test_name in "${expected[@]}"; do
    printf 'PASS: %s\n' "$test_name"
  done
}

verify_d13flutter_stages() {
  python3 -B - "$logs/d13flutter.go.jsonl" <<'PY'
import json
import sys

required = (
    'D13_REPLY_STAGE stage=start result=pass',
    'D13_REPLY_STAGE stage=fixture result=pass',
    'D13_REPLY_STAGE stage=chat_import result=pass',
    'D13_REPLY_STAGE stage=flutter result=pass',
    'D13_REPLY_STAGE stage=ledger result=pass',
    'D13_LEDGER_STAGE:verified keys=2 outage_keys=1 complete_keys=1 ledger=1 unrefunded=1 held=0',
    'D13_CONTACT_INFERENCE_STAGE:verified rows=2 invalidated=1 complete=1 processing=0',
)
text = []
with open(sys.argv[1], encoding='utf-8', errors='replace') as stream:
    for line in stream:
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            continue
        output = event.get('Output')
        if isinstance(output, str):
            text.append(output)
combined = ''.join(text)
missing = [item for item in required if item not in combined]
if missing:
    print('missing D13 Flutter-to-Go stage receipt: ' + ', '.join(missing), file=sys.stderr)
    raise SystemExit(1)
print('PASS: D13 Flutter-to-Go stages, durable ledgers and contact invalidation')
PY
}

verify_contact_fixture() {
  local log=$logs/contact-fixture.flutter.jsonl
  local stderr_log=$logs/contact-fixture.flutter.stderr
  local status=0
  (cd app && flutter test --no-pub -r json tool/d13/contact_fixture_test.dart)     >"$log" 2>"$stderr_log" || status=$?
  if ! python3 -B - "$log" "$status" <<'PY'
import json
import sys

path, raw_status = sys.argv[1:]
expected_name = 'contact fixture leaves chat import for the first UI grant'
starts = []
dones = []
runner_done = []
problems = []
with open(path, encoding='utf-8', errors='replace') as stream:
    for line_number, line in enumerate(stream, start=1):
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            problems.append(f'invalid JSON event at line {line_number}')
            continue
        if not isinstance(event, dict):
            problems.append(f'non-object JSON event at line {line_number}')
            continue
        event_type = event.get('type')
        if event_type == 'testStart':
            test = event.get('test')
            if isinstance(test, dict) and test.get('name') == expected_name:
                metadata = test.get('metadata')
                starts.append((test.get('id'), test.get('hidden', False),
                               isinstance(metadata, dict) and metadata.get('skip') is False))
        elif event_type == 'testDone':
            dones.append((event.get('testID'), event.get('result'), event.get('skipped'),
                          event.get('hidden')))
        elif event_type == 'done':
            runner_done.append(event.get('success'))

if raw_status != '0':
    problems.append(f'flutter test exited {raw_status}')
if len(starts) != 1:
    problems.append(f'expected one exact testStart, got {len(starts)}')
elif starts[0][1] is not False or starts[0][2] is not True:
    problems.append('exact testStart is hidden or skips execution')
if len(runner_done) != 1 or runner_done[0] is not True:
    problems.append('flutter runner done.success is not exactly true')
if len(starts) == 1 and isinstance(starts[0][0], int):
    exact_id = starts[0][0]
    exact_dones = [item for item in dones if item[0] == exact_id]
    if len(exact_dones) != 1:
        problems.append(f'expected one exact testDone, got {len(exact_dones)}')
    elif exact_dones[0][1:] != ('success', False, False):
        problems.append('exact testDone is not success, non-skipped and non-hidden')
else:
    problems.append('exact testStart has no integer test id')
if problems:
    print('contact fixture receipt rejected: ' + '; '.join(problems), file=sys.stderr)
    raise SystemExit(1)
print('PASS: contact fixture leaves chat import for the first UI grant')
PY
  then
    fail 'required contact fixture receipt was not an exact PASS'
  fi
}

verify_strict() {
  python3 -B - "$logs/strict.log" <<'PY'
import json
import sys

expected = {
    'TestChatImportCleanupProcess',
    'TestChatImportsExpireAtBoundaryAndRetryAcrossPoolRestart',
    'TestReplyLifecycle',
    'TestProfileLifecycle',
    'TestReplyContactRegrantBlocksPendingDispatchAndSave',
    'TestProfileInferenceReviewRegressions',
}
seen = {}
sentinel = 'OK: all D13 integration tests produced exact PASS results; no SKIP or FAIL'
has_sentinel = False
with open(sys.argv[1], encoding='utf-8', errors='replace') as stream:
    for line in stream:
        if line.rstrip('\n') == sentinel:
            has_sentinel = True
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            continue
        test = event.get('Test')
        action = event.get('Action')
        if test in expected and action in {'pass', 'skip', 'fail'}:
            seen.setdefault(test, set()).add(action)
problems = []
for test in sorted(expected):
    actions = seen.get(test, set())
    if actions != {'pass'}:
        problems.append(f'{test}: {sorted(actions) or ["missing"]}')
if not has_sentinel:
    problems.append('strict completion sentinel missing')
if problems:
    print('strict D13 receipt rejected: ' + '; '.join(problems), file=sys.stderr)
    raise SystemExit(1)
print('PASS: strict D13 six top-level tests')
PY
}

run_t35_gate() {
  local mode=$1
  shift
  local -a expected=("$@")
  local log=$logs/t35-$mode.log
  local status=0
  bash app/tool/t35-privacy/gate.sh "$mode" >"$log" 2>&1 || status=$?
  python3 -B - "$log" "$mode" "$status" "${expected[@]}" <<'PY'
import re
import sys

path, mode, raw_status, *expected = sys.argv[1:]
with open(path, encoding='utf-8', errors='replace') as stream:
    lines = [line.rstrip('\n') for line in stream]
passed = [line[len('PASS: '):] for line in lines if line.startswith('PASS: ')]
problems = []
bad = [line for line in lines if line.startswith(('SKIP:', 'FAIL:'))]
if bad:
    problems.append('non-pass terminal lines: ' + ', '.join(bad))
if raw_status != '0':
    problems.append(f'gate exited {raw_status}')
if len(passed) != len(expected) or set(passed) != set(expected):
    problems.append(f'exact PASS set differs: got={sorted(passed)}')
if not lines or lines[-1] != f'T35 privacy gate {mode} PASS':
    problems.append('completion sentinel missing')
if problems:
    print('T35 receipt rejected: ' + '; '.join(problems), file=sys.stderr)
    raise SystemExit(1)
for name in expected:
    print(f'PASS: {name}')
PY
}

case $gate in
  strict)
    if ! bash server/tests/d13-integration.sh >"$logs/strict.log" 2>&1; then
      fail 'strict D13 integration did not complete successfully'
    fi
    verify_strict
    ;;
  d13flutter)
    run_go_tests d13flutter 'integration d13flutter' '^TestD13ReplyFlutter$' no \
      TestD13ReplyFlutter
    verify_d13flutter_stages
    verify_contact_fixture
    ;;
  profile-fence)
    run_go_tests profile-fence integration '^TestProfileDispatchFences$' no \
      TestProfileDispatchFences
    ;;
  reply-cancellation)
    run_go_tests reply-cancellation integration \
      '^TestReplyRoutedDispatchOperationCancellationKeepsAttempt$' no \
      TestReplyRoutedDispatchOperationCancellationKeepsAttempt
    ;;
  t35-reentry)
    run_go_tests t35-reentry integration \
      '^TestProfileActiveReentryBehindAuthorize$|^TestProfileReentryFallsBackForExpiredAndRetryable$' yes \
      TestProfileActiveReentryBehindAuthorize TestProfileReentryFallsBackForExpiredAndRetryable
    ;;
  t35-service)
    run_t35_gate service \
      TestPrivacyAccountRouteContract \
      TestPrivacyAccountBarrierResponse \
      TestPrivacyPhoneOnlyClosureHTTP \
      TestAccountLifecycle \
      TestGrowthRoutesRejectFrozenAccountWithoutGeneratingPlan \
      TestPrivacyExpiredAccountMaintenanceIsolatesFailure \
      TestAIExportGroupsAcrossBusinessRequests \
      TestProfileInferenceRecoversInterruptedExecution \
      TestProfileInferenceSurvivesPopulatedRollback \
      TestExportCommitFailureDoesNotRevealArchive \
      TestExportStreamsLargeIncompressibleEntryBeforeCommit \
      TestExportLateFailureAbortsHTTP2Stream \
      TestExportLateFailureDoesNotEndAsNormalHTTP1Response \
      TestExportLatePanicAbortsResponse
    ;;
  t35-export-ownership)
    run_t35_gate export-ownership TestT35ExportAssessmentOwnership
    ;;
esac

printf 'D13 dedicated CI gate %s PASS\n' "$gate"
