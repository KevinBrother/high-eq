#!/usr/bin/env bash
# Disposable development services. Never point the test at a merchant or production.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d); project="t17-auth-$(basename "$tmp" | tr -cd 'a-z0-9')-$$"
export HEQ_PG_PASSWORD="$(openssl rand -hex 24)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
# Test the committed T05 server, not another card's dirty working directory.
git -C "$root" archive HEAD docker-compose.yml server | tar -x -C "$tmp"
dc() { docker compose -p "$project" -f "$tmp/docker-compose.yml" "$@"; }
cleanup() { dc down --volumes --remove-orphans --rmi local >/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
dc up -d --build api
export T17_LOCAL_PORT
T17_LOCAL_PORT=$(dc port api 8080 | cut -d: -f2)
# Older server snapshots lack these modules. Report coverage explicitly.
export T17_TEST_ASSESSMENT=0 T17_TEST_RIGHTS=0
if [[ -f $tmp/server/internal/service/assessment_http.go ]]; then T17_TEST_ASSESSMENT=1; fi
if [[ -f $tmp/server/internal/service/entitlements_http.go ]]; then T17_TEST_RIGHTS=1; fi
printf 'Live modules under test: accounts=1 assessment=%s rights=%s\n' "$T17_TEST_ASSESSMENT" "$T17_TEST_RIGHTS"
for _ in {1..50}; do
  if curl -fsS "http://127.0.0.1:$T17_LOCAL_PORT/v1/health" >/dev/null; then break; fi
  sleep 1
done
export T17_APPLE_TICKET=$(uuidgen) T17_WECHAT_TICKET=$(uuidgen)
for provider in apple wechat; do
  ticket="$T17_APPLE_TICKET"; if [[ $provider == wechat ]]; then ticket="$T17_WECHAT_TICKET"; fi
  dc exec -T cache redis-cli SET "dev:ticket:$provider:$ticket" "synthetic-$provider" EX 120 >/dev/null
done
cd "$root/app"; flutter test --no-pub test/support/t17_account_smoke.dart
