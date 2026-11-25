import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/api.dart';
import 'package:high_eq_admin/features/workspace/shell.dart';
import 'package:http/http.dart' as http;

// T14: the shipped /models page runs against the disposable Go service over
// real loopback HTTP, selects the next primary model and presses save. The Go
// parent verifies the persisted route, the single success audit and the next
// App call's actual model. Nothing here talks to a real provider or account.
void main() {
  testWidgets('T14 /models page saves the next primary model over real HTTP', (
    tester,
  ) async {
    HttpOverrides.global = null;
    final env = Platform.environment;
    final origin = Uri.parse(env['T14_ADMIN_ORIGIN']!);
    final token = env['T14_ADMIN_TOKEN']!;
    final currentId = env['T14_PRIMARY_MODEL_ID']!;
    final nextId = env['T14_NEXT_MODEL_ID']!;
    final nextName = env['T14_NEXT_MODEL_NAME']!;
    final nextLabel = env['T14_NEXT_MODEL_LABEL']!;
    final receipt = env['T14_SAVE_RECEIPT']!;

    final api = AdminApi(http.Client(), origin);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp(
          home: Workspace(
            path: '/models',
            session: Session(
              token,
              'super_admin',
              DateTime.now().add(const Duration(hours: 1)),
            ),
          ),
        ),
      ),
    );

    await _until(tester, find.text('新增模型'), 'models list');
    await _untilGone(tester, find.byType(LinearProgressIndicator), 'model load');
    await tester.tap(find.text('任务路由'));
    await tester.pump();

    final routeCard = find.ancestor(
      of: find.text('回复建议'),
      matching: find.byType(Card),
    );
    await _until(tester, routeCard, 'reply_suggestion route card');
    await tester.tap(
      find.descendant(of: routeCard, matching: find.text('配置路由')),
    );
    await tester.pump();

    final primary = find.byKey(ValueKey('primary_model:$currentId'));
    await _until(tester, primary, 'primary model selector');
    await tester.tap(primary);
    await tester.pump();
    final option = find.text(nextLabel);
    await _until(tester, option, 'next model option');
    await tester.tap(option.last);
    await tester.pump();

    final save = find.text('保存配置');
    await _until(tester, save, 'save button');
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pump();

    await _until(tester, find.text('配置已生效'), 'save confirmation');
    await _until(
      tester,
      find.textContaining('主：$nextName'),
      'saved route readback',
    );
    // Close the real client so its idle keep-alive timer does not outlive the
    // fake clock, then drain the snackbar's dismissal timer.
    api.client.close();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    File(receipt).writeAsStringSync('model=$nextId\n');
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
  fail('T14 live page timed out waiting for $label');
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
  fail('T14 live page timed out waiting for $label to finish');
}
