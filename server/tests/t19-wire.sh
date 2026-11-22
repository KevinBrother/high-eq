#!/usr/bin/env bash
# Disposable PG + two independent Redis instances; only loopback synthetic TLS
# models. Do not source .env or reuse a development volume, URL or credential.
set -euo pipefail
cd "$(dirname "$0")/../.."
export HEQ_PG_PASSWORD="$(openssl rand -hex 16)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
project="t19-$(openssl rand -hex 6)"
dc(){ docker compose --env-file /dev/null -f docker-compose.yml -p "$project" --profile verify "$@"; }
trap 'dc down -v --remove-orphans >/dev/null' EXIT
dc build tests
dc up -d --wait db cache ledger
dc run --rm --no-deps -e T19_DISPOSABLE=yes tests go test -count=1 -timeout=4m -v -tags integration -run '^TestPracticeWire$' ./internal/service
