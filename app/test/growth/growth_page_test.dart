import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/growth/growth_page.dart';
import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/onboarding/radar.dart';
import 'package:http/http.dart' as http;

import '../isolation_test.dart' show MemorySecret, tokens;
import '../support/real_async.dart';
import 'support/fakes.dart';

void main() {
  testWidgets('成长档案只画 WLEIS 四维并展示前后总分', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpGrowth(tester, repository);

    final radar = tester.widget<AssessmentRadar>(find.byType(AssessmentRadar));
    expect(radar.percentages.keys, ['SEA', 'OEA', 'UOE', 'ROE']);
    expect(radar.beforePercentages?.keys, ['SEA', 'OEA', 'UOE', 'ROE']);
    expect(find.text('WLEIS 四维变化'), findsOneWidget);
    expect(find.text('最近一次总分'), findsOneWidget);
    expect(find.text('更早一次'), findsWidgets);
    expect(find.textContaining('自我觉察 · 70 / 100'), findsOneWidget);
    expect(find.textContaining('读懂别人 · 64 / 100'), findsOneWidget);
    expect(find.textContaining('自我激励 · 74 / 100'), findsOneWidget);
    expect(find.textContaining('自我管理 · 63 / 100'), findsOneWidget);
  });

  testWidgets('未解锁行为分时展示精确文案且不伪造训练分', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(
        trainingReference: null,
        validBehaviorCount: 0,
        sessions: const [
          PracticeScoreData(
            sessionId: 'single-only',
            mode: 'single_skill',
            targetItem: 'feeling',
            total: 20,
            maximum: 25,
          ),
        ],
      ),
    );
    await _pumpGrowth(tester, repository);

    await _scrollTo(tester, find.text(unlockBehaviorCopy));
    expect(find.text('训练参考分 · 待解锁'), findsOneWidget);
    expect(find.text('单项练习只记录过关进度，不会生成行为分。'), findsOneWidget);
    expect(find.textContaining('基于近 30 天'), findsNothing);
    expect(find.text('70 / 100'), findsNothing);
  });

  testWidgets('已解锁时展示服务端训练参考分和有效行为数', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(trainingReference: 72, validBehaviorCount: 3),
    );
    await _pumpGrowth(tester, repository);

    await _scrollTo(tester, find.text('72 / 100'));
    expect(find.text('训练参考分'), findsOneWidget);
    expect(find.text('基于近 30 天 3 次有效完整行为记录，与 WLEIS 分开计算。'), findsOneWidget);
  });

  testWidgets('历次得分区分整场和单项，并按契约顺序标记最近与更早', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpGrowth(tester, repository);

    await _scrollTo(tester, find.text('最近一次 · 整场对练'));
    expect(find.text('最近一次 · 整场对练'), findsOneWidget);
    expect(find.text('74 / 100'), findsOneWidget);
    expect(find.text('更早一次 · 单项练习 · 感受'), findsOneWidget);
    expect(find.text('20 / 25'), findsOneWidget);
    expect(find.text('只记录这一项目标的过关进度，不计入训练参考分。'), findsOneWidget);
  });

  testWidgets('缺少完成时间的历史得分不冒充最近一次', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(
        sessions: const [
          PracticeScoreData(
            sessionId: 'legacy',
            mode: 'full_session',
            targetItem: null,
            total: 70,
            maximum: 100,
          ),
        ],
      ),
    );
    await _pumpGrowth(tester, repository);

    await _scrollTo(tester, find.text('完成时间未记录 · 整场对练'));
    expect(find.text('完成时间未记录 · 整场对练'), findsOneWidget);
    expect(find.text('最近一次 · 整场对练'), findsNothing);
  });

  testWidgets('无测评和无得分时展示可执行空状态', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(
        assessments: const [],
        sessions: const [],
        trainingReference: null,
        validBehaviorCount: 0,
      ),
    );
    await _pumpGrowth(tester, repository);

    expect(find.text('还没有 WLEIS 四维记录'), findsOneWidget);
    await _scrollTo(tester, find.text('还没有可展示的得分'));
    expect(find.text('完成一次整场对练或单项练习后，分数会按最近一次到更早一次排列。'), findsOneWidget);
  });

  testWidgets('加载失败读取缓存并保留历史成就', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      cachedSnapshot: sampleSnapshot(
        trainingReference: null,
        validBehaviorCount: 0,
        achievements: const [3, 7],
      ),
      loadError: StateError('offline'),
    );
    await _pumpGrowth(tester, repository);

    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsOneWidget);
    await _scrollTo(tester, find.text('阶段成就'));
    final handle = tester.ensureSemantics();
    try {
      await tester.pump();
      expect(find.bySemanticsLabel('成就，连续 7 天，已达成'), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('401 不读取成长缓存并清除授权数据', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      cachedSnapshot: sampleSnapshot(),
      loadError: const ApiFailure(401, 'unauthenticated', '请重新登录', false),
    );

    await _pumpGrowth(tester, repository);

    expect(find.text('登录凭证无效或已过期，请重新验证。'), findsOneWidget);
    expect(find.text('WLEIS 四维变化'), findsNothing);
    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsNothing);
    expect(repository.cachedCalls, 0);
    expect(repository.clearCacheCalls, 1);
  });

  testWidgets('真实客户端业务 401 且 refresh 失败时隐藏缓存', (tester) async {
    final transport = _StatusTransport(401);
    final repository = await _realGrowthRepository(tester, transport);
    await runRealAsync(tester, () => repository.saveCache(sampleSnapshot()));

    await tester.pumpWidget(_growthApp(repository));
    await _driveRealGrowth(tester, repository.cacheCleared);

    expect(find.text('登录凭证无效或已过期，请重新验证。'), findsOneWidget);
    expect(find.text('WLEIS 四维变化'), findsNothing);
    expect(find.textContaining('自我觉察 · 70 / 100'), findsNothing);
    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsNothing);
    expect(transport.calls, greaterThan(1));
  });

  testWidgets('真实客户端普通 503 时展示离线缓存', (tester) async {
    final transport = _StatusTransport(503);
    final repository = await _realGrowthRepository(tester, transport);
    await runRealAsync(tester, () => repository.saveCache(sampleSnapshot()));

    await tester.pumpWidget(_growthApp(repository));
    await _driveRealGrowth(tester, repository.cacheRead);

    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsOneWidget);
    expect(find.text('WLEIS 四维变化'), findsOneWidget);
    expect(find.textContaining('自我觉察 · 70 / 100'), findsOneWidget);
  });

  testWidgets('删除清理缓存后 503 不回退旧分，恢复后展示服务端剩余评分', (tester) async {
    final transport = _SwitchableGrowthTransport();
    transport.fixtures =
        jsonDecode(
              await runRealAsync(
                tester,
                () => File('assets/contract_examples.json').readAsString(),
              ),
            )
            as Map<String, dynamic>;
    final repository = await _realGrowthRepository(tester, transport);
    await runRealAsync(tester, () => repository.saveCache(sampleSnapshot()));
    await runRealAsync(tester, repository.clearCache);

    await tester.pumpWidget(_growthApp(repository));
    await _driveRealGrowth(tester, repository.cacheRead);

    expect(find.text('服务暂不可用，请稍后重试。'), findsOneWidget);
    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsNothing);
    expect(find.text('WLEIS 四维变化'), findsNothing);
    expect(find.text('70 / 100'), findsNothing);
    expect(find.text('74 / 100'), findsNothing);
    expect(find.text('20 / 25'), findsNothing);

    repository.loadCompleted = Completer<void>();
    transport.status = 200;
    await tester.tap(find.text('重新加载'));
    await tester.pump();
    await _driveRealGrowth(tester, repository.loadCompleted);

    await _scrollTo(tester, find.text('62 / 100'));
    expect(find.text('62 / 100'), findsOneWidget);
    await _scrollTo(tester, find.text('66 / 100'));
    expect(find.text('66 / 100'), findsOneWidget);
    expect(find.text('最近一次 · 整场对练'), findsOneWidget);
    expect(find.text('74 / 100'), findsNothing);
    expect(find.text('20 / 25'), findsNothing);
    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsNothing);
  });

  testWidgets('刷新收到 403 后清空已展示的成长数据', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpGrowth(tester, repository);
    expect(find.text('WLEIS 四维变化'), findsOneWidget);

    repository.loadError = const ApiFailure(403, 'forbidden', '无权访问', false);
    unawaited(
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show(),
    );
    await tester.pumpAndSettle();

    expect(find.text('没有获得所需授权，请重新确认。'), findsOneWidget);
    expect(find.text('WLEIS 四维变化'), findsNothing);
    expect(repository.cachedCalls, 0);
    expect(repository.clearCacheCalls, 1);
  });

  testWidgets('复测到期和未到期分别出现正确提醒', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpGrowth(
      tester,
      repository,
      now: () => DateTime.utc(2026, 11, 22),
    );
    expect(find.text('四周复测提醒'), findsOneWidget);
    expect(find.textContaining('还有 14 天可以复测'), findsOneWidget);

    await tester.pumpWidget(
      _growthApp(repository, now: () => DateTime.utc(2026, 12, 10)),
    );
    await tester.pumpAndSettle();
    expect(find.text('四周复测已到期'), findsOneWidget);
    expect(find.text('去复测'), findsOneWidget);
  });

  testWidgets('应用前台恢复后立即更新复测到期提醒', (tester) async {
    var current = DateTime.utc(2026, 11, 22);
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpGrowth(tester, repository, now: () => current);

    expect(find.text('四周复测提醒'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    current = DateTime.utc(2026, 12, 10);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(find.text('四周复测已到期'), findsOneWidget);
    expect(find.text('去复测'), findsOneWidget);
  });

  testWidgets('仓库切换后旧账号迟到响应不会覆盖新账号成长档案', (tester) async {
    final firstCompleter = Completer<GrowthSnapshot>();
    final first = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      loadCompleter: firstCompleter,
    );
    final second = FakeGrowthRepository(
      snapshot: sampleSnapshot(
        assessments: [
          AssessmentData(
            id: 'b-assessment',
            completedAt: DateTime.utc(2026, 11, 1),
            nextEligibleAt: DateTime.utc(2026, 11, 29),
            dimensions: const {'SEA': 41, 'OEA': 42, 'UOE': 43, 'ROE': 44},
            totalPercent: 42.5,
          ),
        ],
      ),
    );

    await _pumpGrowth(tester, first, settle: false);
    await tester.pumpWidget(_growthApp(second));
    await tester.pumpAndSettle();

    expect(find.textContaining('自我觉察 · 41 / 100'), findsOneWidget);
    expect(first.loadCalls, 1);
    expect(second.loadCalls, 1);

    firstCompleter.complete(sampleSnapshot());
    await tester.pumpAndSettle();

    expect(find.textContaining('自我觉察 · 41 / 100'), findsOneWidget);
    expect(find.textContaining('自我觉察 · 70 / 100'), findsNothing);
  });

  testWidgets('320px 与 1.8 倍字号下成长档案可滚动且无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());

    await tester.pumpWidget(_growthApp(repository, textScale: 1.8));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _scrollTo(tester, find.text('阶段成就'));
    expect(find.text('连续 3 / 7 / 30 天。已获得的成就会保留，不因断卡消失。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _StatusTransport implements Transport {
  _StatusTransport(this.status);
  final int status;
  int calls = 0;

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    calls++;
    final code = op == AppOp.refreshTokens ? 500 : status;
    return http.StreamedResponse(
      Stream.value(
        utf8.encode(
          jsonEncode({
            'code': code == 401 ? 'unauthenticated' : 'unavailable',
            'message': code == 401
                ? 'account frozen'
                : 'temporarily unavailable',
          }),
        ),
      ),
      code,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() {}
}

class _SwitchableGrowthTransport implements Transport {
  int status = 503;
  int calls = 0;
  Map<String, dynamic>? fixtures;

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    calls++;
    if (status != 200) {
      return _response({
        'code': 'unavailable',
        'message': 'temporarily unavailable',
        'retryable': true,
      }, status);
    }
    final data = switch (op) {
      AppOp.getGrowth => {
        ...(fixtures!['getGrowth'] as Map<String, dynamic>),
        'training_reference': 62,
        'valid_behavior_count': 1,
      },
      AppOp.listSessions => {
        'items': [
          {
            'session_id': 'remaining-session',
            'status': 'finished',
            'mode': 'full_session',
            'target_item': null,
            'messages': <Object>[],
            'completed_at': '2026-11-21T09:00:00+08:00',
            'result': {
              'mode': 'full_session',
              'score': {
                'nvc': {'total': 66},
              },
            },
          },
        ],
        'next_cursor': null,
      },
      _ => fixtures![op.name] as Map<String, dynamic>,
    };
    return _response(data, 200);
  }

  http.StreamedResponse _response(Map<String, dynamic> data, int code) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(data))),
        code,
        headers: {'content-type': 'application/json'},
      );

  @override
  void close() {}
}

