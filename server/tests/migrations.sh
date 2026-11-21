#!/usr/bin/env bash
# Starts a disposable database; never accepts an existing database URL.
set -euo pipefail
cd "$(dirname "$0")/.."
password=$(openssl rand -hex 16)
id=$(docker run -d --rm -e POSTGRES_PASSWORD="$password" -p 127.0.0.1::5432 "${PG_TEST_IMAGE:-postgres:17}")
trap 'docker rm -f "$id" >/dev/null' EXIT
port=$(docker port "$id" 5432/tcp | cut -d: -f2)
url="postgres://postgres:$password@127.0.0.1:$port/postgres?sslmode=disable"
psql_test() { docker exec -i "$id" psql -XqAt -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"; }
for ((i=0;i<60;i++)); do docker exec "$id" pg_isready -h 127.0.0.1 -q && break; sleep 1; done
migrate -path migrations -database "$url" up
psql_test < tests/invariants.sql
migrate -path migrations -database "$url" down -all
count=$(psql_test -c "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename <> 'schema_migrations'")
[[ $count == 0 ]] || { echo "Rollback left $count business tables" >&2; exit 1; }
migrate -path migrations -database "$url" up
echo 'OK: up, invariants, down to empty schema, up again'
