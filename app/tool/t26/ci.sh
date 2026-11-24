#!/usr/bin/env bash
# Run on the disposable Linux runner. Only the stores run in containers.
set +x +v
set -euo pipefail
umask 077

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
package=high-eq/server/internal/service
test_name=TestT26NewUserPlanFlutter

prerequisite() {
  printf 'T26 CI prerequisite: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'T26 CI: %s\n' "$1" >&2
  exit 1
}

offline=false
case "$#:${1:-}" in
  0:) ;;
  1:--offline-receipts) offline=true ;;
  *) prerequisite 'expected no arguments or --offline-receipts' ;;
esac

tools=(bash go python3)
paths=(server/go.mod server/tests/t19_wire_result.py)
if ! "$offline"; then
  tools+=(docker flutter openssl)
  paths+=(docker-compose.yml server/internal/service/t26_flutter_journey_integration_test.go
    server/internal/service/testdata/t26_assessment.yaml app/tool/t26/plan_journey_test.dart)
fi
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || prerequisite "$tool must be on PATH"
done
for path in "${paths[@]}"; do
  [[ -f "$path" && -r "$path" ]] || prerequisite "missing $path"
done
if ! "$offline" && [[ ! -s app/.dart_tool/package_config.json ]]; then
  prerequisite 'missing app/.dart_tool/package_config.json; run flutter pub get --enforce-lockfile in app/'
