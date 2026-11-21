// Simulator-only runner. Receipts contain only the test count and outcome and
// are emitted after Flutter has finished the same suite used by Android.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import '../../integration_test/smoke_test.dart' as suite;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Standalone launches (unlike `flutter test`) can start before iOS has
  // attached the engine's accessibility handle. Establish the platform view
  // before testWidgets snapshots its outstanding handles. Do not disable it.
  setUpAll(() async {
    final previous = binding.framePolicy;
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    runApp(const SizedBox.shrink());
    await binding.waitUntilFirstFrameRasterized.timeout(
      const Duration(seconds: 40),
    );
    binding.framePolicy = previous;
  });
  suite.main();
  binding.allTestsPassed.future.then((passed) async {
    final count = binding.results.length;
    final file = File('${Directory.systemTemp.path}/t16-smoke.new');
    await file.writeAsString(
      passed && count > 0 ? 'PASS $count' : 'FAIL',
      flush: true,
    );
    await file.rename('${Directory.systemTemp.path}/t16-smoke.result');
  });
}
