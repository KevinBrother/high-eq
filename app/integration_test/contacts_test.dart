import 'support/demo_login.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:high_eq/main.dart';
import 'package:high_eq/core/providers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('从根导航切换场景，进入契约模拟手记并查看只读画像', (t) async {
    final box = ProviderContainer();
    addTearDown(box.dispose);
    final api = await box.read(apiProvider.future);
    await api.sessions.clear();
    await t.pumpWidget(
      UncontrolledProviderScope(container: box, child: const HighEqApp()),
    );
    await t.pumpAndSettle();
    await demoLogin(t);
    await t.tap(find.text('暂不测评'));
    await t.pumpAndSettle();
    Future<void> tap(String label) async {
      final w = find.text(label).last;
      await t.ensureVisible(w);
      await t.tap(w);
      await t.pumpAndSettle();
    }

    await tap('切换练习场景');
    await tap('伴侣');
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    await tap('我的');
    await tap('切换练习场景');
    expect(
      t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '伴侣')).selected,
      true,
    );
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    await tap('关系人手记');
    await tap('老朋友');
    expect(find.textContaining('仅供参考'), findsWidgets);
    expect(find.text('编辑资料'), findsNothing);
    expect(find.text('模拟手记 · 不会发送数据'), findsOneWidget);
  });
}
