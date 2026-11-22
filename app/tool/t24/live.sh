#!/usr/bin/env bash
# Real T24 client -> T23 HTTP -> disposable PG/Redis. Only the vendor is synthetic.
set -euo pipefail
root=$(cd "$(dirname "$0")/../../.." && pwd)
cd "$root"

for command in docker openssl curl flutter; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "T24 live prerequisite missing: $command" >&2
    exit 2
  }
done
[[ -f app/.dart_tool/package_config.json && -f app/.dart_tool/package_graph.json ]] || {
  echo 'T24 live prerequisite missing: run flutter pub get in app/' >&2
  exit 2
}

test_file="server/internal/service/reviews_vendor_integration_test.go"
grep -q '^//go:build integration || t24live$' "$test_file" || {
  echo 'T24 test bridge prerequisite missing: reviews_vendor_integration_test.go needs the t24live tag' >&2
  exit 2
}

export HEQ_PG_PASSWORD="$(openssl rand -hex 24)"
export HEQ_FIELD_KEY="$(openssl rand -base64 32)"
export HEQ_PORT=0
export T24_FIXTURE_TOKEN="$(openssl rand -hex 24)"
project="t24-$(openssl rand -hex 6)"
container="$project-http"
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
  -e T24_FIXTURE_TOKEN="$T24_FIXTURE_TOKEN" \
  -v "$root/app/tool/t24/server_test.go:/src/internal/service/t24_live_test.go:ro" \
  tests go test -tags t24live -count=1 -timeout 10m \
  -run '^TestT24LiveServer$' ./internal/service >/dev/null

export T24_ORIGIN="http://$(docker port "$container" 8080/tcp)"
ready=false
for _ in {1..180}; do
  if curl --noproxy '*' -fsS --max-time 1 "$T24_ORIGIN/v1/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
[[ "$ready" == true ]] || {
  docker logs "$container" >&2 || true
  echo 'T24 HTTP fixture did not become ready' >&2
  exit 1
}
curl --noproxy '*' -fsS "$T24_ORIGIN/v1/health" | grep -q '"ok":true'

export T24_DEV_TICKET="$(openssl rand -hex 16)"
dc exec -T cache redis-cli SET "dev:ticket:apple:$T24_DEV_TICKET" \
  "synthetic-$project" EX 300 >/dev/null

cd "$root/app"
flutter test --no-pub -r expanded tool/t24/live_test.dart
