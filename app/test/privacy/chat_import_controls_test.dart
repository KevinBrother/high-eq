import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/privacy/page.dart';
import 'package:high_eq/features/privacy/store.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import 'account_journey_test.dart' show pumpUntil;

void main() {
  testWidgets('账号页面分别撤回两种聊天授权且不提交聊天内容', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('d13-consents.'),
    );
    addTearDown(() => dir!.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir!);
    final scope = (await tester.runAsync(
      () => sessions.activate(tokens('synthetic-A')),
    ))!;
    final grants = {
      'chat_import': '2026-11',
      'reply_chat_import': '2026-11-reply',
    };
    final withdrawals = <String>[];
    final handler = Handler()
      ..handle = (op, request) async {
        switch (op) {
          case AppOp.getMe:
            return response({
              'user_id': scope.account,
              'timezone': 'Asia/Shanghai',
              'bindings': <String>[],
              'frozen_until': null,
            });
          case AppOp.listConsents:
            return response({
              'items': [
                for (final entry in grants.entries)
                  {
                    'purpose': entry.key,
                    'version': entry.value,
                    'granted': true,
                  },
              ],
              'next_cursor': null,
            });
          case AppOp.setConsent:
            final purpose = request.url.pathSegments.last;
            final version = grants.remove(purpose);
            expect(version, isNotNull);
            expect(jsonDecode(request.body), {
              'version': version,
              'granted': false,
            });
            withdrawals.add(purpose);
            return response({
              'purpose': purpose,
              'version': version,
              'granted': false,
            });
          default:
            fail('unexpected operation ${op.name}');
        }
      };
    await tester.pumpWidget(
      MaterialApp(
        home: PrivacyPage(
          PrivacyStore(
            AppApi(Uri.https('example.invalid'), handler, sessions),
            scope,
          ),
          onClosureSubmitted: (_) {},
          onClosureUnconfirmed: (_) {},
          onClosureCancelled: () {},
          onExit: () {},
        ),
        routes: {'/replies': (_) => const Scaffold(body: Text('回复入口'))},
      ),
    );
    await pumpUntil(tester, find.byKey(const Key('privacy-timezone')));
    expect(withdrawals, isEmpty);
    final scrollable = find
        .descendant(
          of: find.byKey(const Key('privacy-account-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('聊天导入授权'),
      200,
      scrollable: scrollable,
    );
    Future<void> withdraw(String purpose) async {
      final button = find.byWidgetPredicate(
        (w) =>
            w is TextButton &&
            w.key == ValueKey('withdraw-$purpose') &&
            w.onPressed != null,
      );
      await pumpUntil(tester, button);
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button.hitTestable());
      await pumpUntil(tester, find.textContaining('已撤回'));
    }

    await withdraw('reply_chat_import');
    expect(grants, {'chat_import': '2026-11'});
    expect(find.text('已撤回回复助手聊天分析授权。'), findsOneWidget);

    final open = find.text('前往入口');
    await tester.ensureVisible(open);
    await tester.tap(open.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('回复入口'), findsOneWidget);
    expect(withdrawals, ['reply_chat_import']);
    Navigator.of(tester.element(find.text('回复入口'))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));

    await withdraw('chat_import');
    expect(grants, isEmpty);
    expect(withdrawals, ['reply_chat_import', 'chat_import']);
    expect(find.text('已撤回关系人聊天导入授权。'), findsOneWidget);
  });
}
