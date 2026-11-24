#!/usr/bin/env bash
# Real T27 app -> T26 growth HTTP -> disposable PG/Redis. Loopback only.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

for command in docker openssl curl flutter grep; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "T27 live prerequisite missing: $command" >&2
    exit 2
  }
done
[[ -f app/.dart_tool/package_config.json && -f app/.dart_tool/package_graph.json ]] || {
  echo 'T27 live prerequisite missing: run flutter pub get in app/' >&2
  exit 2
}

missing=()
[[ -f server/internal/growth/planning.go ]] || missing+=('server/internal/growth/planning.go')
[[ -f server/internal/service/growth_http.go ]] || missing+=('server/internal/service/growth_http.go')
[[ -f server/content/t26.yaml ]] || missing+=('server/content/t26.yaml')
# Do not assume an internal Go constructor or adapter method name. Once the
# feature sources are present, startup and the real assessment -> plan -> check-in
# assertions below decide whether production wiring works. A 501/503 is a failure.
if ((${#missing[@]})); then
  printf 'T27 live prerequisite missing (not a test pass): %s\n' "${missing[*]}" >&2
  exit 2
fi

export HEQ_PG_PASSWORD="$(openssl rand -hex 24)"
export HEQ_FIELD_KEY="$(openssl rand -base64 32)"
export HEQ_PORT=0
export T27_DEV_TICKET="$(openssl rand -hex 24)"
project="t27-$(openssl rand -hex 6)"
dc() {
  docker compose --env-file /dev/null -f "$root/docker-compose.yml" \
    -p "$project" --profile verify "$@"
}
cleanup() {
  dc down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

dc up -d --wait db cache ledger
dc build api
dc up -d --wait api

bound=$(dc port api 8080)
[[ $bound =~ ^127\.0\.0\.1:[0-9]+$ ]] || { echo 'Fixture did not publish its private loopback port' >&2; exit 1; }
origin="http://$bound"
ready=false
for _ in {1..180}; do
  if curl --noproxy '*' -fsS --max-time 1 "$origin/v1/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || {
  dc logs api >&2 || true
  echo 'T27 API fixture did not become ready' >&2
  exit 1
}
curl --noproxy '*' -fsS "$origin/v1/health" | grep -q '"ok":true'

dc exec -T cache redis-cli SET "dev:ticket:apple:$T27_DEV_TICKET" \
  "synthetic-$project" EX 300 >/dev/null

export T27_ORIGIN="$origin"
cd "$root/app"
flutter test --no-pub --reporter "${T27_LIVE_REPORTER:-expanded}" tool/t27/live_test.dart
