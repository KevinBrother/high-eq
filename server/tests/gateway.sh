#!/usr/bin/env bash
# Focused T09 integration test. Never accept a caller-provided DB, cache, or API key.
set -euo pipefail
cd "$(dirname "$0")/.."
pg='' redis=''
cleanup() { for id in "$pg" "$redis"; do if [[ -n $id ]]; then docker rm -f "$id" >/dev/null; fi; done; }
trap cleanup EXIT
pw=$(openssl rand -hex 24)
pg=$(docker run --rm -d -e POSTGRES_PASSWORD="$pw" -p 127.0.0.1::5432 postgres:17)
redis=$(docker run --rm -d -p 127.0.0.1::6379 redis:8.2.0 redis-server --save '')
for i in {1..60}; do
  if docker exec "$pg" pg_isready -h 127.0.0.1 -q && docker exec "$redis" redis-cli ping | grep -q PONG; then break; fi
  sleep 1
done
export DATABASE_URL="postgres://postgres:$pw@$(docker port "$pg" 5432/tcp)/postgres?sslmode=disable"
export REDIS_URL="redis://$(docker port "$redis" 6379/tcp)/0"
migrate -path migrations -database "$DATABASE_URL" up
go test -race -tags integration -v -count=1 ./internal/gateway
