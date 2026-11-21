#!/bin/bash
# Run from app/. Does not discover a Dart debug socket via simulator logs.
set -euo pipefail
udid=${1:?supply a booted iPhone simulator UDID}
flutter build ios --config-only --simulator --debug --no-pub --target=tool/ios_smoke.dart
xcodebuild -quiet -jobs 3 -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -destination "id=$udid" -derivedDataPath build/native-tests \
  ONLY_ACTIVE_ARCH=YES build
bundle=cn.higheq.highEq
xcrun simctl install "$udid" build/native-tests/Build/Products/Debug-iphonesimulator/Runner.app
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
receipt="$data/tmp/t16-smoke.result"
rm -f "$receipt"
log=$(mktemp)
trap 'rm -f "$log"' EXIT
xcrun simctl launch --terminate-running-process --stdout="$log" --stderr="$log" "$udid" "$bundle"
for ((i=0; i<150; i++)); do
  if [[ -f "$receipt" ]]; then
    if grep -Eq '^PASS [1-9][0-9]*$' "$receipt"; then cat "$receipt"; echo; exit 0; fi
    break
  fi
  sleep 2
done
# Output only test status, never dump application/network logs.
grep -E 'Test failed|EXCEPTION CAUGHT|Test timed out|Some tests failed' "$log" | tail -5 || true
echo 'Simulator smoke suite failed or did not finish' >&2
exit 1
