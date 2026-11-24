import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/main.dart';
import '../isolation_test.dart' show MemorySecret, tokens;

import '../../integration_test/support/demo_login.dart';
import '../../tool/t26/assessment_steps.dart';
import '../../tool/t26/journey_stage.dart';

// Avoid filesystem/timers under the widget test's fake clock. A separate test
// exercises the actual encrypted continuation on a fresh Sessions instance.
class WidgetSessions extends Sessions {
  final AccountScope known;
  WidgetSessions(this.known) : super(MemorySecret(), Directory.systemTemp);
  final cache = <String, List<int>>{};
  @override
  Future<AccountScope> activate(Tokens t) async {
    (identity as ValueNotifier<AccountScope?>).value = known;
    return known;
  }

  @override
  Tokens require(AccountScope s) {
    if (s != active) throw SessionChanged();
    return tokens(s.account);
  }

  @override
  Future<List<int>?> get(AccountScope s, CacheKind k, String id) async =>
      cache[id];
  @override
  Future<void> put(AccountScope s, CacheKind k, String id, List<int> b) async {
    cache[id] = b;
  }

  @override
  Future<void> remove(AccountScope s, CacheKind k, String id) async {
    cache.remove(id);
  }
}

// Keep widget time deterministic. Real transport, timers and native storage
// are exercised separately by the account smoke and simulator integration.
class _FixtureApi extends AppApi {
  final Json examples;
  _FixtureApi(super.origin, super.transport, super.sessions, this.examples);
  @override
  Future<Json> json(
    AppOp op, {
    AccountScope? scope,
    Map<String, String> path = const {},
    Map<String, String> query = const {},
    Json? body,
    Future<void> Function()? beforeSend,
  }) async => {
    ...examples[op.name] as Json,
    if (op == AppOp.getMe) 'user_id': scope!.account,
  };
}

Future<AccountScope> _widgetScope(WidgetTester tester) async {
  final scope = await tester.runAsync(() async {
    final dir = await Directory.systemTemp.createTemp();
    try {
      return await Sessions(MemorySecret(), dir).activate(tokens('widget'));
    } finally {
      await dir.delete(recursive: true);
    }
  });
  return scope!;
}

void main() {
  testWidgets(
    'gates, encrypted-draft UI resume, 16 items, scene shared and retest blocked',
    (t) async {
      final api = _FixtureApi(
        Uri.https('example.invalid'),
        ExampleTransport(),
        WidgetSessions(await _widgetScope(t)),
        jsonDecode(File('assets/contract_examples.json').readAsStringSync())
            as Json,
      );
      await t.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWith((_) async => api)],
          child: const HighEqApp(),
        ),
      );
      await t.pumpAndSettle();
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '同意并继续'))
            .onPressed,
        isNull,
      );
      await demoLogin(t);
      expect(find.text('是否同意开始本次自评？'), findsOneWidget);
      Future<void> tap(String s) async {
        final labels = find.text(s);
        if (labels.evaluate().isEmpty && (s == '本次自评与续答' || s == '切换练习场景')) {
          await t.scrollUntilVisible(
            labels,
            200,
            scrollable: find.byType(Scrollable).first,
          );
        }
        final f = labels.last;
        await t.ensureVisible(f);
        await t.pumpAndSettle();
        await t.tap(f);
        await t.pumpAndSettle();
      }

      await tap('单独同意并开始');
      await tap('有点同意');
      await tap('稍后续答');
      await tap('本次自评与续答');
      expect(find.text('第 2 / 16 题'), findsOneWidget);
      for (var i = 1; i < 16; i++) {
        await tap('同意');
      }
      await tap('伴侣');
      await tap('稍后续答');
      await tap('本次自评与续答');
      expect(
        t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '伴侣')).selected,
        isTrue,
      );
      await tap('提交并查看雷达图');
      expect(find.text('本次自评'), findsOneWidget);
      expect(find.textContaining('距下次可复测'), findsOneWidget);
      expect(find.text('开始复测'), findsNothing);
      await tap('进入练习');
      await tap('切换练习场景');
      expect(
        t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '伴侣')).selected,
        isTrue,
      );
    },
  );

  testWidgets('T26 assessment gestures work in a short viewport', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(380, 440);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final sessions = WidgetSessions(await _widgetScope(t));
    await sessions.activate(tokens('widget'));
    final api = _FixtureApi(
      Uri.https('example.invalid'),
      ExampleTransport(),
      sessions,
      jsonDecode(File('assets/contract_examples.json').readAsStringSync())
          as Json,
    );
    await t.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWith((_) async => api)],
        child: const HighEqApp(),
      ),
    );
    await t.pumpAndSettle();

    final phases = <T26AssessmentPhase>[];
    final enterPractice = await completeT26Assessment(t, report: phases.add);

    expect(phases, T26AssessmentPhase.values);
    expect(find.text('本次自评总分 · 67 / 100'), findsOneWidget);
    expect(find.text('开始复测'), findsNothing);
    expect(enterPractice, findsOneWidget);
    await t.tap(enterPractice);
    await t.pumpAndSettle();
    expect(find.text('今天，练一件小事'), findsOneWidget);
  });
}
