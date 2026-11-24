import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/json.dart';
import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/lobby.dart';
import 'package:high_eq/features/practice/result.dart';

import 'journey_stage.dart';

const _targetPlanTitle = '完整对练';
const _turnText = '我注意到刚才会议被打断了，我有些着急，因为我想把进度讲清楚。能不能先让我说完这两分钟？';
const _fixtureReply = '合成甲。合成乙。';

/// Finishes the full-session practice card already visible on today's plan.
///
/// The caller must first render the production app and leave it on the
/// real practice home. All product writes below are made through widget
/// gestures; API calls in this helper are read-only cross-checks.
Future<void> finishT26PlanPractice(WidgetTester tester, AppApi api) async {
  final activeScope = api.sessions.active;
  expect(activeScope, isNotNull, reason: '前置条件不满足：当前没有已登录账号');
  final scope = activeScope!;
  final wire = MobileEndpoints(api);

  final beforePlanJson = await _read(
    '今日计划（操作前）',
    () => wire.getTodayPlan(scope: scope),
  );
  final beforePlan = PlanData.fromJson(beforePlanJson);
  final target = beforePlan.items
      .where(
        (item) => item.kind == PlanKind.level && item.title == _targetPlanTitle,
      )
      .firstOrNull;
  expect(target, isNotNull, reason: '今日计划中没有“$_targetPlanTitle”关卡');
  expect(target!.completed, isFalse, reason: '“$_targetPlanTitle”操作前已完成');

  final beforeSessionsJson = await _read(
    '练习历史（操作前）',
    () => wire.listSessions(scope: scope, limit: 100),
  );
  final beforeSessionIds = {
    for (final row in (beforeSessionsJson['items'] as List).cast<Json>())
      if (row['session_id'] is String) row['session_id'] as String,
  };

  await _waitForUi(
    tester,
    '今日计划加载出“$_targetPlanTitle”',
    () => _targetTile.evaluate().length == 1,
    timeout: const Duration(seconds: 30),
  );
  expect(
    _completedTargetLabel,
    findsNothing,
    reason: '“$_targetPlanTitle”操作前不应显示已完成',
  );
  final planRoute = ModalRoute.of(tester.element(_targetTile))!;
  expect(planRoute.settings.name, '/practice');

  T26JourneyStage.chat.report();
  T26ChatPhase.openPlan.report();
  await tester.tap(await revealT26PracticeControl(tester, _targetTile));
  await _waitForUi(
    tester,
    '进入计划关卡所在的对练大厅',
    () => _lobby.evaluate().length == 1,
  );
  final lobbyRoute = ModalRoute.of(tester.element(_lobby))!;
  expect(lobbyRoute.settings.name, '/training');
  expect(lobbyRoute.settings.arguments == target.contentId, isTrue);
  T26ChatPhase.planOpened.report();

  await _waitForUi(
    tester,
    '出现对练授权或进入聊天页',
    () => _consentButton.evaluate().isNotEmpty || _chat.evaluate().isNotEmpty,
    timeout: const Duration(seconds: 90),
  );
  if (_consentButton.evaluate().isNotEmpty) {
    T26ChatPhase.consent.report();
    await tester.tap(await revealT26PracticeControl(tester, _consentButton));
    await _waitForUi(
      tester,
      '确认练习授权后进入聊天页',
      () => _chat.evaluate().length == 1,
      timeout: const Duration(seconds: 90),
    );
  }

  T26ChatPhase.chatInput.report();
  final sessionId =
      tester.widget<PracticeChat>(_chat).initial['session_id'] as String;
  final input = _inChat(
    find.byWidgetPredicate(
      (widget) => widget is TextField && widget.enabled == true,
    ),
  );
  await _waitForUi(tester, '聊天输入框可用', () => input.evaluate().length == 1);
  await tester.enterText(
    await revealT26PracticeControl(tester, input),
    _turnText,
  );
  await tester.pump(const Duration(milliseconds: 50));
  final controller = tester.widget<TextField>(input).controller!;
  expect(controller.text, _turnText);

  T26ChatPhase.send.report();
  final send = _inChat(find.widgetWithIcon(IconButton, Icons.arrow_upward));
  expect(tester.widget<IconButton>(send).onPressed, isNotNull);
  await tester.tap(await revealT26PracticeControl(tester, send));
  // The product accepts the gesture by clearing the composer before sending.
  expect(controller.text, isEmpty, reason: '发送手势未被聊天输入框接收');

  T26ChatPhase.awaitReply.report();
  final finish = _inChat(find.widgetWithText(TextButton, '结束并评分'));
  await _waitForUi(
    tester,
    '真实 SSE 完成且聊天页读回已保存的回复',
    () => finish.evaluate().length == 1,
    timeout: const Duration(seconds: 120),
  );
  T26ChatPhase.verifyReply.report();
  final detail = await _read(
    'SSE 后的已保存对话',
    () => wire.getSession(scope: scope, sessionId: sessionId),
  );
  expect(detail['session_id'], sessionId);
  expect(detail['level_id'], target.contentId);
  final messages = (detail['messages'] as List).cast<Json>();
  expect(messages, hasLength(2));
  final user = messages.first;
  final assistant = messages.last;
  expect(user['role'], 'user');
  expect(user['seq'], 1);
  expect(user['text'], _turnText);
  expect(
    user['client_message_id'],
    isA<String>().having((id) => id.isNotEmpty, '非空', isTrue),
  );
  expect(assistant['role'], 'assistant');
  expect(assistant['seq'], 2);
  expect(assistant['text'], _fixtureReply);
  expect(assistant['client_message_id'], user['client_message_id']);

  T26ChatPhase.revealFinish.report();
  expect(tester.widget<TextButton>(finish).onPressed, isNotNull);
  reportT26FinishBeforeScroll(
    hittable: finish.hitTestable().evaluate().isNotEmpty,
  );
  final finishControl = await revealT26PracticeControl(tester, finish);
  T26JourneyStage.score.report();
  T26ScorePhase.finish.report();
  await tester.tap(finishControl);

  final feedback = _feedback;
  await _waitForUi(
    tester,
    '正式评分返回反馈页',
    () => feedback.evaluate().length == 1,
    timeout: const Duration(seconds: 120),
  );
  T26ScorePhase.feedback.report();
  final heading = find.descendant(of: feedback, matching: find.text('整场反馈'));
  final nvcTotal = find.descendant(
    of: feedback,
    matching: find.text('NVC 总分 100 / 100'),
  );
  await _waitForUi(
    tester,
    '整场反馈显示夹具的正式 NVC 总分',
    () => heading.evaluate().length == 1 && nvcTotal.evaluate().length == 1,
  );
  await revealT26PracticeControl(tester, heading);
  await revealT26PracticeControl(tester, nvcTotal);

  await returnT26ToCompletedPlan(
    tester,
    lobbyRoute: lobbyRoute,
    planRoute: planRoute,
    targetTitle: _targetPlanTitle,
    report: (phase) => phase.report(),
  );

  T26ScorePhase.readback.report();
  final afterPlanJson = await _read(
    '今日计划（操作后交叉校验）',
    () => wire.getTodayPlan(scope: scope),
  );
  final afterPlan = PlanData.fromJson(afterPlanJson);
  final afterTarget = afterPlan.items
      .where((item) => item.id == target.id)
      .firstOrNull;
  expect(afterTarget, isNotNull, reason: '操作后今日计划缺少原对练关卡');
  expect(afterTarget!.completed, isTrue, reason: 'API 未回写计划项完成状态');
  expect(afterTarget.contentId == target.contentId, isTrue);

  final afterSessionsJson = await _read(
    '练习历史（操作后交叉校验）',
    () => wire.listSessions(scope: scope, limit: 100),
  );
  final freshCompleteSessions = (afterSessionsJson['items'] as List)
      .cast<Json>()
      .where(
        (row) =>
            !beforeSessionIds.contains(row['session_id']) &&
            row['status'] == 'complete' &&
            row['level_id'] == target.contentId,
      )
      .toList();
  expect(freshCompleteSessions, hasLength(1), reason: 'API 应返回本次唯一新完成的完整对练记录');
  expect(freshCompleteSessions.single['session_id'], sessionId);
  T26ScorePhase.verified.report();
}

