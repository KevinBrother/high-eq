#!/usr/bin/env bash
# Disposable PG + two independent Redis instances; only loopback synthetic TLS
# models. Do not source .env or reuse a development volume, URL or credential.
set -euo pipefail
cd "$(dirname "$0")/../.."
export HEQ_PG_PASSWORD="$(openssl rand -hex 16)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
tests=(TestPracticeWire TestPublishedPromptPlanRolePlayIntegration)
package=high-eq/server/internal/service
project=
log="$(mktemp .t19-wire.XXXXXX)"
dc(){ docker compose --env-file /dev/null -f docker-compose.yml -p "$project" --profile verify "$@"; }
cleanup(){
  if [[ -n "$project" ]]; then
    dc down -v --remove-orphans >/dev/null
  fi
  rm -f "$log"
}
trap cleanup EXIT

# The parser fixtures are offline and prove that Output text, subtests, empty
# selections and conflicting terminal actions cannot produce a false green.
python3 -B server/tests/test_t19_wire_result.py

index=0
for test in "${tests[@]}"; do
  index=$((index + 1))
  # A fresh project gives each test its own empty PG and both Redis volumes.
  project="t19-wire-${index}-$(openssl rand -hex 6)"
  dc build tests
  dc up -d --wait db cache ledger
  go_status=0
  if dc run --rm --no-deps -e T19_DISPOSABLE=yes tests go test -count=1 -timeout=4m -json -tags integration -run "^${test}$" ./internal/service | tee "$log"; then
    :
  else
    go_status=$?
  fi
  if ! verdict="$(python3 -B server/tests/t19_wire_result.py --package "$package" --test "$test" "$log" 2>&1)"; then
    printf 'T19: %s: %s\n' "$test" "$verdict" >&2
    exit 1
  fi
  if (( go_status != 0 )); then
    printf 'T19: %s: go test exited %d despite a top-level PASS; refusing this result\n' "$test" "$go_status" >&2
    exit 1
  fi
  printf 'T19: %s: %s\n' "$test" "$verdict"
  dc down -v --remove-orphans >/dev/null
  project=
  : >"$log"
done
