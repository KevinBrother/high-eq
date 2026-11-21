#!/usr/bin/env bash
# Real T21 HTTP + disposable PG/Redis. Only the model/moderation runner is synthetic.
set -euo pipefail
cd "$(dirname "$0")/../../.."
[[ -f server/internal/service/replies_http.go ]] || { echo 'T21 service prerequisite missing (not a fixture pass)' >&2; exit 2; }
export HEQ_PG_PASSWORD="$(openssl rand -hex 24)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
project="t22-$(openssl rand -hex 6)"; container="$project-http"
dc(){ docker compose --env-file /dev/null -p "$project" --profile verify "$@"; }
cleanup(){ docker rm -f "$container" >/dev/null 2>&1 || true; dc down -v --remove-orphans >/dev/null; }
trap cleanup EXIT
dc up -d --wait db cache ledger
dc build tests
dc run --no-deps -d --name "$container" -p 127.0.0.1::8080 -v "$PWD/app/tool/t22/server_test.go:/src/internal/service/t22_live_test.go:ro" tests go test -tags t22live -count=1 -timeout 10m -run '^TestT22LiveServer$' ./internal/service >/dev/null
export T22_ORIGIN="http://$(docker port "$container" 8080/tcp)"
for _ in {1..180}; do curl --noproxy '*' -fsS --max-time 1 "$T22_ORIGIN/v1/health" >/dev/null 2>&1 && break; sleep 1; done
curl --noproxy '*' -fsS "$T22_ORIGIN/v1/health" | grep -q '"ok":true'
export T22_DEV_TICKET="$(openssl rand -hex 16)"
dc exec -T cache redis-cli SET "dev:ticket:apple:$T22_DEV_TICKET" "synthetic-$project" EX 300 >/dev/null
cd app
flutter test --no-pub -r expanded tool/t22/live_test.dart
