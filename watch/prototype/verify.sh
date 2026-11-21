#!/bin/bash
# Offline verification. Never installs, runs on a device, provisions or archives.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc -swift-version 6 Shared/Wire.swift Tests/main.swift -o "$tmp/check"
"$tmp/check"
xcodebuild -quiet -project T36.xcodeproj -scheme T36Phone -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$tmp/derived" \
  CODE_SIGNING_ALLOWED=NO build
app="$tmp/derived/Build/Products/Debug-iphoneos/T36Phone.app"
watch="$app/Watch/T36Watch.app"
test -x "$app/T36Phone" && test -x "$watch/T36Watch" || exit 1
key() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Info.plist"; }
test "$(key "$app" CFBundleIdentifier)" = "$(key "$watch" WKCompanionAppBundleIdentifier)"
test "$(key "$watch" WKBackgroundModes:0)" = 'workout-processing'
for usage in NSHealthShareUsageDescription NSHealthUpdateUsageDescription NSMotionUsageDescription; do
  test -n "$(key "$watch" "$usage")"
done
printf 'PASS: unsigned companion + embedded watch app, matching IDs, usage strings and background mode\n'
