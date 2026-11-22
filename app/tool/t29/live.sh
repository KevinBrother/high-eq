#!/usr/bin/env bash
# Real T29 client -> T30 HTTP/PG17/Redis. Only loopback and disposable services.
# The device boundary is synthetic PCM and fake OS authorization; never a real
# microphone, vendor, user or production service.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

for command in docker openssl curl dart flutter; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "T29 live prerequisite missing: $command" >&2
    exit 2
  }
done
[[ -f app/.dart_tool/package_config.json ]] || {
  echo 'T29 live prerequisite missing: run flutter pub get in app/' >&2
  exit 2
}
[[ -f app/tool/t29/server_test.go ]] || {
  echo 'T29 live prerequisite missing: app/tool/t29/server_test.go' >&2
  exit 2
}

# Compiler scratch stays inside the disposable tests container, never in a host cache.
export HEQ_PG_PASSWORD="$(openssl rand -hex 24)"
export HEQ_FIELD_KEY="$(openssl rand -base64 32)"
export HEQ_PORT=0
export T29_FIXTURE_TOKEN="$(openssl rand -hex 24)"
export T29_DEV_TICKET="$(openssl rand -hex 16)"
project="t29-$(openssl rand -hex 6)"
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
  -e T29_FIXTURE_TOKEN="$T29_FIXTURE_TOKEN" \
  -v "$root/app/tool/t29/server_test.go:/src/internal/service/t29_live_test.go:ro" \
  tests go test -tags t29live -count=1 -timeout 10m \
  -run '^TestT29LiveServer$' ./internal/service >/dev/null

export T29_ORIGIN="http://$(docker port "$container" 8080/tcp | head -n1)"
ready=false
for _ in {1..180}; do
  if curl --noproxy '*' -fsS --max-time 1 "$T29_ORIGIN/v1/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || {
  echo 'T29 HTTP fixture did not become ready' >&2
  exit 1
}
curl --noproxy '*' -fsS "$T29_ORIGIN/v1/health" | grep -q '"ok":true'

dc exec -T cache redis-cli SET "dev:ticket:apple:$T29_DEV_TICKET" \
  "synthetic-$project" EX 300 >/dev/null

cd "$root/app"
./tool/t29/with_sentinel_proxy.sh \
  flutter --no-version-check --suppress-analytics \
  test --no-pub -r expanded \
  tool/t29/proxy_isolation_test.dart \
  tool/t29/live_test.dart