fi
: "${HOME:?T26 CI requires a runner HOME}"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/t26-ci.XXXXXXXX")
started=false
worker=
# Give Compose and Go independent process groups so cancellation also reaches
# their descendants. The direct PID is a fallback before setsid has run.
isolated=(python3 -I -B -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])')
cleanup() {
  local status=$?
  trap - EXIT
  trap '' INT TERM HUP
  if [[ -n "$worker" ]]; then
    kill -TERM -- "-$worker" 2>/dev/null || kill "$worker" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
  fi
  if "$started" && ! "${compose[@]}" down --timeout 5 --volumes --remove-orphans >"$scratch/down.log" 2>&1; then
    printf 'T26 CI: storage cleanup failed for %s\n' "$project" >&2
    if (( status == 0 )); then status=1; fi
  fi
  rm -rf -- "$scratch"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

go_environment=(env -i PATH="$PATH" HOME="$HOME" TMPDIR="$scratch" CI=true
  GOENV=off GOTOOLCHAIN=local GOWORK=off GOAUTH=off)
if "$offline"; then
  checks=(TestT26FixtureFailureReceipt TestT26FlutterAssessmentFixture TestT26FlutterStageReceipt
    TestT26FlutterAssessmentPhaseReceipt TestT26FlutterChatAndScorePhaseReceipt
    TestT26FlutterChatPhaseReceiptWithExistingConsent TestT26FlutterFinishReceipt)
  selection=$(IFS='|'; printf '%s' "${checks[*]}")
  (
    cd server
    exec "${isolated[@]}" "${go_environment[@]}" go test -tags integration,t26flutter \
      -count=1 -timeout=2m -json -run "^(${selection})\$" ./internal/service
  ) >"$scratch/go.jsonl" 2>"$scratch/go.stderr" &
  worker=$!
  go_status=0
  wait "$worker" || go_status=$?
  worker=
  if (( go_status != 0 )); then
    printf 'T26 CI: offline receipt checks: go test exited %d\n' "$go_status" >&2
    exit "$go_status"
  fi
  for check in "${checks[@]}"; do
    python3 -B server/tests/t19_wire_result.py \
      --package "$package" --test "$check" "$scratch/go.jsonl" >/dev/null 2>&1 ||
      fail "offline receipt check did not pass: $check"
  done
  printf 'T26 CI: offline receipt checks passed\n'
  exit 0
fi

docker_compose=(env -i PATH="$PATH" HOME="$scratch" docker --host unix:///var/run/docker.sock compose)
"${docker_compose[@]}" version >/dev/null 2>&1 || prerequisite 'local Docker Compose is required'

pg_password=$(openssl rand -hex 16)
field_key=$(openssl rand -base64 32)
project="t26-ci-$(openssl rand -hex 8)"
cat >"$scratch/ports.yml" <<'YAML'
services:
  db: {ports: ['127.0.0.1::5432']}
  cache: {ports: ['127.0.0.1::6379']}
  ledger: {ports: ['127.0.0.1::6379']}
YAML
compose=(env -i PATH="$PATH" HOME="$scratch" HEQ_PG_PASSWORD="$pg_password"
  HEQ_FIELD_KEY="$field_key" HEQ_PORT=0 docker --host unix:///var/run/docker.sock
  compose --env-file /dev/null --project-name "$project"
  -f docker-compose.yml -f "$scratch/ports.yml")

started=true
"${isolated[@]}" "${compose[@]}" up --detach --no-build --wait --wait-timeout 90 db cache ledger \
  >"$scratch/up.log" 2>&1 &
worker=$!
if ! wait "$worker"; then
  worker=
  fail 'could not start disposable storage'
fi
worker=

published_endpoint() {
  local binding
  binding=$("${compose[@]}" port "$1" "$2" 2>/dev/null) || fail "could not resolve port for $1"
  [[ "$binding" =~ ^127\.0\.0\.1:([1-9][0-9]{0,4})$ ]] &&
    (( BASH_REMATCH[1] <= 65535 )) || fail "invalid loopback port for $1"
  printf '%s\n' "$binding"
}

pg=$(published_endpoint db 5432)
cache=$(published_endpoint cache 6379)
ledger=$(published_endpoint ledger 6379)
[[ "$pg" != "$cache" && "$pg" != "$ledger" && "$cache" != "$ledger" ]] ||
  fail 'storage must use three distinct loopback ports'

printf 'T26 CI: running %s on the host\n' "$test_name"
(
  cd server
  exec "${isolated[@]}" "${go_environment[@]}" \
    T19_DISPOSABLE=yes APP_ENV=development PAYMENT_MODE=disabled BACKUP_RETENTION_DAYS=45 \
    DATABASE_URL="postgres://postgres:$pg_password@$pg/postgres?sslmode=disable" \
    REDIS_URL="redis://$cache/0" LEDGER_URL="redis://$ledger/0" FIELD_KEY_BASE64="$field_key" \
    go test -tags integration,t26flutter -count=1 -timeout=6m -json \
    -run "^${test_name}\$" ./internal/service
) >"$scratch/go.jsonl" 2>"$scratch/go.stderr" &
worker=$!
go_status=0
wait "$worker" || go_status=$?
worker=

# Report only fixed journey, fixture and readback receipts and scoped counts.
# Raw output stays in scratch, including on a compile error or an interrupted test.
python3 -B - "$scratch/go.jsonl" "$package" "$test_name" <<'PY'
import json
import re
import sys

path, package, test = sys.argv[1:]
journey_source = r"[ \t]+t26_flutter_journey_integration_test\.go:[0-9]+: "
fixture_source = r"[ \t]+(?:t26_flutter_journey|training_fixture)_integration_test\.go:[0-9]+: "
fixture_stage = ("operation|listen_provider|load_config|start_runtime|check_model_routes|"
                 "seed_provider_admission|seed_model|seed_model_cost|seed_model_route|"
                 "seed_role_play_prompt|seed_scoring_prompt|listen_api|check_empty_users|issue_apple_proof")
readback_stage = "begin|owner|assessment|practice|plan|commit"
error = "canceled|timeout|connection|database|operation"
location = (
    r"(stage=(?:unreported|login|plan|assessment(?:, phase=(?:load|answer|scene|submit|continueReady))?"
    r"|chat(?:, phase=(?:openPlan|planOpened|consent|chatInput|send|awaitReply|verifyReply|revealFinish))?"
    r"|score(?:, phase=(?:finish|feedback|returnLobby|lobbyCurrent|lobbyBack|returnPlan|"
    r"planCompletion|revealCompletion|readback|verified))?)(?:, finish_before_scroll=(?:hit|miss))?)"
)
patterns = (
    ("", re.compile(journey_source + r"(?:Could not run Flutter T26 journey \("
                    r"|Flutter T26 journey (?:exited successfully \(|exited without a complete receipt \("
                    r"|failed \(exit=-?[0-9]+, |terminated: context (?:canceled|deadline exceeded) \())"
                    + location + r"\)\n?")),
    ("", re.compile(journey_source + r"T26 synthetic readback: "
                    r"(sessions=[0-9]+ saved_turns=[0-9]+ scores=[0-9]+)\n?")),
    ("fixture ", re.compile(fixture_source + rf"T26 fixture: (stage=(?:{fixture_stage}) error=(?:{error}))\n?")),
    ("readback ", re.compile(journey_source + rf"T26 readback: (stage=(?:{readback_stage}) error=(?:{error}))\n?")),
    # Only the assertion enum is printed. Parenthesized detail stays in the raw receipt.
    ("readback ", re.compile(journey_source + rf"T26 readback: (stage=(?:{readback_stage}) error=assertion)"
                              r" \([^\r\n]*\)\n?")),
)
with open(path, encoding="utf-8", errors="replace") as stream:
    for line in stream:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if (isinstance(event, dict) and event.get("Action") == "output"
                and event.get("Package") == package and event.get("Test") == test):
            output = event.get("Output")
            if not isinstance(output, str):
                continue
            for prefix, pattern in patterns:
                if match := pattern.fullmatch(output):
                    print(f"T26 CI: {prefix}{match[1]}")
                    break
PY

verdict_status=0
verdict=$(python3 -B server/tests/t19_wire_result.py \
  --package "$package" --test "$test_name" "$scratch/go.jsonl" 2>&1) || verdict_status=$?
if (( verdict_status != 0 )); then
  printf 'T26 CI: %s\n' "$verdict" >&2
fi
if (( go_status != 0 )); then
  printf 'T26 CI: go test exited %d\n' "$go_status" >&2
  exit "$go_status"
fi
(( verdict_status == 0 )) || exit 1
printf 'T26 CI: %s\n' "$verdict"