class _TrackedGrowthRepository extends ApiGrowthRepository {
  _TrackedGrowthRepository(super.api, super.scope);

  final cacheRead = Completer<void>();
  final cacheCleared = Completer<void>();
  Completer<void> loadCompleted = Completer<void>();

  @override
  Future<GrowthSnapshot> load() async {
    try {
      return await super.load();
    } finally {
      if (!loadCompleted.isCompleted) loadCompleted.complete();
    }
  }

  @override
  Future<GrowthSnapshot?> cached() async {
    try {
      return await super.cached();
    } finally {
      if (!cacheRead.isCompleted) cacheRead.complete();
    }
  }

  @override
  Future<void> clearCache() async {
    try {
      await super.clearCache();
    } finally {
      if (!cacheCleared.isCompleted) cacheCleared.complete();
    }
  }
}

Future<_TrackedGrowthRepository> _realGrowthRepository(
  WidgetTester tester,
  Transport transport,
) async {
  final setup = await runRealAsync(tester, () async {
    final dir = await Directory.systemTemp.createTemp('t27-growth-widget-');
    final sessions = Sessions(MemorySecret(), dir);
    final api = AppApi(Uri.https('test.invalid'), transport, sessions);
    final scope = await sessions.activate(tokens('A'));
    return (dir: dir, repository: _TrackedGrowthRepository(api, scope));
  });
  addTearDown(() => setup.dir.delete(recursive: true));
  return setup.repository;
}

