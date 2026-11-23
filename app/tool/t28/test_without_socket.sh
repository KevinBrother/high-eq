#!/usr/bin/env bash
# macOS fallback for a sandbox that denies the standard Flutter test driver's
# localhost socket. Uses the pinned SDK and the ORIGINAL test declarations.
set -euo pipefail
cd "$(dirname "$0")/../.."
flutter_root=${FLUTTER_ROOT:-$(cd "$(dirname "$(command -v flutter)")/.." && pwd)}
cache="$flutter_root/bin/cache"; dart="$cache/dart-sdk/bin"; engine="$cache/artifacts/engine"
mkdir -p build; out=$(mktemp -d "$PWD/build/t28-run.XXXXXX"); trap 'rm -rf "$out"' EXIT
mkdir -p "$out/assets/shaders"
shader="$flutter_root/packages/flutter/lib/src/material/shaders/ink_sparkle.frag"
"$engine/darwin-x64/impellerc" --sksl --iplr --input-type=frag --input="$shader" \
  --include="$(dirname "$shader")" --include="$engine/darwin-x64/shader_lib" \
  --sl="$out/assets/shaders/ink_sparkle.frag" --spirv="$out/material.spirv"
cat >"$out/runner.dart" <<'DART'
import 'dart:io';
import 'package:flutter_test/flutter_test.dart' show AutomatedTestWidgetsFlutterBinding;
import 'package:test_api/src/backend/declarer.dart';
import 'package:test_api/src/backend/runtime.dart';
import 'package:test_api/src/backend/suite.dart';
import 'package:test_api/src/backend/suite_platform.dart';
import 'package:test_api/src/backend/test.dart';
import '../../test/health/windows_test.dart' as windows;
import '../../test/health/sync_test.dart' as sync;
import '../../test/health/page_test.dart' as page;
import '../../test/health/logout_regression_test.dart' as logout;
import '../../test/health/huawei_test.dart' as huawei;
import '../../test/health/huawei_release_config_test.dart' as huawei_release;
import '../../tool/t28/loopback_client_test.dart' as loopback;

void main() async {
  AutomatedTestWidgetsFlutterBinding.ensureInitialized();
  int count = 0, errors = 0;
  for (final register in [windows.main, sync.main, page.main, logout.main, huawei.main, huawei_release.main, loopback.main]) {
    final d = Declarer(); d.declare(register);
    final suite = Suite(d.build(), SuitePlatform(Runtime.vm));
    for (final test in suite.group.entries.cast<Test>()) {
      final live = test.load(suite, groups: [suite.group]);
      live.onError.listen((e) { errors++; print(e); });
      await live.run(); count++;
      print('${live.state.result}: ${test.name}');
      if (!live.state.result.isPassing) errors++;
      await live.close();
    }
  }
  print('executed $count errors $errors'); exit(count > 0 && errors == 0 ? 0 : 1);
}
DART
"$dart/dartaotruntime" "$dart/snapshots/frontend_server_aot.dart.snapshot" \
  --sdk-root "$engine/common/flutter_patched_sdk/" --target=flutter --enable-asserts \
  --no-print-incremental-dependencies --packages "$PWD/.dart_tool/package_config.json" \
  --output-dill "$out/test.dill" "$out/runner.dart"
FLUTTER_TEST=true "$engine/darwin-x64/flutter_tester" --disable-vm-service \
  --enable-checked-mode --enable-software-rendering --skia-deterministic-rendering \
  --use-test-fonts --flutter-assets-dir="$out/assets" "$out/test.dill"
