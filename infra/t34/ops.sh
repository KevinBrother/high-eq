#!/bin/sh
# Test environment only. Fixed directory, immutable completed bundles, no external sinks.
set -eu
umask 077
export PGCONNECT_TIMEOUT=10

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

valid_snapshot_name() {
  case "$1" in
    snap-*) rest=${1#snap-} ;;
    *) return 1 ;;
  esac
  [ -n "$rest" ] || return 1
  case "$rest" in *[!A-Za-z0-9]*) return 1 ;; esac
}

backup() (
  start=$(date -u +%s)
  d=$(mktemp -d "${VAULT_DIR:-/vault}/.partial.XXXXXXXX")
  trap 'rm -rf "$d"' EXIT HUP INT TERM
  pg_dump --no-owner --no-acl -Fc -f "$d/business.dump" 2>/dev/null || fail backup_failed
  (cd "$d" && sha256sum business.dump > SHA256SUMS)
  printf '%s %s %s\n' "$start" "$((start + 45*86400))" "${INSTALLATION:?}" > "$d/inventory"
  name=snap-${d##*.}
  mv "$d" "${VAULT_DIR:-/vault}/$name"
  trap - EXIT HUP INT TERM
  printf '%s\n' "$name"
)

prune() {
  vault=${VAULT_DIR:-/vault}
  for d in "$vault"/snap-*; do
    [ -d "$d" ] || continue
    name=${d##*/}
    valid_snapshot_name "$name" || fail backup_invalid_name
    [ -s "$d/inventory" ] || fail backup_invalid_inventory
    read -r start expires scope extra < "$d/inventory" || fail backup_invalid_inventory
    [ -z "${extra:-}" ] && [ "$scope" = "${INSTALLATION:?}" ] || fail backup_scope_mismatch
    case "$start:$expires" in *[!0-9:]*) fail backup_invalid_inventory ;; esac
    [ "$expires" = "$((start + 45*86400))" ] || fail backup_invalid_inventory
    # One-day margin for sweep cadence; restore also enforces absolute expiry.
    [ "$(date -u +%s)" -lt "$((expires-86400))" ] || rm -rf "$d"
  done
}

backup_health() {
  vault=${VAULT_DIR:-/vault}
  max_age=${BACKUP_MAX_AGE:-93600}
  case "$max_age" in ''|*[!0-9]*) fail backup_health_invalid ;; esac
  now=$(date -u +%s)
  newest=
  for d in "$vault"/snap-*; do
    [ -d "$d" ] || continue
    name=${d##*/}
    valid_snapshot_name "$name" || fail backup_invalid_name
    [ -s "$d/business.dump" ] && [ -s "$d/SHA256SUMS" ] && [ -s "$d/inventory" ] || fail backup_incomplete
    read -r start expires scope extra < "$d/inventory" || fail backup_invalid_inventory
    [ -z "${extra:-}" ] && [ "$scope" = "${INSTALLATION:?}" ] || fail backup_scope_mismatch
    case "$start:$expires" in *[!0-9:]*) fail backup_invalid_inventory ;; esac
    [ "$expires" = "$((start + 45*86400))" ] || fail backup_invalid_inventory
    if [ "$now" -ge "$expires" ]; then
      printf 'backup_stale age=%s max_age=%s\n' "$((now-start))" "$max_age" >&2
      exit 1
    fi
    if [ -z "$newest" ] || [ "$start" -gt "$newest" ]; then newest=$start; fi
  done
  [ -n "$newest" ] || fail backup_missing
  if [ "$now" -lt "$newest" ] || [ "$((now-newest))" -gt "$max_age" ]; then
    printf 'backup_stale age=%s max_age=%s\n' "$((now-newest))" "$max_age" >&2
    exit 1
  fi
  printf 'backup_fresh age=%s max_age=%s\n' "$((now-newest))" "$max_age"
}

