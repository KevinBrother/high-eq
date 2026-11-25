import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/api.dart';
import 'package:high_eq_admin/features/workspace/shell.dart';
import 'package:http/http.dart' as http;

// T15: the shipped /prompts page runs against the disposable Go service over
// real loopback HTTP, selects the published model and presses "回滚到 v1". The
// Go parent verifies the release pointer, experiment reset, one success audit
// and the next App call's actual template and version. No real provider,
// account or browser.
void main() {
  testWidgets('T15 /prompts page rolls the live prompt back over real HTTP', (
    tester,
  ) async {
    HttpOverrides.global = null;
    final env = Platform.environment;
    final origin = Uri.parse(env['T15_ADMIN_ORIGIN']!);
    final token = env['T15_ADMIN_TOKEN']!;
    final modelLabel = env['T15_MODEL_LABEL']!;
    final current = env['T15_CURRENT']!;
    final rollback = env['T15_ROLLBACK']!;
    final receipt = env['T15_RECEIPT']!;

    final api = AdminApi(http.Client(), origin);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Workspace(
            path: '/prompts',
            session: Session(
              token,
              'operator',
              DateTime.now().add(const Duration(hours: 1)),
            ),
          ),
        ),
      ),
    );

    await _until(tester, find.text('版本编辑'), 'prompt page load');
    await tester.scrollUntilVisible(
      find.text('发布与分流'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    final target = find
        .ancestor(
          of: find.text('目标模型'),
          matching: find.byType(InputDecorator),
        )
        .first;
    final dropdown = find.descendant(
      of: target,
      matching: find.byType(DropdownButton<String>),
    );
    await tester.ensureVisible(dropdown);
    await tester.pump();
    await tester.tap(dropdown);
    await tester.pump();
    final option = find.text(modelLabel);
    await _until(tester, option, 'published model option');
    await tester.tap(option.last);
    await tester.pump();
    await _until(
      tester,
      find.textContaining('线上主版本：$current'),
      'selected model release readback',
    );

    final button = find.text('回滚到 $rollback');
    await _until(tester, button, 'rollback button');
    await tester.ensureVisible(button);
    await tester.pump();
    await tester.tap(button);
    await tester.pump();

    await _until(tester, find.text('已回滚，并关闭实验分流'), 'rollback confirmation');
    await _untilGone(
      tester,
      find.byType(LinearProgressIndicator),
      'rollback reload',
    );
    await tester.scrollUntilVisible(
      find.text('发布与分流'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await _until(
      tester,
      find.textContaining('线上主版本：$rollback'),
      'rolled-back release readback',
    );
    await tester.scrollUntilVisible(
      find.textContaining('线上主版本：$rollback'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // Close the real client so its idle keep-alive timer does not outlive the
    // fake clock, then drain the snackbar's dismissal timer.
    api.client.close();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    File(receipt).writeAsStringSync('rollback=$rollback\n');
  });
}

// Pump while giving real sockets a turn on the real event loop. Widget tests
// otherwise run in fake async, where an HTTP response never arrives.
Future<void> _until(WidgetTester tester, Finder finder, String label) async {
  for (var i = 0; i < 600; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  final texts = <String>[];
  for (final e in find.byType(Text).evaluate()) {
    final data = (e.widget as Text).data;
    if (data != null && data.isNotEmpty) texts.add(data);
  }
  fail('T15 live page timed out waiting for $label; visible: $texts');
}

Future<void> _untilGone(
  WidgetTester tester,
  Finder finder,
  String label,
) async {
  for (var i = 0; i < 600; i++) {
    if (finder.evaluate().isEmpty) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  fail('T15 live page timed out waiting for $label to finish');
}
