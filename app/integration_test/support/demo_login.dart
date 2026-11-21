import 'package:flutter_test/flutter_test.dart';

/// Only call on an empty, contract-mode installation. Never contacts a provider.
Future<void> demoLogin(WidgetTester t) async {
  for (final label in ['我已阅读并同意', '同意并继续', '我已满 14 周岁', '微信登录']) {
    final item = find.text(label);
    await t.ensureVisible(item);
    await t.pumpAndSettle();
    await t.tap(item);
    await t.pumpAndSettle();
  }
}
