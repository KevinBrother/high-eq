#!/bin/sh
# Offline recovery gate. It accepts serving only when the restored database,
# independent deletion ledger and signed-off snapshot ticket all agree.
set -eu
umask 077

ticket_file=${GATE_FILE:-/gate/ticket}
here=$(dirname "$0")

fail() {
  echo "recovery_gate_refused" >&2
  exit 1
}

# Purpose is a property of the controlled target, never a claim made by the
# ticket. Any other service pair fails closed.
expected_purpose() {
  case "${DB_SERVICE:-}:${CACHE_SERVICE:-}" in
    db:cache) printf '%s\n' initial ;;
    restored:coldcache) printf '%s\n' recovery ;;
    *) return 1 ;;
  esac
}

# Read a quiescent synthetic ledger in one Redis operation. TIME and
# PEXPIRETIME use the same clock; opaque markers do not store creation times.
ledger_inventory() {
  [ -n "${LEDGER_URL:-}" ] || fail
  days=${BACKUP_RETENTION_DAYS:-}
  [ "$days" = 45 ] || fail
  mode=${LEDGER_RETENTION_MODE-fresh}
  case "$mode" in
    fresh) [ -z "${LEDGER_DEADLINES:-}${LEDGER_WINDOW_CUTOFFS:-}" ] || fail ;;
    persistent) [ -n "${LEDGER_DEADLINES:-}" ] && [ -z "${LEDGER_WRITES:-}" ] || fail ;;
    *) fail ;;
  esac
  lua='
    local t=redis.call("TIME")
    local out={seal=redis.call("GET","ledger:identity"), now_ms=t[1]*1000+math.floor(t[2]/1000), deadlines={}}
    for _,k in ipairs(redis.call("KEYS","*")) do
      if k~="ledger:identity" then
        if string.sub(k,1,8)~="deleted:" or #k<=8 or redis.call("GET",k)~="" then
          return "invalid"
        end
        out.deadlines[string.sub(k,9)]=redis.call("PEXPIRETIME",k)
      end
    end
    return cjson.encode(out)'
  raw=$(redis-cli -u "$LEDGER_URL" --raw EVAL "$lua" 0 2>/dev/null) || fail
  # First observation proves each independent write interval and window
  # cutoff. Later checks compare the exact absolute deadlines frozen there.
  empty='{}'
  printf '%s\n' "$raw" | jq -ce --argjson days "$days" --arg mode "$mode" \
    --arg missing "${1:-}" --argjson writes "${LEDGER_WRITES:-$empty}" \
    --argjson expected "${LEDGER_DEADLINES:-null}" \
    --argjson cutoffs "${LEDGER_WINDOW_CUTOFFS:-$empty}" '
    def uint: type == "number" and . >= 0 and floor == .;
    def without_missing:
      if $missing == "" then .
      elif has($missing) then del(.[$missing])
      else error("unknown probe root") end;
    ($days * 86400000) as $retention |
    (180 * 86400000) as $upload_lifetime |
    select(type == "object" and
      (.seal | type == "string" and test("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}:45$")) and
      (.now_ms | uint and . > 0) and (.deadlines | type == "object")) |
    .now_ms as $now |
    select(all(.deadlines[]; uint and . > $now)) |
    select(if $mode == "persistent" then
      ($expected | type == "object" and length > 0) and
      ($cutoffs | type == "object") and
      all($cutoffs | to_entries[];
        .key as $root | (.value | uint and . > 0 and . <= $now + $upload_lifetime)
        and ($expected | has($root))) and
      .deadlines == ($expected | without_missing) and
      all($expected | to_entries[];
        ($cutoffs[.key] // 0) as $floor | .value as $end |
        ($end | uint and . > $now and . >= $floor) and
        ($end <= $now + $retention or $end == $floor))
    else
      ($writes | type == "object") and
      (.deadlines | keys) == ($writes | without_missing | keys) and
      all($writes | to_entries[];
        .value as $w | ($w | type == "array" and length == 3 and all(.[]; uint)) and
        ($w[0] > 0 and $w[0] <= $w[1] and $w[1] <= $now and
          $w[0] >= $now - 600000 and $w[2] <= $w[0] + $upload_lifetime)) and
      all(.deadlines | to_entries[];
        $writes[.key] as [$before,$after,$floor] | .value as $end |
        $end >= ([$before + $retention,$floor] | max) and
        $end <= ([$after + $retention,$floor] | max))
    end) | {seal, deadlines}
  ' 2>/dev/null || fail
}

