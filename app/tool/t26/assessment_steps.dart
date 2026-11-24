import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/onboarding/assessment.dart';
import 'package:high_eq/features/onboarding/surface.dart';

import 'journey_stage.dart';

const _waitLimit = Duration(seconds: 25);
const _frame = Duration(milliseconds: 20);
const _itemCount = 16;

/// Completes the assessment through the production UI and returns its enabled
/// practice button. The caller owns the stage transition to the plan.
Future<Finder> completeT26Assessment(
  WidgetTester tester, {
  required void Function(T26AssessmentPhase) report,
}) async {
  report(T26AssessmentPhase.load);
  await tester.tap(await _button(tester, '单独同意并开始', 'assessment consent'));
  await _waitForTitle(tester, '第 1 / $_itemCount 题', 'first assessment item');

  report(T26AssessmentPhase.answer);
  for (var item = 1; item <= _itemCount; item++) {
    final option = _control<ListTile>('有点同意', (tile) => tile.onTap != null);
    await tester.tap(await _readyControl(tester, option, 'assessment answer'));
    // Tapping the row saves the draft and advances the screen automatically.
    if (item < _itemCount) {
      await _waitForTitle(
        tester,
        '第 ${item + 1} / $_itemCount 题',
        'assessment item ${item + 1}',
      );
    }
  }

  report(T26AssessmentPhase.scene);
  await _waitForTitle(tester, '想先在哪种场合练习？', 'assessment scene screen');
  final family = _control<ChoiceChip>('家人', (chip) => chip.onSelected != null);
  await tester.tap(await _readyControl(tester, family, 'family scene'));
  await _waitFor(tester, () {
    final matches = family.evaluate();
    return matches.length == 1 &&
        (matches.single.widget as ChoiceChip).selected;
  }, 'selected family scene');

  report(T26AssessmentPhase.submit);
  await tester.tap(await _button(tester, '提交并查看雷达图', 'assessment submission'));
  final score = _inAssessment(find.textContaining('本次自评总分'));
  await _waitFor(
    tester,
    () => score.evaluate().length == 1,
    'assessment score',
  );
  expect(_inAssessment(find.textContaining('距下次可复测')), findsOneWidget);

  report(T26AssessmentPhase.continueReady);
  return _button(tester, '进入练习', 'continue to practice');
}

Finder _inAssessment(Finder matching) =>
    find.descendant(of: find.byType(AssessmentPage), matching: matching);

Finder _control<T extends Widget>(String text, bool Function(T) enabled) =>
    _inAssessment(
      find.ancestor(
        of: find.text(text),
        matching: find.byWidgetPredicate(
          (widget) => widget is T && enabled(widget),
        ),
      ),
    );

Future<Finder> _button(WidgetTester tester, String text, String label) =>
    _readyControl(
      tester,
      _control<FilledButton>(text, (button) => button.onPressed != null),
      label,
    );

Future<Finder> _readyControl(
  WidgetTester tester,
  Finder control,
  String label,
) async {
  final target = control.hitTestable();
  await _waitFor(tester, () async {
    if (control.evaluate().length != 1) return false;
    if (target.evaluate().isEmpty) {
      await Scrollable.ensureVisible(tester.element(control), alignment: .5);
      await tester.pump();
    }
    // FlowSurface temporarily ignores pointers while it saves or submits.
    return target.evaluate().length == 1;
  }, label);
  return target;
}

Future<void> _waitForTitle(
  WidgetTester tester,
  String text,
  String label,
) async {
  final surface = _inAssessment(
    find.byWidgetPredicate(
      (widget) => widget is FlowSurface && widget.title == text,
    ),
  );
  await _waitFor(tester, () => surface.evaluate().length == 1, label);
  final title = find.descendant(of: surface, matching: find.text(text));
  if (title.evaluate().isEmpty) {
    // The shared list can keep its scroll offset as the next item appears.
    final list = find.descendant(of: surface, matching: find.byType(ListView));
    await tester.scrollUntilVisible(
      title,
      -180,
      scrollable: find.descendant(of: list, matching: find.byType(Scrollable)),
    );
  }
  expect(title, findsOneWidget);
}

Future<void> _waitFor(
  WidgetTester tester,
  FutureOr<bool> Function() ready,
  String label,
) async {
  final clock = tester.binding.clock;
  final deadline = clock.now().add(_waitLimit);
  do {
    if (await ready()) return;
    await tester.pump(_frame);
  } while (clock.now().isBefore(deadline));
  if (!await ready()) fail('Timed out waiting for $label.');
}
