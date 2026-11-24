#!/usr/bin/env bash
# Prove public DELETE fencing, timer recovery, and fail-closed startup with the
# real cmd/api process.
# Run only with a fresh synthetic PostgreSQL and two independent Redis services.
set -euo pipefail
cd "$(dirname "$0")/../.."
export HEQ_PG_PASSWORD="$(openssl rand -hex 16)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
project="t35-process-$(openssl rand -hex 6)"
log=$(mktemp)
dc() { docker compose --env-file /dev/null -p "$project" --profile verify "$@"; }
cleanup() {
  rm -f "$log"
  dc down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

dc build tests
dc up -d --wait db cache ledger
dc run --rm --no-deps tests sh -eu -c '
  go build -o /tmp/t35-api ./cmd/api
  T35_API_BIN=/tmp/t35-api go test -count=1 -timeout=5m -v \
    -tags "integration process" \
    -run "^(TestContactDeletionPublicDeleteBarrier|TestContactDeletionProcessTicker|TestContactDeletionStartupFailClosed)$" \
    ./internal/service
' | tee "$log"

if grep -Eq '^[[:blank:]]*--- SKIP:' "$log"; then
  echo 'T35 process regression skipped' >&2
  exit 1
fi
for test in TestContactDeletionPublicDeleteBarrier TestContactDeletionProcessTicker TestContactDeletionStartupFailClosed; do
  if ! grep -Eq "^--- PASS: ${test} \\(" "$log"; then
    echo "T35 required process test did not pass: $test" >&2
    exit 1
  fi
done
echo 'OK: public DELETE fencing, real minute ticker recovery, and startup fail-closed'
