#!/usr/bin/env bash
# Run one test command with a test-only loopback proxy endpoint exposed through
# T29_SENTINEL_PROXY. Do not set HTTP_PROXY/HTTPS_PROXY/ALL_PROXY or clear
# NO_PROXY: the Flutter tool and test runner must keep their own environment.
# The test installs HttpOverrides only inside its own zone for the default
# client positive control; controlled clients explicitly use DIRECT.
set -euo pipefail
[[ $# -gt 0 ]] || {
  echo 'usage: with_sentinel_proxy.sh <command> [args...]' >&2
  exit 2
}

dart_bin=${DART_BIN:-dart}
command -v "$dart_bin" >/dev/null 2>&1 || {
  echo 'T29 proxy isolation prerequisite missing: dart' >&2
  exit 2
}

here=$(cd "$(dirname "$0")" && pwd)
sentinel_dir=$(mktemp -d "${TMPDIR:-/tmp}/t29-proxy-sentinel.XXXXXX")
ready_file="$sentinel_dir/ready"
hit_file="$sentinel_dir/hit"
sentinel_pid=''
cleanup() {
  if [[ -n "$sentinel_pid" ]]; then
    kill "$sentinel_pid" >/dev/null 2>&1 || true
    wait "$sentinel_pid" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$sentinel_dir"
}
trap cleanup EXIT

"$dart_bin" "$here/proxy_sentinel.dart" "$ready_file" "$hit_file" \
  >/dev/null 2>&1 &
sentinel_pid=$!

for _ in {1..200}; do
  [[ -s "$ready_file" ]] && break
  if ! kill -0 "$sentinel_pid" >/dev/null 2>&1; then
    echo 'T29 proxy isolation sentinel failed to start (loopback binding may be unavailable)' >&2
    exit 1
  fi
  sleep 0.05
done
[[ -s "$ready_file" ]] || {
  echo 'T29 proxy isolation sentinel did not become ready' >&2
  exit 1
}

sentinel_port=$(tr -d '[:space:]' <"$ready_file")
[[ "$sentinel_port" =~ ^[0-9]+$ ]] || {
  echo 'T29 proxy isolation sentinel returned an invalid port' >&2
  exit 1
}
proxy="http://127.0.0.1:$sentinel_port"

set +e
env \
  T29_SENTINEL_PROXY="$proxy" \
  FLUTTER_SUPPRESS_ANALYTICS=true \
  "$@"
status=$?
set -e

hits=0
if [[ -e "$hit_file" ]]; then
  hits=$(wc -l <"$hit_file" | tr -d '[:space:]')
  hits=${hits:-0}
fi
if (( status != 0 )); then
  echo "T29 proxy isolation test failed (exit $status)" >&2
  exit "$status"
fi
if [[ "$hits" != 1 ]]; then
  echo "T29 proxy isolation failed: expected one explicit default-client control hit and zero controlled-client hits (observed $hits total)" >&2
  exit 1
fi
echo 'T29 proxy isolation: controlled clients observed zero proxy requests'
