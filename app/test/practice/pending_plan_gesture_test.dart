import 'dart:async';
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
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/main.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import '../onboarding/journey_test.dart' show WidgetSessions;

const _targetId = '85b72033-9f07-4bbc-8567-fc31f26508ab';
const _planTitle = '今日计划原关卡';
const _pendingKey = 'practice.creating';
final _readRetry = find.widgetWithText(TextButton, '本机续练记录读取失败，重试');
final _abandon = find.widgetWithText(TextButton, '放弃创建请求');
final _abandonRetry = find.text('重试放弃并继续');
final _chat = find.byType(PracticeChat);

void main() {
  testWidgets('放弃确认为空后，续开查询期间不再发出展示读取', (t) async {
    final fixture = await _openPlan(t);
    final targetGate = fixture.holdContinuedLookup();
    fixture.cache.beforeReadAfterAbandon = (read) async {
      if (read > 1 && !targetGate.isCompleted) {
        throw StateError('合成：目标仍在查询时，额外的本机读取失败');
      }
    };

    await t.tap(_abandon);
    await _waitForUi(
      t,
      '放弃确认后目标查询已开始并完成渲染',
      () =>
          fixture.continuedLookupStarted.isCompleted &&
          fixture.cache.readsAfterAbandon == 1 &&
          find.text('正在打开计划中的对练…').hitTestable().evaluate().isNotEmpty &&
          _readRetry.evaluate().isEmpty &&
          fixture.creates.isEmpty &&
          _chat.evaluate().isEmpty,
    );
    expect(fixture.continuedLookupStarted.isCompleted, isTrue);
    expect(targetGate.isCompleted, isFalse);
    expect(fixture.creates, isEmpty);
    expect(_chat, findsNothing);
    expect(fixture.cache.readsAfterAbandon, 1, reason: '确认空值应直接更新界面');
    expect(_readRetry, findsNothing);

    targetGate.complete();
    await _waitForChatRecovery(t);
    fixture.expectOriginalChat();
  });

  testWidgets('创建前读取失败停在大厅，显式核对后只续开一次原计划', (t) async {
    final fixture = await _openPlan(t);
    final targetGate = fixture.holdContinuedLookup();
    var guardFailed = false;
    fixture.cache.beforeReadAfterAbandon = (read) async {
      if (read > 1 && targetGate.isCompleted && !guardFailed) {
        guardFailed = true;
        throw StateError('合成：创建前无法核对本机请求');
      }
    };

    await t.tap(_abandon);
    await _waitForUi(
      t,
      '放弃确认后目标查询已开始并完成渲染',
      () =>
          fixture.continuedLookupStarted.isCompleted &&
          fixture.cache.readsAfterAbandon == 1 &&
          find.text('正在打开计划中的对练…').hitTestable().evaluate().isNotEmpty &&
          _readRetry.evaluate().isEmpty &&
          fixture.creates.isEmpty &&
          _chat.evaluate().isEmpty,
    );
    expect(fixture.continuedLookupStarted.isCompleted, isTrue);
    expect(targetGate.isCompleted, isFalse);
    targetGate.complete();
    await _waitForUi(
      t,
      '创建前读取失败后显示可重试状态',
      () =>
          guardFailed &&
          fixture.creates.isEmpty &&
          _chat.evaluate().isEmpty &&
          _enabledButton(_readRetry) &&
          _disabledLevel(),
    );

    expect(guardFailed, isTrue);
    expect(fixture.creates, isEmpty);
    expect(_chat, findsNothing);
    expect(_readRetry, findsOneWidget);
    expect(t.widget<TextButton>(_readRetry).onPressed, isNotNull);
    final manualLevel = find.widgetWithText(ListTile, '沟通练习');
    expect(t.widget<ListTile>(manualLevel).onTap, isNull);

    await t.tap(_readRetry);
    await _waitForChatRecovery(t);
    fixture.expectOriginalChat();
  });

  testWidgets('历史列表实际刷新后，放弃确认读失败仍可显式重试并续开', (t) async {
    final fixture = await _openPlan(t, failLobbyHistory: true);
    final verification = Completer<void>();
    fixture.cache.beforeReadAfterAbandon = (read) async {
      if (read == 1) await verification.future;
    };

    await t.tap(_abandon);
    await _waitForUi(
      t,
      '放弃确认读取已挂起且处理状态已渲染',
      () =>
          fixture.cache.readsAfterAbandon == 1 &&
          fixture.cache.cache[_pendingKey] == null &&
          find.text('正在处理…').hitTestable().evaluate().isNotEmpty &&
          fixture.creates.isEmpty &&
          _chat.evaluate().isEmpty,
    );
    expect(fixture.cache.readsAfterAbandon, 1);
    expect(fixture.cache.cache[_pendingKey], isNull);

    final reload = find.widgetWithText(TextButton, '读取失败，重新加载');
    await _waitForUi(
      t,
      '历史列表读取失败并提供重新加载入口',
      () => _enabledButton(reload, requireHitTest: false),
    );
    await t.ensureVisible(reload);
    await _waitForUi(t, '历史列表重新加载入口可命中', () => _enabledButton(reload));
    await t.tap(reload);
    await _waitForUi(
      t,
      '历史列表刷新完成且放弃确认仍挂起',
      () =>
          fixture.historyCalls == 3 &&
          find.text('还没有练习记录。').hitTestable().evaluate().isNotEmpty &&
          _abandonRetry.evaluate().isEmpty &&
          fixture.creates.isEmpty &&
          _chat.evaluate().isEmpty,
    );
    expect(verification.isCompleted, isFalse);
    expect(fixture.historyCalls, 3);
    expect(find.text('还没有练习记录。'), findsOneWidget);
    expect(_abandonRetry, findsNothing, reason: '确认仍在处理中');
    expect(fixture.creates, isEmpty);
    expect(_chat, findsNothing);

    verification.completeError(StateError('合成：删除已完成，确认读取失败'));
    await _waitForUi(
      t,
      '放弃确认失败后重试入口可命中',
      () =>
          _enabledButton(_abandonRetry) &&
          fixture.creates.isEmpty &&
          _chat.evaluate().isEmpty,
    );
    expect(fixture.creates, isEmpty);
    expect(_chat, findsNothing);
    expect(_abandonRetry, findsOneWidget);

    await t.tap(_abandonRetry);
    await _waitForChatRecovery(t);
    fixture.expectOriginalChat();
  });
}

