#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
case ${1:-} in
 '') exec flutter test --no-pub -r expanded test/replies ;;
 --socketless) ;;
 *) echo 'usage: offline.sh [--socketless]' >&2; exit 2 ;;
esac
# Pinned Flutter 3.38.10 desktop engine; use warmed pub deps and test assets.
root=${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}
c="$root/bin/cache"; e="$c/artifacts/engine"; d="$c/dart-sdk/bin"
case "$(uname -s)-$(uname -m)" in Darwin-*) host=darwin-x64;; Linux-x86_64) host=linux-x64;; *) echo 'unsupported socketless host' >&2; exit 2;; esac
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
"$d/dartaotruntime" "$d/snapshots/frontend_server_aot.dart.snapshot" --sdk-root "$e/common/flutter_patched_sdk/" --target=flutter --no-print-incremental-dependencies --packages "$PWD/.dart_tool/package_config.json" --output-dill "$tmp/test.dill" --enable-asserts "$PWD/tool/t22/socketless.dart"
FLUTTER_TEST=true "$e/$host/flutter_tester" --disable-vm-service --enable-checked-mode --enable-software-rendering --skia-deterministic-rendering --use-test-fonts --flutter-assets-dir="$PWD/build/unit_test_assets" "$tmp/test.dill" 2>&1 | tee "$tmp/engine.log"
# Engine launch alone (or a test abort before summary) is not a pass.
grep -qx "T22: 28 tests, 0 failures" "$tmp/engine.log"
