#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
mkdir -p build/t04
file=build/t04/dev.env
if [[ ! -f $file ]]; then
  tmp=$(mktemp build/t04/dev.XXXXXX); trap 'rm -f "$tmp"' EXIT
  printf 'HEQ_PG_PASSWORD=%s\nHEQ_FIELD_KEY=%s\n' "$(openssl rand -hex 24)" "$(openssl rand -base64 32)" >"$tmp"
  ln "$tmp" "$file" || test -f "$file"
fi
dc() { docker compose -p high-eq-dev --env-file "$file" "$@"; }
if (($#)); then dc "$@"; exit; fi
dc up -d --build api
url="http://$(dc port api 8080)/v1/health"
for i in {1..45}; do
  if curl -fsS --max-time 4 "$url" 2>/dev/null | grep -q '"ok":true'; then printf 'Ready: %s\n' "$url"; exit 0; fi
  sleep 1
done
echo 'API not ready: run ./server/dev.sh ps -a and ./server/dev.sh logs api' >&2
exit 1
