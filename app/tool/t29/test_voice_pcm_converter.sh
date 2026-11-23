#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$here/../.." && pwd)"
test_file="$here/voice_pcm_converter_tests.swift"
cache="$(mktemp -d "${TMPDIR:-/tmp}/t29-pcm-converter.XXXXXX")"
trap 'rm -rf "$cache"' EXIT

xcrun --sdk macosx swiftc \
  -module-cache-path "$cache/modules" \
  -Xcc -fmodules-cache-path="$cache/clang" \
  -framework AVFoundation \
  "$app"/ios/Runner/{VoicePCMConverter,VoicePCMCaptureSession}.swift "$test_file" \
  -o "$cache/voice_pcm_converter_tests"
status=0
"$cache/voice_pcm_converter_tests" || status=1
if [[ "${1:-}" == --replay ]]; then
  "$cache/voice_pcm_converter_tests" --replay "$cache"
  dart "$here/voice_pcm_replay.dart" "$cache" || status=1

  utc_cut_output="$cache/ios-utc-cut"
  mkdir -p "$utc_cut_output"
  xcrun --sdk macosx swiftc -O \
    -module-cache-path "$cache/modules" \
    -Xcc -fmodules-cache-path="$cache/clang" \
    -framework AVFoundation \
    "$app"/ios/Runner/{VoicePCMConverter,VoicePCMCaptureSession}.swift \
    "$here/ios_utc_cut_probe.swift" \
    -o "$cache/ios_utc_cut_probe"
  "$cache/ios_utc_cut_probe" "$utc_cut_output"
  dart "$here/ios_utc_cut_replay.dart" "$utc_cut_output" || status=1
fi
exit "$status"
