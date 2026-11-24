#!/usr/bin/env bash
# Release gate. Supply disposable stores explicitly; never source .env.
set +x +v
set -euo pipefail
umask 077

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
mode=${1:-all}
case "$#:$mode" in
  0:all|1:all|1:client|1:service|1:legacy|1:export-ownership) ;;
  *) echo 'usage: gate.sh [all|client|service|legacy|export-ownership]' >&2; exit 2 ;;
esac

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

require_disposable() {
  if [[ ${T35_PRIVACY_DISPOSABLE:-} != yes || ${APP_ENV:-} != development ]]; then
    echo 'Require T35_PRIVACY_DISPOSABLE=yes and APP_ENV=development on fresh test stores' >&2
    exit 2
  fi
  python3 -B - <<'PY'
from ipaddress import ip_address
import os
from urllib.parse import urlsplit

ports = []
for name, schemes in (
    ("DATABASE_URL", ("postgres", "postgresql")),
    ("REDIS_URL", ("redis",)),
    ("LEDGER_URL", ("redis",)),
):
    try:
        url = urlsplit(os.environ[name])
        if url.scheme not in schemes or not ip_address(url.hostname).is_loopback or not url.port:
            raise ValueError
        ports.append((ip_address(url.hostname), url.port))
    except (KeyError, TypeError, ValueError):
        raise SystemExit(f"{name} must name a disposable numeric loopback endpoint with an explicit port")
if ports[1] == ports[2]:
    raise SystemExit("Cache and deletion ledger must be independent Redis instances")
PY
}

go_receipts() {
  local tags=$1
  shift
  local name status=0 receipt_status=0 selection
  selection=$(IFS='|'; printf '%s' "$*")
  (
    cd server
    go test -mod=readonly -tags "$tags" -count=1 -timeout=8m -json \
      -run "^($selection)\$" ./internal/service
  ) >"$scratch/go.jsonl" 2>"$scratch/go.stderr" || status=$?
  for name in "$@"; do
    if python3 -B server/tests/t19_wire_result.py --package high-eq/server/internal/service \
      --test "$name" "$scratch/go.jsonl" >/dev/null; then
      printf 'PASS: %s\n' "$name"
    else
      printf 'FAIL: %s\n' "$name" >&2
      receipt_status=1
    fi
  done
  if (( status != 0 )); then
    printf 'FAIL: Go test (%s) exited with status %s\n' "$tags" "$status" >&2
    return "$status"
  fi
  return "$receipt_status"
}

client() {
  local status=0
  (cd app && flutter test --no-pub --reporter json test/privacy/account_journey_test.dart) \
    >"$scratch/flutter.jsonl" 2>"$scratch/flutter.stderr" || status=$?
  python3 -B app/tool/t35-privacy/client_receipt.py "$scratch/flutter.jsonl" "$status"
  if (cd app && flutter test --no-pub test/client_test.dart test/onboarding/journey_test.dart \
    test/practice/pending_plan_gesture_test.dart test/replies/entry_test.dart \
    test/health/page_test.dart test/voice/page_test.dart test/privacy/export_journey_test.dart) \
    >"$scratch/flutter-companions.log" 2>&1; then
    echo 'PASS: Flutter companion regressions'
  else
    status=$?
    printf 'FAIL: Flutter companion regressions exited with status %s\n' "$status" >&2
    return "$status"
  fi
}

service() {
  go_receipts contract TestPrivacyAccountRouteContract TestPrivacyAccountBarrierResponse
  go_receipts integration TestPrivacyPhoneOnlyClosureHTTP TestAccountLifecycle \
    TestGrowthRoutesRejectFrozenAccountWithoutGeneratingPlan \
    TestPrivacyExpiredAccountMaintenanceIsolatesFailure \
    TestAIExportGroupsAcrossBusinessRequests \
    TestProfileInferenceRecoversInterruptedExecution \
    TestProfileInferenceSurvivesPopulatedRollback \
    TestExportCommitFailureDoesNotRevealArchive \
    TestExportStreamsLargeIncompressibleEntryBeforeCommit \
    TestExportLateFailureAbortsHTTP2Stream \
    TestExportLateFailureDoesNotEndAsNormalHTTP1Response \
    TestExportLatePanicAbortsResponse
}

t26() {
  T19_DISPOSABLE=yes go_receipts integration,t26flutter TestT26NewUserPlanFlutter
}

t27() {
  : "${T35_PG_BIN:?set the host PostgreSQL 17 bin directory}"
  : "${T35_REDIS_BIN:?set the host redis-server binary}"
  python3 -B app/tool/t27/history_journey.py --pg-bin "$T35_PG_BIN" --redis "$T35_REDIS_BIN"
}

case "$mode" in
  all) require_disposable; client; t26; service; t27 ;;
  client) client ;;
  service) require_disposable; service ;;
  legacy) require_disposable; t26; t27 ;;
  export-ownership) go_receipts integration,t26flutter TestT35ExportAssessmentOwnership ;;
esac
printf 'T35 privacy gate %s PASS\n' "$mode"
