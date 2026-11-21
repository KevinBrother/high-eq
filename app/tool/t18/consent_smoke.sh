#!/usr/bin/env bash
# Real first-use UI on a booted iOS simulator. Never use a shared database.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
udid=${1:?supply a booted iPhone Simulator UDID}
tmp=$(mktemp -d); project="t18-$(openssl rand -hex 5)"
export HEQ_PG_PASSWORD=$(openssl rand -hex 18) HEQ_FIELD_KEY=$(openssl rand -base64 32) HEQ_PORT=0
# Default: published revision. While T25 awaits merge an isolated reviewed
# T25 source snapshot may be used, not a running/shared service or volume.
service=${T18_SERVICE_ROOT:-$tmp}
if [[ $service == "$tmp" ]]; then git -C "$root" archive HEAD docker-compose.yml server | tar -x -C "$tmp"; fi
dc(){ docker compose --env-file /dev/null -p "$project" -f "$service/docker-compose.yml" "$@"; }
cleanup(){ dc down -v --remove-orphans --rmi local >/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
test -f "$service/server/internal/service/profile_http.go" || { echo 'T25 service source required' >&2; exit 1; }
dc up --build -d api
port=$(dc port api 8080 | cut -d: -f2)
for _ in {1..50}; do curl -fsS "http://127.0.0.1:$port/v1/health" >/dev/null 2>&1 && break; sleep 1; done
curl -fsS "http://127.0.0.1:$port/v1/health" | grep -q '"ok":true'
ticket=$(openssl rand -hex 16)
dc exec -T cache redis-cli SET "dev:ticket:apple:$ticket" "synthetic-$(openssl rand -hex 16)" EX 900 >/dev/null
cd "$root/app"; flutter test --no-pub -r expanded -d "$udid" --dart-define=T18_LOCAL_PORT="$port" --dart-define=T18_DEV_TICKET="$ticket" integration_test/contact_consent_live_test.dart
