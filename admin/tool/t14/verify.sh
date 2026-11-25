#!/usr/bin/env bash
# T14 real-service check: the shipped /models page saves the next primary model
# over loopback HTTP, then one synthetic App call follows it. Disposable stores
# only; no provider, account, browser or platform credential.
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
test_name=TestT14AdminPageNextAppCall

prerequisite() {
  printf 'T14 verify prerequisite: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'T14 verify: %s\n' "$1" >&2
  exit 1
}

[[ ${T14_DISPOSABLE:-} == yes ]] ||
  prerequisite 'T14_DISPOSABLE=yes is required for disposable loopback stores'
for tool in go flutter python3; do
  command -v "$tool" >/dev/null || prerequisite "$tool must be on PATH"
done
[[ -f $root/server/internal/service/t14_page_next_call_integration_test.go ]] ||
  prerequisite 'missing server/internal/service/t14_page_next_call_integration_test.go'
[[ -f $root/admin/.dart_tool/package_config.json ]] ||
  prerequisite 'run flutter pub get --enforce-lockfile in admin first'

scratch=$(mktemp -d "${TMPDIR:-/tmp}/t14-verify.XXXXXX")
pg_dir=
cache_pid=
ledger_pid=
stop_redis() {
  local pid=$1
  [[ -n $pid ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
cleanup() {
  status=$?
  trap - EXIT
  trap '' INT TERM HUP
  # Only the two children started below; no host-wide service discovery.
  stop_redis "$cache_pid"
  stop_redis "$ledger_pid"
  if [[ -n $pg_dir ]]; then
    pg_ctl -D "$pg_dir" -m fast -w stop >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

provided=0
if [[ -n ${DATABASE_URL:-} ]]; then provided=$((provided + 1)); fi
if [[ -n ${REDIS_URL:-} ]]; then provided=$((provided + 1)); fi
if [[ -n ${LEDGER_URL:-} ]]; then provided=$((provided + 1)); fi
case "$provided" in
  0)
    for tool in initdb pg_ctl createdb redis-server redis-cli openssl; do
      command -v "$tool" >/dev/null || prerequisite "$tool must be on PATH"
    done
    read -r pg_port cache_port ledger_port < <(python3 - <<'PY'
import socket
sockets = []
for _ in range(3):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    sockets.append(listener)
print(*(listener.getsockname()[1] for listener in sockets))
PY
)
    pg_dir="$scratch/pg"
    mkdir "$scratch/cache" "$scratch/ledger"
    initdb -D "$pg_dir" -U t14_local --auth=trust --encoding=UTF8 --no-locale \
      >"$scratch/initdb.log" 2>&1
    pg_ctl -D "$pg_dir" -l "$scratch/postgres.log" \
      -o "-h 127.0.0.1 -p $pg_port -c unix_socket_directories=" -w start >/dev/null
    createdb -h 127.0.0.1 -p "$pg_port" -U t14_local t14_route
    # Foreground mode backgrounded here, so $! is the process we own before it
    # can serve or fail; cleanup waits it instead of racing a daemon pid file.
    redis-server --bind 127.0.0.1 --port "$cache_port" --save '' --appendonly no \
      --daemonize no --dir "$scratch/cache" >"$scratch/cache.log" 2>&1 &
    cache_pid=$!
    # The ledger is append-only with per-write fsync, matching the real one.
    redis-server --bind 127.0.0.1 --port "$ledger_port" --save '' --appendonly yes \
      --appendfsync always --maxmemory-policy noeviction --no-appendfsync-on-rewrite no \
      --aof-load-truncated no --daemonize no --dir "$scratch/ledger" \
      >"$scratch/ledger.log" 2>&1 &
    ledger_pid=$!
    for port in "$cache_port" "$ledger_port"; do
      for ((i = 0; i < 30; i++)); do
        [[ $(redis-cli -p "$port" ping 2>/dev/null || true) == PONG ]] && break
        sleep 0.1
      done
      [[ $(redis-cli -p "$port" ping) == PONG ]]
    done
    [[ $(redis-cli -p "$ledger_port" config get appendonly | tail -1) == yes ]] ||
      fail 'the disposable ledger must be append-only'
    export DATABASE_URL="postgres://t14_local@127.0.0.1:$pg_port/t14_route?sslmode=disable"
    export REDIS_URL="redis://127.0.0.1:$cache_port/0"
    export LEDGER_URL="redis://127.0.0.1:$ledger_port/0"
    export APP_ENV=development PAYMENT_MODE=disabled BACKUP_RETENTION_DAYS=45
    export DATABASE_POOL_MAX_CONNS=20
    export FIELD_KEY_BASE64="$(openssl rand -base64 32)"
    export WLEIS_CONFIG_PATH="$root/server/internal/service/testdata/t26_assessment.yaml"
    ;;
  3)
    if ! python3 - "$DATABASE_URL" "$REDIS_URL" "$LEDGER_URL" <<'PY'
import ipaddress
import sys
import urllib.parse

endpoints = []
for raw in sys.argv[1:]:
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme not in ("postgres", "postgresql", "redis"):
        sys.exit("store URLs must be postgres or redis")
    host = parsed.hostname or ""
    try:
        loopback = ipaddress.ip_address(host).is_loopback
    except ValueError:
        loopback = host == "localhost"
    if not loopback:
        sys.exit("store URLs must stay on loopback")
    endpoints.append((host, parsed.port))
if len(set(endpoints)) != 3:
    sys.exit("use one PostgreSQL and two distinct Redis instances")
PY
    then
      fail 'store URLs must be disposable loopback endpoints'
    fi
    if command -v redis-cli >/dev/null; then
      [[ $(redis-cli -u "$LEDGER_URL" config get appendonly | tail -1) == yes ]] ||
        fail 'the provided ledger must be append-only'
    fi
    ;;
  *)
    fail 'set all of DATABASE_URL, REDIS_URL and LEDGER_URL, or none'
    ;;
esac

cd "$root/server"
log="$scratch/go-test.log"
set +e
go test -tags integration,t14flutter -count=1 -timeout=10m -v \
  -run "^${test_name}$" ./internal/service >"$log" 2>&1
status=$?
set -e
if ((status != 0)); then
  tail -40 "$log" >&2 || true
  fail "go test exited $status"
fi
grep -q "^--- PASS: ${test_name} " "$log" || fail 'the named test did not run to PASS'
if grep -q '^--- SKIP:' "$log"; then
  fail 'the named test was skipped'
fi
grep -q 'T14 page->next call: page_saves=1 audit_ok=1 business_models=t14-one,t14-two' "$log" ||
  fail 'missing page save, audit and next-call receipt'
grep -F 'T14 page->next call:' "$log" | tail -1 | sed 's/^[[:space:]]*/T14 verify: /'
printf 'T14 verify: PASS %s\n' "$test_name"
