import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/onboarding/login.dart' show vendorChannel;
import 'package:high_eq/features/onboarding/radar.dart';
import 'package:high_eq/features/onboarding/repository.dart';
import 'package:high_eq/features/onboarding/score.dart' show abilities;
import 'package:high_eq/main.dart';

import '../t26/transport.dart';

const _wait = Duration(seconds: 30);

/// Test stand-in for the platform keystore. Two independent widget processes
/// share the same synthetic account through this file; the real app uses
/// DeviceSecret. The answers themselves are only written by the product page.
class _FileSecret implements SecretStore {
  _FileSecret(this.file);
  final File file;

  @override
  Future<String?> read() async =>
      await file.exists() ? file.readAsString() : null;

  @override
  Future<void> replace(String? value) async {
    if (value == null) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(value, flush: true);
  }
}

class _T17LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String label,
  Duration limit = _wait,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < limit) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  await tester.pump();
  if (!ready()) fail('Timed out after ${limit.inSeconds}s waiting for $label.');
}

const _optionLabels = [
  '非常不同意',
  '不同意',
  '有点不同意',
  '说不清',
  '有点同意',
  '同意',
  '非常同意',
];

Finder _option(int value) => find.ancestor(
  of: find.text(_optionLabels[value - 1]),
  matching: find.byWidgetPredicate(
    (widget) => widget is ListTile && widget.onTap != null,
  ),
);

Future<void> _waitForText(
  WidgetTester tester,
  String text, {
  String? label,
}) => _waitUntil(
  tester,
  () => find.text(text).evaluate().isNotEmpty,
  label: label ?? text,
);