/// Returns through the real AppBar buttons to the plan that opened the chat.
Future<void> returnT26ToCompletedPlan(
  WidgetTester tester, {
  required ModalRoute<dynamic> lobbyRoute,
  required ModalRoute<dynamic> planRoute,
  required String targetTitle,
  required void Function(T26ScorePhase) report,
}) async {
  report(T26ScorePhase.returnLobby);
  // The score replaces the body of PracticeChat on the same route.
  final feedbackRoute = ModalRoute.of(tester.element(_feedback))!;
  await _tapBack(tester, _chat, feedbackRoute);

  report(T26ScorePhase.lobbyCurrent);
  final lobbyHeading = find
      .descendant(of: _lobby, matching: find.text('对练与预演'))
      .hitTestable();
  await _waitForUi(
    tester,
    '原对练大厅返回动画完成',
    () =>
        _routeReady(lobbyRoute) &&
        lobbyHeading.evaluate().length == 1 &&
        identical(ModalRoute.of(tester.element(lobbyHeading)), lobbyRoute),
  );
  report(T26ScorePhase.lobbyBack);
  await _tapBack(tester, _lobby, lobbyRoute);

  report(T26ScorePhase.returnPlan);
  await _waitForUi(tester, '原今日计划返回动画完成', () => _routeReady(planRoute));
  report(T26ScorePhase.planCompletion);
  final planHeading = _inPracticeHome(find.text('今日计划'));
  final tile = _planTile(targetTitle);
  final completed = _completionLabel(tile);
  await _waitForUi(
    tester,
    '原计划关卡刷新为已完成',
    () =>
        planHeading.evaluate().length == 1 &&
        identical(ModalRoute.of(tester.element(planHeading)), planRoute) &&
        tile.evaluate().length == 1 &&
        completed.evaluate().length == 1,
  );
  report(T26ScorePhase.revealCompletion);
  await revealT26PracticeControl(tester, planHeading);
  await revealT26PracticeControl(tester, completed);
}

