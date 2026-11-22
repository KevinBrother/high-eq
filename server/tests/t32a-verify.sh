#!/usr/bin/env bash
# A separate compose project, random keys, synthetic Apple tickets only. No .env or personal volumes.
set -euo pipefail
cd "$(dirname "$0")/../.."
export HEQ_PG_PASSWORD="$(openssl rand -hex 16)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
project="t32a-$(openssl rand -hex 8)"
dc(){ docker compose --env-file /dev/null -p "$project" --profile verify "$@"; }
trap 'dc down -v --remove-orphans >/dev/null' EXIT
dc build api tests
dc up -d api
export T32A_ORIGIN="http://$(dc port api 8080)"
for _ in {1..60}; do curl -fsS --max-time 2 "$T32A_ORIGIN/v1/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "$T32A_ORIGIN/v1/health" | grep -q '"ok":true'
dc run --rm --no-deps tests go test -count=1 -tags integration -v -run '^TestT32AMarkLifecycle$' ./internal/service
export T32A_DEV_TICKET="$(openssl rand -hex 24)"
dc exec -T cache redis-cli SET "dev:ticket:apple:$T32A_DEV_TICKET" "synthetic-$(openssl rand -hex 16)" EX 300 | grep -q OK
cd app
flutter test --no-pub -r expanded test/marks/page_test.dart test/marks/book_test.dart test/marks/live_test.dart
