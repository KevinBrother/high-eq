// Safe on an empty emulator. Only discover the bridge; DO NOT call request/read.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/windows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('registered native history bridge; synthetic payload only', (
    _,
  ) async {
    final port = DeviceHealth();
    final source = await port.source();
    if (Platform.isAndroid) {
      expect(
        source,
        const bool.fromEnvironment('EXPECT_RESTRICTED')
            ? 'huawei_history'
            : 'health_connect',
      );
    } else {
      expect(source, anyOf(isNull, 'apple_history'));
    }
    await port.stop();
    expect(
      healthWindows('apple_history', 0, 30000, [
        ['heart_rate', 5000, 5000, 72],
      ]).single['heart_rate']['mean'],
      72,
    );
  });
}
