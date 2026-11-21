#!/usr/bin/env bash
# Never consume project .env / dev volumes; test real service startup and AOF restart.
set -euo pipefail
cd "$(dirname "$0")/../.."
export HEQ_PG_PASSWORD=$(openssl rand -hex 16) HEQ_FIELD_KEY=$(openssl rand -base64 32) HEQ_PORT=0
project="t04-$(openssl rand -hex 5)"
dc() { docker compose --env-file /dev/null -p "$project" --profile verify "$@"; }
trap 'dc down -v --remove-orphans >/dev/null' EXIT
dc build api tests
dc up -d api
url="http://$(dc port api 8080)/v1/health"
check(){ curl -fsS --max-time 5 "$url" |grep -q '"ok":true'; }
for i in {1..50}; do if check 2>/dev/null; then break; fi;sleep 1; done
check || { dc logs api; exit 1; }
dc run --rm --no-deps tests
before=$(dc exec -T ledger redis-cli --raw keys 'deleted:*' | sort)
[[ -n $before ]]
dc restart ledger
for i in {1..30}; do if dc exec -T ledger redis-cli ping 2>/dev/null | grep -q PONG; then break; fi; sleep 1; done
dc restart api
url="http://$(dc port api 8080)/v1/health"
for i in {1..30}; do if check 2>/dev/null; then break; fi; sleep 1; done
check; [[ $(dc exec -T ledger redis-cli --raw keys 'deleted:*' | sort) == "$before" ]]
dc stop ledger
[[ $(curl -sS --max-time 6 -o /dev/null -w '%{http_code}' "$url") == 500 ]]
dc run --rm --no-deps -e T04_LEDGER_OFFLINE=1 tests go test -count=1 -tags integration -run "^TestOfflineLedger$" ./internal/privacy
echo 'OK: migrated service, guarded transactions, restart persistence, dependency failure'
