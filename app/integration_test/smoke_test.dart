import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:high_eq/main.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('on-device navigation, native secret store and A/B isolation', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final api = await container.read(apiProvider.future);
    expect(await api.json(AppOp.checkHealth), {'ok': true});
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const HighEqApp()),
    );
    await tester.pumpAndSettle();
    for (final label in ['实战', '成长', '我的', '练习']) {
      await tester.tap(
        find
            .descendant(
              of: find.byType(NavigationBar),
              matching: find.text(label),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.text(label), findsWidgets);
      expect(
        tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
        ['练习', '实战', '成长', '我的'].indexOf(label),
      );
    }
    Tokens tokens(String id) => Tokens(
      id,
      'test-access',
      'test-refresh',
      DateTime.now().add(const Duration(hours: 1)),
    );
    final a = await api.sessions.activate(tokens('A'));
    for (final k in CacheKind.values) {
      await api.sessions.put(a, k, 'last', utf8.encode('A-data'));
    }
    await api.sessions.restore();
    final restored = api.sessions.active!;
    expect(
      utf8.decode((await api.sessions.get(restored, CacheKind.queue, 'last'))!),
      'A-data',
    );
    await api.logout(restored);
    final b = await api.sessions.activate(tokens('B'));
    for (final k in CacheKind.values) {
      expect(await api.sessions.get(b, k, 'last'), isNull);
    }
    await expectLater(
      api.json(AppOp.getMe, scope: restored),
      throwsA(isA<SessionChanged>()),
    );
    await api.sessions.clear();
  });
}
