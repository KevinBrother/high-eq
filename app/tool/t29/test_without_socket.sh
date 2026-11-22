#!/usr/bin/env bash
# Reproducible fallback for a macOS sandbox that denies the Flutter test
# driver's localhost socket. Runs the original T29 declarations unchanged.
set -euo pipefail
cd "$(dirname "$0")/../.."
flutter_root=${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}
cache="$flutter_root/bin/cache"
dart="$cache/dart-sdk/bin"
if [[ ! -f "$PWD/.dart_tool/package_config.json" ]]; then
  echo "missing app/.dart_tool/package_config.json; run: flutter pub get --enforce-lockfile" >&2
  exit 1
fi
mkdir -p "$PWD/build"
engine=
engine_candidates=(
  "$cache/artifacts/engine/darwin-$(uname -m)"
  "$cache/artifacts/engine/darwin-x64"
)
for candidate in "${engine_candidates[@]}"; do
  if [[ -x "$candidate/flutter_tester" ]]; then
    engine="$candidate"
    break
  fi
done
if [[ -z "$engine" ]]; then
  echo "missing Flutter test engine artifacts under $cache/artifacts/engine" >&2
  exit 1
fi
out=$(mktemp -d "$PWD/build/t29-run.XXXXXX")
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/assets/shaders"
shader="$flutter_root/packages/flutter/lib/src/material/shaders/ink_sparkle.frag"
"$engine/impellerc" --sksl --iplr --input-type=frag --input="$shader" \
  --include="$(dirname "$shader")" --include="$engine/shader_lib" \
  --sl="$out/assets/shaders/ink_sparkle.frag" --spirv="$out/material.spirv"
cat >"$out/runner.dart" <<'DART'
import 'dart:io';
import 'package:flutter_test/flutter_test.dart' show AutomatedTestWidgetsFlutterBinding;
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/suite.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/test.dart';
import '../../test/voice/aggregator_test.dart' as aggregator;
import '../../test/voice/controller_test.dart' as controller;
import '../../test/voice/features_test.dart' as features;
import '../../test/voice/page_test.dart' as page;
import '../../test/voice/platform_test.dart' as platform;
import '../../test/voice/retention_janitor_test.dart' as retentionJanitor;
import '../../test/voice/store_test.dart' as store;
import '../../test/voice/upload_retry_test.dart' as uploadRetry;

void main() async {
  AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  int count = 0, errors = 0;
  for (final register in [
    aggregator.main,
    features.main,
    store.main,
    controller.main,
    uploadRetry.main,
    platform.main,
    retentionJanitor.main,
    page.main,
  ]) {
    final declarer = Declarer();
    declarer.declare(register);
    final suite = Suite(declarer.build(), SuitePlatform(Runtime.vm));
    for (final test in suite.group.entries.cast<Test>()) {
      final live = test.load(suite, groups: [suite.group]);
      live.onError.listen((error) {
        errors++;
        print(error);
      });
      await live.run();
      count++;
      print('${live.state.result}: ${test.name}');
      if (!live.state.result.isPassing) errors++;
      await live.close();
    }
  }
  print('executed $count errors $errors');
  exit(count > 0 && errors == 0 ? 0 : 1);
}
DART
"$dart/dartaotruntime" "$dart/snapshots/frontend_server_aot.dart.snapshot" \
  --sdk-root "$cache/artifacts/engine/common/flutter_patched_sdk/" \
  --target=flutter --enable-asserts --no-print-incremental-dependencies \
  --packages "$PWD/.dart_tool/package_config.json" \
  --output-dill "$out/test.dill" "$out/runner.dart"
FLUTTER_TEST=true "$engine/flutter_tester" --disable-vm-service \
  --enable-checked-mode --enable-software-rendering --skia-deterministic-rendering \
  --use-test-fonts --flutter-assets-dir="$out/assets" "$out/test.dill"
