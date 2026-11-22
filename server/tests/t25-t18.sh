#!/usr/bin/env bash
# T18 repository + actual generated client + real HTTP. Never use the developer's data volumes.
set -euo pipefail
cd "$(dirname "$0")/../.."
export HEQ_PG_PASSWORD=$(openssl rand -hex 16) HEQ_FIELD_KEY=$(openssl rand -base64 32) HEQ_PORT=0
project="t25-$(openssl rand -hex 5)"
dc(){ docker compose --env-file /dev/null -p "$project" "$@"; }
trap 'dc down -v --remove-orphans >/dev/null' EXIT
dc up --build -d api
export T25_ORIGIN="http://$(dc port api 8080)"
for _ in {1..50}; do curl -fsS --max-time 2 "$T25_ORIGIN/v1/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "$T25_ORIGIN/v1/health" |grep -q '"ok":true'
export T25_DEV_TICKET=$(openssl rand -hex 16)
dc exec -T cache redis-cli SET "dev:ticket:apple:$T25_DEV_TICKET" "synthetic-$(openssl rand -hex 16)" EX 300 >/dev/null
cd app
flutter test --no-pub -r expanded test/contacts/t25_live_test.dart
