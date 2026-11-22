#!/usr/bin/env bash
# Use the host Go toolchain for -race (the minimal API container has no C compiler).
# Isolated, randomly named stores on ephemeral loopback ports. Never source .env.
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
export HEQ_PG_PASSWORD="$(openssl rand -hex 16)" HEQ_FIELD_KEY="$(openssl rand -base64 32)" HEQ_PORT=0
project="t23-$(openssl rand -hex 6)"
override=$(mktemp)
cat >"$override" <<'YAML'
services:
  db: {ports: ['127.0.0.1::5432']}
  cache: {ports: ['127.0.0.1::6379']}
  ledger: {ports: ['127.0.0.1::6379']}
YAML
dc(){ docker compose --env-file /dev/null -f "$root/docker-compose.yml" -f "$override" -p "$project" "$@"; }
cleanup(){ dc down -v --remove-orphans >/dev/null; rm -f "$override"; }
trap cleanup EXIT
dc up --wait -d db cache ledger
export APP_ENV=development BACKUP_RETENTION_DAYS=45 FIELD_KEY_BASE64="$HEQ_FIELD_KEY"
export DATABASE_URL="postgres://postgres:$HEQ_PG_PASSWORD@$(dc port db 5432)/postgres?sslmode=disable"
export REDIS_URL="redis://$(dc port cache 6379)/0" LEDGER_URL="redis://$(dc port ledger 6379)/0"
cd server
go test -race -tags integration,t23 -count=1 -timeout 5m -v \
  -run '^(TestReviewLifecycle|TestReviewMarkLinks|TestProfileReviewSourceLifecycle)$' ./internal/service