bool _enabledButton(Finder finder, {bool requireHitTest = true}) {
  final elements = (requireHitTest ? finder.hitTestable() : finder).evaluate();
  if (elements.length != 1) return false;
  final widget = elements.single.widget;
  if (widget is ButtonStyleButton) return widget.enabled;
  final buttons = find
      .ancestor(
        of: finder,
        matching: find.byWidgetPredicate((item) => item is ButtonStyleButton),
      )
      .evaluate();
  return buttons.length == 1 &&
      (buttons.single.widget as ButtonStyleButton).enabled;
}

bool _disabledLevel() {
  final elements = find
      .widgetWithText(ListTile, '沟通练习')
      .hitTestable()
      .evaluate();
  if (elements.length != 1) return false;
  final widget = elements.single.widget;
  return widget is ListTile && widget.onTap == null;
}

bool _routeSettled(BuildContext context, {String? name}) {
  final route = ModalRoute.of(context);
  return route?.animation?.status == AnimationStatus.completed &&
      (name == null || route?.settings.name == name);
}

Future<void> _waitForChatRecovery(WidgetTester t) =>
    _waitForUi(t, '原练习聊天路由与详情恢复完成', () {
      final elements = _chat.hitTestable().evaluate();
      if (elements.length != 1 || !_routeSettled(t.element(_chat))) {
        return false;
      }
      return find
              .descendant(
                of: _chat,
                matching: find.byType(LinearProgressIndicator),
              )
              .evaluate()
              .isEmpty &&
          find.text('恢复会话').evaluate().isEmpty;
    });

Future<void> _waitForUi(
  WidgetTester t,
  String stage,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  final deadline = DateTime.now().add(timeout);
  var rounds = 0;
  while (true) {
    // Let real file and transport futures run before advancing the widget clock.
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await t.pump(const Duration(milliseconds: 25));
    rounds++;
    final exception = t.takeException();
    if (exception != null) {
      fail('等待「$stage」时页面抛出异常：$exception\n${_uiSummary(t)}');
    }
    if (condition()) return;
    if (DateTime.now().isAfter(deadline)) {
      fail(
        '等待「$stage」超时：${timeout.inMilliseconds}ms/$rounds 轮。\n'
        '${_uiSummary(t)}',
      );
    }
  }
}

String _uiSummary(WidgetTester t) {
  final texts = t
      .widgetList<Text>(find.byType(Text))
      .map((text) => text.data)
      .whereType<String>()
      .take(30)
      .join(' | ');
  return '可见文本：$texts；'
      '放弃按钮=${_abandon.evaluate().length}；'
      '读取重试=${_readRetry.evaluate().length}；'
      '放弃重试=${_abandonRetry.evaluate().length}；'
      '聊天=${_chat.evaluate().length}';
}

