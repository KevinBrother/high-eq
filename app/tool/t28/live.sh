#!/usr/bin/env bash
# Real T28 HealthSync -> T30 HTTP/PG17/dual Redis. Only loopback and disposable
# services. The device boundary is synthetic historical samples plus fake OS
# authorization; it never reads a real health store or uses production services.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

for command in docker openssl curl flutter; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "T28 live prerequisite missing: $command" >&2
    exit 2
  }
done
[[ -f app/.dart_tool/package_config.json ]] || {
  echo 'T28 live prerequisite missing: run flutter pub get in app/' >&2
  exit 2
}
[[ -f app/tool/t28/server_test.go ]] || {
  echo 'T28 live prerequisite missing: app/tool/t28/server_test.go' >&2
  exit 2
}

# Compiler scratch stays inside the disposable tests container, never in a host cache.
export HEQ_PG_PASSWORD="$(openssl rand -hex 24)"
export HEQ_FIELD_KEY="$(openssl rand -base64 32)"
export HEQ_PORT=0
export T28_FIXTURE_TOKEN="$(openssl rand -hex 24)"
export T28_DEV_TICKET="$(openssl rand -hex 16)"
project="t28-$(openssl rand -hex 6)"
container="$project-http"

# --env-file /dev/null prevents Compose from loading a developer .env file.
dc() {
  docker compose --env-file /dev/null -f "$root/docker-compose.yml" \
    -p "$project" --profile verify "$@"
}
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  dc down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

dc up -d --wait db cache ledger
dc build tests
dc run --no-deps -d --name "$container" \
  -p 127.0.0.1::8080 \
  -e T28_FIXTURE_TOKEN="$T28_FIXTURE_TOKEN" \
  -v "$root/app/tool/t28/server_test.go:/src/internal/service/t28_live_test.go:ro" \
  tests go test -tags t28live -count=1 -timeout 10m \
  -run '^TestT28LiveServer$' ./internal/service >/dev/null

export T28_ORIGIN="http://$(docker port "$container" 8080/tcp | head -n1)"
ready=false
for _ in {1..180}; do
  if curl --noproxy '*' -fsS --max-time 1 "$T28_ORIGIN/v1/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || {
  docker logs "$container" >&2 || true
  echo 'T28 HTTP fixture did not become ready' >&2
  exit 1
}
curl --noproxy '*' -fsS "$T28_ORIGIN/v1/health" | grep -q '"ok":true'

dc exec -T cache redis-cli SET "dev:ticket:apple:$T28_DEV_TICKET" \
  "synthetic-$project" EX 300 >/dev/null

cd "$root/app"
flutter test --no-pub -r expanded \
  tool/t28/loopback_client_test.dart tool/t28/live_test.dart
