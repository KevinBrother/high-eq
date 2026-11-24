#!/usr/bin/env bash
# Provision fresh stores on the GitHub runner for gate.sh service.
set +x +v
set -euo pipefail
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

fail() { printf 'T35 service FAIL: %s\n' "$1" >&2; exit 1; }

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
pg_password=$(openssl rand -hex 16)
field_key=$(openssl rand -base64 32)
project="t35-privacy-$(openssl rand -hex 8)"
cat >"$scratch/ports.yml" <<'YAML'
services:
  db: {ports: ['127.0.0.1::5432']}
  cache: {ports: ['127.0.0.1::6379']}
  ledger: {ports: ['127.0.0.1::6379']}
YAML

compose=(env -i PATH="$PATH" DOCKER_CONFIG="$scratch/docker" HEQ_PG_PASSWORD="$pg_password"
  HEQ_FIELD_KEY="$field_key" HEQ_PORT=0 docker --host unix:///var/run/docker.sock
  compose --env-file /dev/null --project-name "$project"
  -f docker-compose.yml -f "$scratch/ports.yml")

cleanup() {
  local status=$?
  if ! "${compose[@]}" down --volumes --remove-orphans >"$scratch/cleanup.log" 2>&1; then
    echo 'T35 service FAIL: could not remove disposable storage' >&2
    if (( status == 0 )); then status=1; fi
  fi
  rm -rf -- "$scratch"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

"${compose[@]}" up --detach --no-build --wait --wait-timeout 90 db cache ledger \
  >"$scratch/startup.log" 2>&1 || fail 'could not start disposable storage'

published_endpoint() {
  local binding
  binding=$("${compose[@]}" port "$1" "$2" 2>"$scratch/port.stderr") || fail "could not resolve $1 port"
  [[ "$binding" =~ ^127\.0\.0\.1:([1-9][0-9]{0,4})$ ]] && \
    (( BASH_REMATCH[1] <= 65535 )) || fail "invalid loopback port for $1"
  printf '%s\n' "$binding"
}

pg=$(published_endpoint db 5432)
cache=$(published_endpoint cache 6379)
ledger=$(published_endpoint ledger 6379)
[[ "$pg" != "$cache" && "$pg" != "$ledger" && "$cache" != "$ledger" ]] || \
  fail 'storage must use three distinct loopback ports'

T35_PRIVACY_DISPOSABLE=yes APP_ENV=development PAYMENT_MODE=disabled BACKUP_RETENTION_DAYS=45 \
  DATABASE_URL="postgres://postgres:$pg_password@$pg/postgres?sslmode=disable" \
  REDIS_URL="redis://$cache/0" LEDGER_URL="redis://$ledger/0" FIELD_KEY_BASE64="$field_key" \
  bash app/tool/t35-privacy/gate.sh service
