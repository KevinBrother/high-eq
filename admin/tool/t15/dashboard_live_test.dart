import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/api.dart';
import 'package:high_eq_admin/features/workspace/shell.dart';
import 'package:http/http.dart' as http;

// T15: the shipped /metrics page runs against the disposable Go service over
// real loopback HTTP. It selects the task, model UUID and prompt-version UUID
// of the one synthetic review, presses "查询调用", and records exactly what
// that row rendered. The Go parent compares those strings with persisted
// ai_calls and the decrypted growth projection. No provider, account or
// browser.
void main() {
  testWidgets('T15 /metrics page shows the live call group over real HTTP', (
    tester,
  ) async {
    HttpOverrides.global = null;
    final env = Platform.environment;
    final origin = Uri.parse(env['T15_ADMIN_ORIGIN']!);
    final token = env['T15_ADMIN_TOKEN']!;
    final model = env['T15_MODEL_ID']!;
    final version = env['T15_VERSION_ID']!;
    final receipt = env['T15_RECEIPT']!;

    final api = AdminApi(http.Client(), origin);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Workspace(
            path: '/metrics',
            session: Session(
              token,
              'operator',
              DateTime.now().add(const Duration(hours: 1)),
            ),
          ),
        ),
      ),
    );

    await _until(tester, find.text('调用监控'), 'metrics page load');
    for (var i = 0; i < 800; i++) {
      final rows = _textsMatching(tester, RegExp(r'^调用 \d+ 次$'));
      if (rows.isNotEmpty && _loading.evaluate().isEmpty) break;
      if (i == 799) {
        fail(
          'T15 /metrics did not finish its initial load; '
          'visible=${_visibleTexts(tester)}',
        );
      }
      await _tick(tester);
    }

    final taskField = find
        .ancestor(
          of: find.text('任务'),
          matching: find.byType(InputDecorator),
        )
        .first;
    final taskDropdown = find.descendant(
      of: taskField,
      matching: find.byType(DropdownButton<String>),
    );
    await tester.ensureVisible(taskDropdown);
    await tester.pump();
    final scoringLabels = find.text('评分');
    final beforeMenu = scoringLabels.evaluate().length;
    await tester.tap(taskDropdown);
    for (var i = 0; i < 40; i++) {
      await _tick(tester);
      if (scoringLabels.evaluate().length > beforeMenu) break;
    }
    // The open menu's overlay item is last; a rendered scoring group would use
    // the same label earlier in the tree.
    await tester.tap(scoringLabels.last);
    await tester.pump();

    await tester.scrollUntilVisible(
      find.text('精确筛选'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('精确筛选'));
    await tester.pump();

    // The expanded "精确筛选" section holds exactly the model UUID and prompt
    // version UUID fields, in that order.
    final inputs = find.byType(TextFormField);
    await _until(tester, inputs, 'precise filters');
    await tester.ensureVisible(inputs.at(0));
    await tester.enterText(inputs.at(0), model);
    await tester.ensureVisible(inputs.at(1));
    await tester.enterText(inputs.at(1), version);
    await tester.pump();

    final query = find.text('查询调用');
    await tester.ensureVisible(query);
    await tester.tap(query);
    await tester.pump();

    // With task, model and version all selected the page builds exactly one
    // group: the scored review. Individual filter omissions are not exercised
    // here, so this does not claim any one of them alone would add a group.
    for (var i = 0; i < 800; i++) {
      final rows = _textsMatching(tester, RegExp(r'^调用 \d+ 次$'));
      if (rows.length == 1 && _loading.evaluate().isEmpty) break;
      if (i == 799) {
        fail(
          'T15 /metrics did not settle on one live group; '
          'calls=$rows visible=${_visibleTexts(tester)}',
        );
      }
      await _tick(tester);
    }

    final identity = _singleText(
      tester,
      RegExp(r'^模型 [0-9a-f-]+\n模板 [0-9a-f-]+$'),
      'model/version readback',
    );
    final calls = _singleText(tester, RegExp(r'^调用 \d+ 次$'), 'call count');
    final mean = _singleText(
      tester,
      RegExp(r'^平均 \d+\.\d ms$'),
      'mean latency',
    );
    final failures = _singleText(
      tester,
      RegExp(r'^失败 \d+ 次 · \d+\.\d%$'),
      'failure summary',
    );
    final cost = _singleText(
      tester,
      RegExp(r'^已知成本 ¥\d+\.\d{8}  ·  未知成本 \d+ 次$'),
      'known/unknown cost',
    );
    final bins = _textsMatching(tester, RegExp(r'^\d{1,3} 分$'));
    final counts = _textsMatching(tester, RegExp(r'^\d+ 份$'));
    final missing = _textsMatching(tester, RegExp(r'^尚无数值投影：'));
    if (bins.isEmpty || counts.isEmpty) {
      fail('T15 /metrics omitted the score distribution; '
          'visible=${_visibleTexts(tester)}');
    }

    File(receipt).writeAsStringSync(
      jsonEncode({
        'identity': identity,
        'calls': calls,
        'mean': mean,
        'failures': failures,
        'cost': cost,
        'bins': bins,
        'counts': counts,
        'missing': missing.isEmpty ? '' : missing.first,
      }),
    );
    // Close the real client so its keep-alive timer does not outlive the fake
    // clock, then drain the page's own animations.
    api.client.close();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  });
}

// The top-of-page loading bar is indeterminate; distribution bars carry a
// value and must not be mistaken for a pending query.
final _loading = find.byWidgetPredicate(
  (widget) => widget is LinearProgressIndicator && widget.value == null,
);

List<String> _visibleTexts(WidgetTester tester) {
  final texts = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final data = (element.widget as Text).data;
    if (data != null && data.isNotEmpty) texts.add(data);
  }
  for (final element in find.byType(SelectableText).evaluate()) {
    final data = (element.widget as SelectableText).data;
    if (data != null && data.isNotEmpty) texts.add(data);
  }
  return texts;
}

List<String> _textsMatching(WidgetTester tester, RegExp pattern) => [
  for (final text in _visibleTexts(tester))
    if (pattern.hasMatch(text)) text,
];

String _singleText(WidgetTester tester, RegExp pattern, String label) {
  final matches = _textsMatching(tester, pattern);
  if (matches.length != 1) {
    fail(
      'T15 /metrics expected one $label, got $matches; '
      'visible=${_visibleTexts(tester)}',
    );
  }
  return matches.single;
}

// Pump while giving real sockets a turn on the real event loop. Widget tests
// otherwise run in fake async, where an HTTP response never arrives.
Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 25)),
  );
  await tester.pump(const Duration(milliseconds: 25));
}

Future<void> _until(WidgetTester tester, Finder finder, String label) async {
  for (var i = 0; i < 800; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await _tick(tester);
  }
  fail('T15 live page timed out waiting for $label; visible=${_visibleTexts(tester)}');
}