restore() {
  snapshot=${1:-}
  valid_snapshot_name "$snapshot" || fail restore_invalid_snapshot
  vault=${VAULT_DIR:-/vault}
  d="$vault/$snapshot"
  [ -d "$d" ] && [ ! -L "$d" ] || fail restore_snapshot_missing
  [ -s "$d/business.dump" ] && [ -s "$d/SHA256SUMS" ] && [ -s "$d/inventory" ] || fail restore_incomplete_snapshot
  read -r start expires scope extra < "$d/inventory" || fail restore_invalid_inventory
  [ -z "${extra:-}" ] && [ "$scope" = "${INSTALLATION:?}" ] || fail restore_scope_mismatch
  case "$start:$expires" in *[!0-9:]*) fail restore_invalid_inventory ;; esac
  [ "$expires" = "$((start + 45*86400))" ] || fail restore_invalid_inventory
  now=$(date -u +%s)
  [ "$now" -ge "$start" ] && [ "$now" -lt "$expires" ] || fail restore_snapshot_expired
  (cd "$d" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || fail restore_checksum_failed
  public_tables=$(psql -XqAt -v ON_ERROR_STOP=1 -c "select count(*) from pg_tables where schemaname='public'") || fail restore_target_unavailable
  [ "$public_tables" = 0 ] || fail restore_target_not_empty
  pg_restore --single-transaction --exit-on-error --no-owner --no-acl \
    -U "${PGUSER:-postgres}" -d "${PGDATABASE:-postgres}" "$d/business.dump" || fail restore_failed
  printf 'restore_ok snapshot=%s sha256=%s\n' "$snapshot" "$(awk 'NR==1 {print $1}' "$d/SHA256SUMS")"
}

alert() {
  status=$1
  [ -n "${ALERT_WEBHOOK:-}" ] || {
    printf 'alert_webhook_missing status=%s\n' "$status" >&2
    return 1
  }
  if ! curl --fail --silent --show-error --max-time 10 --retry 2 --retry-delay 1 \
    --output /dev/null -H 'Content-Type: application/json' \
    --data "{\"source\":\"t34-cost-monitor\",\"status\":\"$status\"}" \
    "$ALERT_WEBHOOK" 2>/dev/null; then
    printf 'alert_delivery_failed status=%s\n' "$status" >&2
    return 1
  fi
}

monitor_once() {
  if raw=$(psql -XqAt -v ON_ERROR_STOP=1 -f /ops/cost.sql 2>/dev/null); then
    statuses=$(printf '%s\n' "$raw" | tr ',' '\n' | awk 'length($0) > 0')
  else
    statuses=monitor_unavailable
  fi
  [ -n "$statuses" ] || statuses=normal
  printf '%s\n' "$statuses" | {
    failed=0
    summary=
    while IFS= read -r status; do
      case "$status" in
        normal) ;;
        cost_anomaly|unpriced|monitor_unavailable)
          if ! alert "$status"; then failed=1; fi
          ;;
        *)
          printf 'monitor_invalid_status\n' >&2
          failed=1
          status=monitor_invalid_status
          ;;
      esac
      summary=${summary}${summary:+,}$status
    done
    printf 'ai_cost=%s sink=webhook\n' "$summary"
    [ "$failed" -eq 0 ]
  }
}

# One-shot staging readiness check, separate from the periodic cost alerts.
monitor_probe() {
  local_sink=http://alert-sink:8080/alerts
  [ "${ALERT_WEBHOOK:-}" = "$local_sink" ] || fail monitor_probe_route_refused
  status=$(curl --fail --silent --show-error --noproxy '*' --max-time 10 \
    --output /dev/null --write-out '%{http_code}' \
    -H 'Content-Type: application/json' \
    --data '{"source":"t34-cost-monitor","status":"synthetic_probe"}' "$local_sink") || fail monitor_probe_delivery_failed
  [ "$status" = 202 ] || fail monitor_probe_not_acknowledged
}

case "${1:-}" in
  once) prune; backup;;
  daily) while :; do prune; backup >/dev/null; echo backup_ok; sleep 86400; done;;
  backup-health) backup_health;;
  restore) restore "${2:-}";;
  monitor-once) monitor_once;;
  monitor-probe) monitor_probe;;
  monitor) while :; do monitor_once; sleep 300; done;;
  *) exit 64;;
esac