Finder _inPracticeHome(Finder matching) =>
    find.descendant(of: find.byType(PracticeHomePage), matching: matching);

Finder _planTile(String title) =>
    _inPracticeHome(find.widgetWithText(ListTile, title));

Finder _completionLabel(Finder tile) =>
    find.descendant(of: tile, matching: find.text('对练关卡 · 已完成'));

Finder get _targetTile => _planTile(_targetPlanTitle);

Finder get _completedTargetLabel => _completionLabel(_targetTile);

Finder get _consentButton => find.widgetWithText(FilledButton, '了解，继续练习');

Finder get _chat => find.byType(PracticeChat);
Finder get _lobby => find.byType(PracticeLobby);
Finder get _feedback => _inChat(find.byType(PracticeResult));
Finder _inChat(Finder matching) =>
    find.descendant(of: _chat, matching: matching);

Future<void> _waitForUi(
  WidgetTester tester,
  String stage,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final clock = tester.binding.clock;
  final deadline = clock.now().add(timeout);
  var rounds = 0;
  while (true) {
    // The live binding waits in real time, allowing transport and cache I/O.
    await tester.pump(const Duration(milliseconds: 25));
    rounds++;
    if (tester.takeException() != null) {
      fail('等待「$stage」时页面抛出异常。\n${_uiSummary()}');
    }
    if (condition()) return;
    if (!clock.now().isBefore(deadline)) {
      fail(
        '等待「$stage」超时：${timeout.inMilliseconds}ms/$rounds 轮。\n'
        '${_uiSummary()}',
      );
    }
  }
}

// The route below becomes current as soon as the route above starts to pop.
bool _routeReady(ModalRoute<dynamic> route) =>
    route.isCurrent &&
    route.animation?.status == AnimationStatus.completed &&
    route.secondaryAnimation?.status == AnimationStatus.dismissed;

Future<void> _tapBack(
  WidgetTester tester,
  Finder page,
  ModalRoute<dynamic> route,
) async {
  final appBar = find.descendant(of: page, matching: find.byType(AppBar));
  final back = find
      .descendant(of: appBar, matching: find.byType(BackButton))
      .hitTestable();
  await _waitForUi(
    tester,
    '当前路由的 AppBar 返回按钮可点击',
    () =>
        _routeReady(route) &&
        back.evaluate().length == 1 &&
        identical(ModalRoute.of(tester.element(back)), route),
  );
  await tester.tap(back);
}

/// Reveals a mounted control in its own scrollable, including the chat footer.
Future<Finder> revealT26PracticeControl(
  WidgetTester tester,
  Finder target,
) async {
  expect(target, findsOneWidget);
  final visible = target.hitTestable();
  if (visible.evaluate().isEmpty) {
    await Scrollable.ensureVisible(tester.element(target), alignment: .5);
    await _waitForUi(tester, '控制项滚动后可点击', () => visible.evaluate().length == 1);
  }
  return visible;
}

Future<Json> _read(String label, Future<Json> Function() request) async {
  try {
    return await request();
  } catch (_) {
    fail('读取「$label」失败');
  }
}

String _uiSummary() =>
    '计划关卡=${_targetTile.evaluate().length}；'
    '已完成标签=${_completedTargetLabel.evaluate().length}；'
    '授权按钮=${_consentButton.evaluate().length}；'
    '聊天=${find.byType(PracticeChat).evaluate().length}；'
    '结束评分=${find.text('结束并评分').evaluate().length}；'
    '整场反馈=${find.text('整场反馈').evaluate().length}';
