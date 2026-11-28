import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/api.dart';
import 'package:high_eq_admin/features/workspace/shell.dart';
import 'package:http/http.dart' as http;

// T15: the shipped /prompts page runs against the disposable Go service over
// real loopback HTTP, selects the published model, chooses the already-saved
// seed as the experiment arm, moves the split to 50%, presses "发布所选版本"
// and reads the primary/experiment line back from the page after its own
// reload. The Go parent verifies the persisted pointer, one success audit, the
// rendered line and the two App users' actual ai_calls attribution.
void main() {
  testWidgets('T15 /prompts page publishes an A/B split over real HTTP', (
    tester,
  ) async {
    HttpOverrides.global = null;
    await tester.binding.setSurfaceSize(const Size(1200, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final env = Platform.environment;
    final origin = Uri.parse(env['T15_ADMIN_ORIGIN']!);
    final token = env['T15_ADMIN_TOKEN']!;
    final modelLabel = env['T15_MODEL_LABEL']!;
    final current = env['T15_CURRENT']!;
    final experiment = env['T15_EXPERIMENT']!;
    final primary = env['T15_PRIMARY']!;
    final percent = int.parse(env['T15_PERCENT']!);
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

    // Pick the generation model whose release the fixture already points at.
    final modelChoice = find
        .ancestor(
          of: find.text('目标模型'),
          matching: find.byType(InputDecorator),
        )
        .first;
    final modelDropdown = find.descendant(
      of: modelChoice,
      matching: find.byType(DropdownButton<String>),
    );
    await tester.ensureVisible(modelDropdown);
    await tester.pump();
    await tester.tap(modelDropdown);
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

    // Select the pending primary from the page's own saved versions, then pick
    // the other saved version as the experiment arm. Two distinct versions for
    // one task and one generation model.
    final baseChoice = find
        .ancestor(
          of: find.text('基于版本'),
          matching: find.byType(InputDecorator),
        )
        .first;
    final baseDropdown = find.descendant(
      of: baseChoice,
      matching: find.byType(DropdownButton<String>),
    );
    await tester.ensureVisible(baseDropdown);
    await tester.pump();
    await tester.tap(baseDropdown);
    await tester.pump();
    final baseOption = find.text(primary);
    await _until(tester, baseOption, 'primary version option');
    await tester.tap(baseOption.last);
    await tester.pump();
    await _until(
      tester,
      find.text('待发布主版本：$primary'),
      'selected primary version',
    );

    final armChoice = find
        .ancestor(
          of: find.text('实验版本'),
          matching: find.byType(InputDecorator),
        )
        .first;
    final armDropdown = find.descendant(
      of: armChoice,
      matching: find.byType(DropdownButton<String>),
    );
    await tester.ensureVisible(armDropdown);
    await tester.pump();
    await tester.tap(armDropdown);
    await tester.pump();
    final armOption = find.text(experiment);
    await _until(tester, armOption, 'experiment version option');
    await tester.tap(armOption.last);
    await tester.pump();
    await _until(tester, find.text('实验流量 10%'), 'experiment split default');

    // Move the real slider to the middle; the page reports the chosen split.
    final slider = find.byType(Slider);
    await tester.ensureVisible(slider);
    await tester.pump();
    await tester.tapAt(tester.getCenter(slider));
    await tester.pump();
    await _until(
      tester,
      find.text('实验流量 $percent%'),
      'experiment split slider',
    );

    final publish = find.text('发布所选版本');
    await tester.ensureVisible(publish);
    await tester.pump();
    await tester.tap(publish);
    await tester.pump();
    await _until(tester, find.text('发布配置已更新'), 'publish confirmation');
    await _untilGone(
      tester,
      find.byType(LinearProgressIndicator),
      'publish reload',
    );

    // Only the reloaded live pointer line carries both the new primary and the
    // split; read the node's own text and hand it to the Go parent.
    await _until(
      tester,
      find.textContaining('线上主版本：$primary'),
      'published release readback',
    );
    await _until(
      tester,
      find.textContaining('实验：$experiment · $percent%'),
      'published experiment readback',
    );
    final line = _releaseLine();
    if (!line.contains('线上主版本：$primary') ||
        !line.contains('实验：$experiment · $percent%')) {
      fail('T15 live page rendered an unexpected release line: $line');
    }

    // Close the real client so its idle keep-alive timer does not outlive the
    // fake clock, then drain the snackbar's dismissal timer.
    api.client.close();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    File(receipt).writeAsStringSync('release=$line\n');
  });
}

String _releaseLine() {
  for (final e in find.byType(Text).evaluate()) {
    final data = (e.widget as Text).data;
    if (data != null && data.startsWith('线上主版本：')) return data;
  }
  fail('T15 live page has no release readback line');
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
