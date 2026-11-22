#!/usr/bin/env bash
# Disposable T19 service + PG/Redis. Only loopback scripted providers are used;
# no model, moderation, user, or production endpoint is contacted.
set -euo pipefail
cd "$(dirname "$0")/../../.."
for prerequisite in \
  server/internal/service/training_fixture_integration_test.go \
  server/internal/service/training_integration_test.go \
  server/internal/training/send.go \
  server/internal/training/finish.go \
  app/tool/t20/server_test.go; do
  [[ -f $prerequisite ]] || {
    echo "T20 live prerequisite missing: $prerequisite (not a fixture pass)" >&2
    exit 2
  }
done
export HEQ_PG_PASSWORD="$(openssl rand -hex 24)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
project="t20-$(openssl rand -hex 6)"
container="$project-server"
dc(){ docker compose --env-file /dev/null -p "$project" --profile verify "$@"; }
cleanup(){
  docker rm -f "$container" >/dev/null 2>&1 || true
  dc down -v --remove-orphans >/dev/null
}
trap cleanup EXIT
dc up -d --wait db cache ledger
dc build tests
dc run --no-deps -d --name "$container" -p 127.0.0.1::8080 \
  -v "$PWD/app/tool/t20/server_test.go:/src/internal/service/t20_live_test.go:ro" \
  tests env T20_DISPOSABLE=yes go test -tags t20live -count=1 -timeout 10m \
  -run '^TestT20LiveServer$' ./internal/service >/dev/null
export T20_ORIGIN="http://$(docker port "$container" 8080/tcp)"
ready=false
for _ in {1..180}; do
  if ! docker inspect -f '{{.State.Running}}' "$container" | grep -q true; then
    docker logs "$container" >&2
    exit 1
  fi
  if curl --noproxy '*' -fsS --max-time 1 "$T20_ORIGIN/v1/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ $ready != true ]]; then
  docker logs "$container" >&2
  echo "T20 live server did not become healthy" >&2
  exit 1
fi
curl --noproxy '*' -fsS "$T20_ORIGIN/v1/health" | grep -q '"ok":true'
export T20_DEV_TICKET="$(openssl rand -hex 16)"
dc exec -T cache redis-cli SET "dev:ticket:apple:$T20_DEV_TICKET" \
  "synthetic-$project" EX 300 >/dev/null
export T20_TERMINAL_TICKET="$(openssl rand -hex 16)"
dc exec -T cache redis-cli SET "dev:ticket:apple:$T20_TERMINAL_TICKET" "synthetic-terminal-$project" EX 300 >/dev/null
cd app
flutter test --no-pub -r expanded tool/t20/live_test.dart
