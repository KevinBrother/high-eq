#!/usr/bin/env bash
# Starts a disposable database; never accepts an existing database URL.
set -euo pipefail
cd "$(dirname "$0")/.."
password=$(openssl rand -hex 16)
id=$(docker run -d --rm -e POSTGRES_PASSWORD="$password" -p 127.0.0.1::5432 "${PG_TEST_IMAGE:-postgres:17}")
trap 'docker rm -f "$id" >/dev/null' EXIT
psql_test() { docker exec -i "$id" psql -XqAt -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
# Docker Desktop can briefly report no published port just after run -d.
# Never build a DSN with an empty port: the driver would try localhost:5432.
endpoint=''
for ((i=0;i<60;i++)); do
  if docker exec "$id" pg_isready -h 127.0.0.1 -q; then
    endpoint=$(docker port "$id" 5432/tcp) || endpoint=''
    [[ $endpoint =~ ^127\.0\.0\.1:[0-9]+$ ]] && break
  fi
  sleep 1
done
[[ $endpoint =~ ^127\.0\.0\.1:[0-9]+$ ]] || { echo 'No disposable PostgreSQL loopback port became ready' >&2; exit 1; }
url="postgres://postgres:$password@$endpoint/postgres?sslmode=disable"
migrate -path migrations -database "$url" up
psql_test < tests/invariants.sql
migrate -path migrations -database "$url" down -all
count=$(psql_test -c "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename <> 'schema_migrations'")
[[ $count == 0 ]] || { echo "Rollback left $count business tables" >&2; exit 1; }
migrate -path migrations -database "$url" up
echo 'OK: up, invariants, down to empty schema, up again'