case "${1:-verify}" in
  issue)
    mkdir -p "$(dirname "$ticket_file")"
    partial=$(mktemp "$(dirname "$ticket_file")/.ticket.XXXXXXXX")
    trap 'rm -f "$partial"' EXIT HUP INT TERM
    cat >"$partial"
    python3 "$here/ticket.py" "$partial" || fail
    chmod 0600 "$partial"
    chown postgres:postgres "$partial"
    mv "$partial" "$ticket_file"
    trap - EXIT HUP INT TERM
    echo "ticket_issued"
    ;;
  revoke)
    rm -f "$ticket_file" "$(dirname "$ticket_file")/pending" "$(dirname "$ticket_file")"/.ticket.*
    echo "ticket_revoked"
    ;;
  inventory)
    ledger_inventory
    ;;
  verify|probe-missing)
    purpose=$(expected_purpose) || fail
    days=${BACKUP_RETENTION_DAYS:-}
    [ "$days" = 45 ] || fail
    [ -n "${DATABASE_URL:-}" ] || fail
    ticket=$(python3 "$here/ticket.py" "$ticket_file" "$purpose") || fail
    seal=$(printf '%s\n' "$ticket" | jq -er '.seal') || fail
    missing=''
    if [ "${1:-verify}" = probe-missing ]; then
      [ "$#" -eq 2 ] && [ -n "$2" ] || fail
      [ "$purpose" = recovery ] || fail
      # Only the explicit one-off negative probe may use the scratch copy.
      # The actual permit action always uses the configured authoritative URL.
      case "${LEDGER_URL:-}" in
        */0) LEDGER_URL=${LEDGER_URL%/0}/1 ;;
        *) fail ;;
      esac
      missing=$2
    elif [ "${LEDGER_RETENTION_MODE-fresh}" = persistent ]; then
      [ "$purpose" = recovery ] || fail
    fi

    binding=$(psql "$DATABASE_URL" -XqAt -v ON_ERROR_STOP=1 -c \
      "select ledger_id::text || ':' || ${days} || ':' || (select count(*) from pending_erasure) from ledger_binding" 2>/dev/null) || fail
    [ "$(printf '%s\n' "$binding" | awk 'NF {n++} END {print n+0}')" = 1 ] || fail
    db_seal=$(printf '%s' "$binding" | cut -d: -f1)
    db_days=$(printf '%s' "$binding" | cut -d: -f2)
    pending=$(printf '%s' "$binding" | cut -d: -f3)
    case "$binding" in *:*:*:*) fail ;; esac
    [ "$db_seal:$db_days" = "$seal" ] || fail
    [ "$db_days" = "$days" ] || fail
    [ "$pending" = 0 ] || fail

    inventory=$(ledger_inventory "$missing") || exit 1
    printf '%s\n' "$inventory" | jq -e --argjson ticket "$ticket" --arg missing "$missing" '
      .seal == $ticket.seal and
      ((.deadlines | keys) as $roots |
       if $missing == "" then $roots == ($ticket.roots | sort)
       else ($roots | index($missing)) == null and
            (($roots + [$missing] | sort) == ($ticket.roots | sort)) end)
    ' >/dev/null 2>&1 || fail
    if [ -n "$missing" ]; then
      echo "recovery_gate_refused_missing_root"
      exit 1
    fi
    echo "recovery_gate_ok"
    ;;
  *)
    exit 64
    ;;
esac