/// Drives the widget fake-async zone and the real file-I/O event loop together.
///
/// Widgets start [_TrackedGrowthRepository] work in the fake-async zone. File
/// operations complete on the real event loop, while their continuations need a
/// pump. Waiting on the repository future from a single [runAsync] call blocks
/// both halves and hangs until the test timeout.
Future<void> _driveRealGrowth(
  WidgetTester tester,
  Completer<void> completed,
) async {
  await pumpRealAsyncUntil(
    tester,
    () =>
        completed.isCompleted &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty,
    reason: '真实成长缓存流程未完成',
  );
}

Future<void> _pumpGrowth(
  WidgetTester tester,
  GrowthRepository repository, {
  DateTime Function()? now,
  bool settle = true,
}) async {
  await tester.pumpWidget(_growthApp(repository, now: now));
  if (settle) await tester.pumpAndSettle();
}

Widget _growthApp(
  GrowthRepository repository, {
  DateTime Function()? now,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: HomeShell(
    Section.growth,
    content: GrowthPage(
      repository: repository,
      now: now ?? () => DateTime.utc(2026, 11, 22),
    ),
  ),
  routes: {
    '/assessment': (_) => const Scaffold(body: Text('测评占位')),
    '/training': (_) => const Scaffold(body: Text('训练占位')),
    '/scene': (_) => const Scaffold(body: Text('场景占位')),
  },
);

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    340,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 30,
  );
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}