Future<_PlanFixture> _openPlan(
  WidgetTester t, {
  bool failLobbyHistory = false,
}) async {
  t.view.devicePixelRatio = 1;
  t.view.physicalSize = const Size(800, 1200);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.view.resetPhysicalSize);

  final scope = (await t.runAsync(() async {
    final directory = await Directory.systemTemp.createTemp('t27-pending-');
    try {
      return await Sessions(MemorySecret(), directory).activate(tokens('plan'));
    } finally {
      await directory.delete(recursive: true);
    }
  }))!;
  final cache = _PendingCache(scope);
  await cache.activate(tokens('plan'));
  await cache.put(
    scope,
    CacheKind.continuation,
    _pendingKey,
    utf8.encode(
      jsonEncode({
        'input': {
          'scenario': '另一场练习',
          'scene': 'work',
          'request_id': '85b72033-9f07-4bbc-8567-fc31f26508ac',
        },
      }),
    ),
  );
  final fixture = _PlanFixture(cache, failLobbyHistory: failLobbyHistory);
  await t.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWith((_) => fixture.api)],
      child: const HighEqApp(),
    ),
  );
  final planHeading = find.text('今日计划');
  final entry = find.text(_planTitle);
  await _waitForUi(
    t,
    '练习首页加载计划入口',
    () => planHeading.evaluate().isNotEmpty && entry.evaluate().isNotEmpty,
  );
  expect(planHeading, findsOneWidget);
  expect(entry, findsOneWidget);
  await t.ensureVisible(entry);
  await _waitForUi(
    t,
    '计划入口滚动后可命中',
    () => entry.hitTestable().evaluate().length == 1,
  );
  await t.tap(entry);
  await _waitForUi(
    t,
    '今日计划进入大厅并显示可操作的放弃入口',
    () =>
        _enabledButton(_abandon) &&
        _routeSettled(t.element(_abandon), name: '/training') &&
        fixture.creates.isEmpty,
  );
  expect(_abandon, findsOneWidget);
  expect(t.widget<TextButton>(_abandon).onPressed, isNotNull);
  expect(fixture.creates, isEmpty);
  return fixture;
}

class _PlanFixture {
  _PlanFixture(this.cache, {required bool failLobbyHistory}) {
    final transport = Handler()
      ..handle = (op, request) async {
        final sample = _examples[op.name] as Json;
        switch (op) {
          case AppOp.getMe:
            return response({...sample, 'user_id': cache.active!.account});
          case AppOp.getTodayPlan:
            return response({
              ...sample,
              'items': [
                {
                  ...((sample['items'] as List).single as Json),
                  'kind': 'level',
                  'title': _planTitle,
                  'content_id': _targetId,
                },
              ],
            });
          case AppOp.listConsents:
            return response({
              ...sample,
              'items': [
                for (final purpose in ['assessment', 'practice'])
                  {
                    ...((sample['items'] as List).single as Json),
                    'purpose': purpose,
                  },
              ],
            });
          case AppOp.listLevels:
            final gate = _lookupGate;
            if (gate != null && !continuedLookupStarted.isCompleted) {
              continuedLookupStarted.complete();
              await gate.future;
            }
            return response(sample);
          case AppOp.listSessions:
            if (++historyCalls == 2 && failLobbyHistory) {
              return response({'code': 'unavailable'}, 503);
            }
            return response({...sample, 'items': []});
          case AppOp.createSession:
            final body = jsonDecode(request.body) as Json;
            creates.add(body);
            return response({
              ...sample,
              'session_id': body['request_id'],
              'level_id': body['level_id'],
            }, 201);
          case AppOp.getSession:
            return response({
              ...(_examples['createSession'] as Json),
              'session_id': request.url.pathSegments.last,
              'level_id': _targetId,
            });
          default:
            return response(sample);
        }
      };
    api = AppApi(Uri.https('example.invalid'), transport, cache);
  }

  final _PendingCache cache;
  final _examples =
      jsonDecode(File('assets/contract_examples.json').readAsStringSync())
          as Json;
  late final AppApi api;
  final creates = <Json>[];
  int historyCalls = 0;
  Completer<void>? _lookupGate;
  final continuedLookupStarted = Completer<void>();

  Completer<void> holdContinuedLookup() => _lookupGate = Completer<void>();

  void expectOriginalChat() {
    expect(creates, hasLength(1));
    expect(creates.single['level_id'], _targetId);
    expect(_chat, findsOneWidget);
  }
}

class _PendingCache extends WidgetSessions {
  _PendingCache(super.known);

  var readsAfterAbandon = 0;
  var _removedPending = false;
  Future<void> Function(int read)? beforeReadAfterAbandon;

  @override
  Future<List<int>?> get(AccountScope scope, CacheKind kind, String id) async {
    if (id == _pendingKey && _removedPending) {
      readsAfterAbandon++;
      await beforeReadAfterAbandon?.call(readsAfterAbandon);
    }
    return super.get(scope, kind, id);
  }

  @override
  Future<void> remove(AccountScope scope, CacheKind kind, String id) async {
    await super.remove(scope, kind, id);
    if (id == _pendingKey) _removedPending = true;
  }
}
