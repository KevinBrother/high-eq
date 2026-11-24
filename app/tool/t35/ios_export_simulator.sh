#!/usr/bin/env bash
# Build without creating a device, or run on one newly created simulator.
set -euo pipefail

tool_dir=$(cd "$(dirname "$0")" && pwd)
probe="$tool_dir/ios_export"
app_dir=$(cd "$tool_dir/../.." && pwd)
runner="$app_dir/ios/Runner"
production=("$runner/PrivacyExportFiles.swift" "$runner/PrivacyExportShare.swift")

local_files_only=false
runner_channel=false

if [[ $# = 1 && ( $1 = --build-only || $1 = --runner-build-only ) ]]; then
  build_only=true
  if [[ $1 = --runner-build-only ]]; then runner_channel=true; fi
else
  build_only=false
  case ${1:-} in
    --local-files-only) local_files_only=true; shift ;;
    --runner) runner_channel=true; shift ;;
  esac
  if [[ $# != 2 || $1 != com.apple.CoreSimulator.SimRuntime.iOS-* || $2 != com.apple.CoreSimulator.SimDeviceType.iPhone-* ]]; then
    printf 'FAIL(simulator.arguments)\n' >&2
    printf 'Usage: %s --build-only | --runner-build-only | [--local-files-only | --runner] <iOS runtime identifier> <iPhone device type identifier>\n' "$0" >&2
    exit 2
  fi
fi

stage=simulator.artifacts
run_dir=""
device=""
result_marker=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ "$status" != 0 ]]; then
    printf 'FAIL(%s)\n' "$stage" >&2
  fi
  if [[ -n "$device" ]]; then
    xcrun simctl shutdown "$device" || true
    if ! xcrun simctl delete "$device"; then
      printf 'FAIL(simulator.cleanup) Could not delete the disposable simulator.\n' >&2
      if [[ "$status" = 0 ]]; then status=1; fi
    fi
  fi
  if [[ -n "$run_dir" ]]; then printf 'T35 artifacts: %s\n' "$run_dir"; fi
  if [[ "$status" = 0 && -n "$result_marker" ]]; then
    printf '%s\n' "$result_marker"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/t35-ios-export.XXXXXXXX")

if $build_only; then
  stage=build.sdk
  sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
  platform=$(xcrun --sdk iphonesimulator --show-sdk-platform-path)
  simulator_flags=(-sdk "$sdk" -swift-version 5 -module-cache-path "$run_dir/modules")
  architecture=$(uname -m)
  if ! $runner_channel; then
    stage=build.bridge
    xcrun --sdk iphonesimulator swiftc "${simulator_flags[@]}" \
      -target "$architecture-apple-ios15.0-simulator" -typecheck "${production[@]}"
    stage=build.probe
    xcrun --sdk iphonesimulator swiftc "${simulator_flags[@]}" \
      -target "$architecture-apple-ios17.0-simulator" -module-name ExportProbe \
      "${production[@]}" "$probe/ProbeApp.swift" "$probe/ExportFixture.swift" \
      "$probe/LocalFilesProbe.swift" -o "$run_dir/ExportProbe"
  fi
  stage=build.ui-tests
  xcrun --sdk iphonesimulator swiftc "${simulator_flags[@]}" \
    -target "$architecture-apple-ios17.0-simulator" -module-name ExportUITests \
    -emit-library -F "$platform/Developer/Library/Frameworks" \
    -I "$platform/Developer/usr/lib" -L "$platform/Developer/usr/lib" \
    "$probe/ExportUITests.swift" "$probe/RunnerExportUITests.swift" \
    -o "$run_dir/ExportUITests.dylib"
  if ! $runner_channel; then
    printf 'T35 Simulator SDK compiled and linked the probe and UI tests\n'
    exit 0
  fi
  printf 'T35 Simulator SDK compiled and linked the Runner UI driver\n'
fi

if $runner_channel; then
  if [[ $(uname -m) != arm64 ]]; then
    printf 'The Runner Simulator build requires an arm64 host\n' >&2
    exit 2
  fi
  runner_app="$run_dir/RunnerDerivedData/Build/Products/Debug-iphonesimulator/Runner.app"
  stage=runner.build
  xcodebuild -workspace "$app_dir/ios/Runner.xcworkspace" -scheme Runner \
    -configuration Debug -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$run_dir/RunnerDerivedData" \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
    "FLUTTER_APPLICATION_PATH=$app_dir" \
    "FLUTTER_TARGET=$probe/runner_export.dart" build 2>&1 | tee "$run_dir/runner-build.log"
  test -x "$runner_app/Runner"
  if $build_only; then exit 0; fi
fi

stage=simulator.create
created=$(xcrun simctl create "T35-iOS-Export-$(uuidgen)" "$2" "$1")
if [[ ! "$created" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  printf 'simctl create did not return a single simulator UUID\n' >&2
  exit 1
fi
device="$created"
stage=simulator.boot
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b

result="$run_dir/ExportProbe.xcresult"
test_selection=ExportUITests/ExportUITests
expected_passes=3
if $local_files_only; then
  test_selection=ExportUITests/ExportLocalFilesUITests/testSaveToOnMyiPhoneSurvivesSourceCleanup
  expected_passes=1
elif $runner_channel; then
  stage=runner.install
  xcrun simctl install "$device" "$runner_app"
  result="$run_dir/RunnerExport.xcresult"
  test_selection=ExportUITests/RunnerExportUITests/testRegisteredFlutterChannelPresentsAndCancelsExport
  expected_passes=1
fi
stage=simulator.test
xcodebuild -project "$probe/ExportProbe.xcodeproj" -scheme ExportProbe \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$device" \
  -derivedDataPath "$run_dir/DerivedData" -resultBundlePath "$result" \
  -parallel-testing-enabled NO -testLanguage en -testRegion US \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  "-only-testing:$test_selection" \
  test 2>&1 | tee "$run_dir/xcodebuild.log"

stage=simulator.summary
xcrun xcresulttool get test-results summary --path "$result" > "$run_dir/summary.json"
python3 - "$run_dir/summary.json" "$expected_passes" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as summary:
    report = json.load(summary)
passed = int(sys.argv[2])
expected = {"totalTestCount": passed, "passedTests": passed, "failedTests": 0, "skippedTests": 0}
actual = {key: report.get(key) for key in expected}
if any(type(actual[key]) is not int for key in expected):
    sys.exit("T35 Simulator acceptance failed: invalid test count")
if actual != expected:
    sys.exit(f"T35 Simulator acceptance failed: {actual!r}")
print(f"T35 Simulator acceptance passed: {passed} passed, 0 failed, 0 skipped")
PY
if $local_files_only; then
  result_marker=T35_LOCAL_FILES_RESULT=PASS
elif $runner_channel; then
  result_marker=T35_RUNNER_EXPORT_RESULT=PASS
fi