Future<void> _tap(WidgetTester tester, Finder finder, {required String label}) async {
  if (finder.evaluate().isEmpty) {
    // The production pages use a lazy ListView; controls below the fold are
    // built only after scrolling.
    await tester.scrollUntilVisible(finder, 120, maxScrolls: 20);
    await tester.pump();
  }
  await _waitUntil(
    tester,
    () => finder.evaluate().length == 1,
    label: label,
  );
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _answer(
  WidgetTester tester, {
  required int question,
  required int option,
}) async {
  await _waitForText(
    tester,
    '合成题目 ${question.toString().padLeft(2, '0')}',
    label: 'question $question',
  );
  debugPrintSynchronously('T17_STEP tap_$question');
  await _tap(tester, _option(option), label: 'option $option for question $question');
}

/// Reads the total and four axis numbers that the result page actually
/// renders. No score literal is supplied by the test; the chart widget is only
/// cross-checked against the same rendered text.
({int total, Map<String, int> axes}) _readPageScores(WidgetTester tester) {
  final texts = find
      .byType(Text)
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .whereType<String>()
      .toList();
  List<int> captured(RegExp pattern) {
    final values = <int>[];
    for (final text in texts) {
      final match = pattern.firstMatch(text);
      if (match != null) values.add(int.parse(match.group(1)!));
    }
    return values;
  }

  final totals = captured(RegExp(r'^本次自评总分 · (\d+) / 100$'));
  expect(totals, hasLength(1), reason: 'result page must render one total');
  final axes = <String, int>{};
  final radar = tester.widget<AssessmentRadar>(find.byType(AssessmentRadar));
  for (final entry in abilities.entries) {
    final values = captured(
      RegExp('^${RegExp.escape(entry.value)} · (\\d+) / 100\$'),
    );
    expect(values, hasLength(1), reason: 'axis row ${entry.key}');
    expect(values.single, radar.percentages[entry.key]!.round());
    axes[entry.key] = values.single;
  }
  return (total: totals.single, axes: axes);
}

void main() {
  _T17LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets(
    'T17 first assessment resumes from a rebuilt client and submits once',
    (tester) async {
      final environment = Platform.environment;
      final stage = environment['T17_RESUME_STAGE'];
      final rawOrigin = environment['T17_RESUME_ORIGIN'];
      final directory = environment['T17_RESUME_DIR'];
      final secretPath = environment['T17_RESUME_SECRET'];
      expect(stage, anyOf('first', 'second'));
      expect(rawOrigin, isNotNull);
      expect(directory, isNotNull);
      expect(secretPath, isNotNull);

      final origin = Uri.parse(rawOrigin!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      expect(origin.hasPort, isTrue);
      expect(origin.hasQuery, isFalse);

      final sessions = Sessions(_FileSecret(File(secretPath!)), Directory(directory!));
      await sessions.restore();
      final transport = HttpTransport(t26LoopbackClient());
      addTearDown(transport.close);
      final api = AppApi(origin, transport, sessions);

      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      if (stage == 'first') {
        final proof = environment['T17_RESUME_APPLE'];
        expect(proof, isNotNull);
        messenger.setMockMethodCallHandler(vendorChannel, (call) async {
          if (call.method != 'authorize') {
            throw PlatformException(code: 'unexpected_method');
          }
          return proof;
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(vendorChannel, null),
        );
      }

      await tester.pumpWidget(
        ProviderScope(
          overrides: [apiProvider.overrideWith((_) async => api)],
          child: const HighEqApp(),
        ),
      );

      if (stage == 'first') {
        await _waitForText(tester, '同意并继续', label: 'privacy agreement');
        await _tap(tester, find.text('我已阅读并同意'), label: 'privacy checkbox');
        await _tap(
          tester,
          find.widgetWithText(FilledButton, '同意并继续'),
          label: 'accept privacy',
        );
        await _waitForText(tester, '先为自己留一个空间', label: 'login screen');
        await _tap(tester, find.text('我已满 14 周岁'), label: 'age confirmation');
        await _tap(
          tester,
          find.widgetWithText(OutlinedButton, 'Apple 登录'),
          label: 'Apple sign-in',
        );
        await _waitForText(
          tester,
          '是否同意开始本次自评？',
          label: 'assessment consent',
        );
        await _tap(
          tester,
          find.widgetWithText(FilledButton, '单独同意并开始'),
          label: 'grant assessment consent',
        );
        for (var question = 1; question <= 7; question++) {
          await _answer(tester, question: question, option: question);
        }
        await _waitForText(tester, '合成题目 08', label: 'question 8 after seven answers');
        expect(sessions.active, isNotNull);

        // Read the product's encrypted draft back through the product cache.
        final book = AssessmentBook(api, sessions.active!);
        final draft = await book.read('draft');
        expect(draft, isNotNull);
        expect(draft!['index'], 7);
        expect(draft['answers'], [1, 2, 3, 4, 5, 6, 7]);
        expect(await Directory(directory).list().isEmpty, isFalse);
        debugPrintSynchronously('T17_STAGE first_stopped');
        return;
      }

      expect(sessions.active, isNotNull);
      await _waitForText(tester, '合成题目 08', label: 'restored question 8');
      final book = AssessmentBook(api, sessions.active!);
      final draft = await book.read('draft');
      expect(draft, isNotNull);
      expect(draft!['index'], 7);
      expect(draft['answers'], [1, 2, 3, 4, 5, 6, 7]);

      // Return to the last answered question and confirm its stored choice.
      await _tap(
        tester,
        find.widgetWithText(TextButton, '上一题'),
        label: 'back to question 7',
      );
      await _waitForText(tester, '合成题目 07', label: 'question 7');
      final previous = _option(7);
      await _waitUntil(
        tester,
        () => previous.evaluate().length == 1,
        label: 'stored choice 7',
      );
      expect(tester.widget<ListTile>(previous).selected, isTrue);
      await _tap(tester, previous, label: 'restore question 8 by keeping the choice');
      await _waitForText(tester, '合成题目 08', label: 'question 8 again');

      for (var question = 8; question <= 16; question++) {
        await _answer(
          tester,
          question: question,
          option: ((question - 1) % 7) + 1,
        );
      }
      await _waitForText(tester, '想先在哪种场合练习？', label: 'scene step');
      await _tap(
        tester,
        find.widgetWithText(FilledButton, '提交并查看雷达图'),
        label: 'submit assessment',
      );
      await _waitUntil(
        tester,
        () =>
            find.textContaining('本次自评总分').evaluate().isNotEmpty &&
            find.byType(AssessmentRadar).evaluate().isNotEmpty,
        label: 'result radar',
      );
      final scores = _readPageScores(tester);
      debugPrintSynchronously(
        'T17_PAGE total=${scores.total} '
        'SEA=${scores.axes['SEA']} OEA=${scores.axes['OEA']} '
        'UOE=${scores.axes['UOE']} ROE=${scores.axes['ROE']}',
      );
      debugPrintSynchronously('T17_STAGE second_complete');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
