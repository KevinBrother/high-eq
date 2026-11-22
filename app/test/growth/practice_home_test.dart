import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/features/marks/page.dart';
import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/growth/widgets.dart' show StreakBadge;
import 'package:high_eq/features/home/shell.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('练习首页展示今日计划、进度、连续天数与知识卡', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());

    await _pumpPractice(tester, repository);

    expect(find.text('今日计划'), findsOneWidget);
    expect(find.text('0 / 3 已完成'), findsOneWidget);
    expect(find.text('读人小练习 · 听出弦外之音'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(StreakBadge),
        matching: find.text('连续 6 天'),
      ),
      findsOneWidget,
    );
    expect(find.text('今天的小练习还在等你'), findsOneWidget);

    await _scrollTo(tester, find.text('事实和评价要分开'));
    expect(find.text('事实和评价要分开'), findsOneWidget);
  });

  testWidgets('读人小练习可选择、查看解析并完成打卡', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpPractice(tester, repository);

    await tester.tap(find.text('读人小练习 · 听出弦外之音'));
    await tester.pumpAndSettle();
    expect(find.text('同事说“随便吧”，但你感觉他并不轻松。下面哪种回应更可能读懂对方？'), findsOneWidget);

    await tester.tap(find.text('我听到你有点顾虑，要不要说说最担心哪一点？'));
    await tester.pump();
    await tester.tap(find.text('看看我读对了吗'));
    await tester.pumpAndSettle();

    expect(find.text('读到了'), findsOneWidget);
    expect(find.text('你保留了对方的字面意思，也用开放问题确认了顾虑。'), findsOneWidget);

    await tester.tap(find.text('完成今日练习'));
    await tester.pumpAndSettle();

    expect(repository.answerCalls, 1);
    expect(repository.completeCalls, 1);
    expect(find.text('读人小练习 · 已完成'), findsOneWidget);
    expect(find.text('已打卡 · 连续 7 天'), findsOneWidget);
  });

  testWidgets('知识卡可阅读并完成计划项', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpPractice(tester, repository);

    await _scrollTo(tester, find.text('知识卡 · 事实和评价要分开'));
    await tester.tap(find.text('知识卡 · 事实和评价要分开'));
    await tester.pumpAndSettle();
    expect(find.text('“你总是迟到”是评价；“这周有两次会议你晚到了十分钟”是事实。'), findsOneWidget);

    await tester.tap(find.text('读完了，记为完成'));
    await tester.pumpAndSettle();

    expect(repository.cardCalls, 1);
    expect(repository.completeCalls, 1);
    await _scrollTo(tester, find.text('知识卡 · 已完成'));
    expect(find.text('知识卡 · 已完成'), findsOneWidget);
  });

  testWidgets('新成就弹窗只展示新增阶段且保留已有成就', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(achievements: const [3]),
      completion: const CompletionData(streak: 7, achievements: [3, 7]),
    );
    await _pumpPractice(tester, repository);

    await tester.tap(find.text('读人小练习 · 听出弦外之音'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我听到你有点顾虑，要不要说说最担心哪一点？'));
    await tester.pump();
    await tester.tap(find.text('看看我读对了吗'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成今日练习'));
    await tester.pumpAndSettle();

    expect(find.text('新成就解锁'), findsOneWidget);
    expect(find.textContaining('你已经连续练习 7 天'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('3 天'),
      ),
      findsNothing,
    );

    await tester.tap(find.text('收下'));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('坚持的痕迹'));
    final handle = tester.ensureSemantics();
    try {
      await tester.pump();
      expect(find.bySemanticsLabel('成就，连续 3 天，已达成'), findsOneWidget);
      expect(find.bySemanticsLabel('成就，连续 7 天，已达成'), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('加载失败时读取离线缓存并可重试恢复', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(planTitle: '在线计划'),
      cachedSnapshot: sampleSnapshot(
        planTitle: '缓存计划',
        achievements: const [3, 7],
      ),
      loadError: StateError('offline'),
    );
    await _pumpPractice(tester, repository);

    expect(find.text('缓存计划'), findsOneWidget);
    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsOneWidget);
    await _scrollTo(tester, find.text('坚持的痕迹'));
    final handle = tester.ensureSemantics();
    try {
      await tester.pump();
      expect(find.bySemanticsLabel('成就，连续 7 天，已达成'), findsOneWidget);
    } finally {
      handle.dispose();
    }

    repository.loadError = null;
    await _scrollTo(tester, find.text('重试'), delta: -320);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('在线计划'), findsOneWidget);
    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsNothing);
  });

  testWidgets('加载失败且无缓存时展示可重试错误页', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      loadError: StateError('offline'),
    );
    await _pumpPractice(tester, repository);

    expect(find.text('暂时无法加载，请检查连接后重试。'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
  });

  testWidgets('无计划与无知识卡时保留可执行空状态', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(
        includePlan: false,
        includeCards: false,
        assessments: const [],
        sessions: const [],
        trainingReference: null,
        validBehaviorCount: 0,
      ),
    );
    await _pumpPractice(tester, repository);

    expect(find.text('今天还没有练习安排'), findsOneWidget);
    expect(find.text('完成测评后会自动生成计划；也可以先自由练习。'), findsOneWidget);
    await _scrollTo(tester, find.text('今天暂无知识卡'));
    expect(find.text('今天暂无知识卡'), findsOneWidget);
  });

  testWidgets('练习内容加载失败保留重试入口', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      exerciseError: StateError('exercise unavailable'),
    );
    await _pumpPractice(tester, repository);

    await tester.tap(find.text('读人小练习 · 听出弦外之音'));
    await tester.pumpAndSettle();

    expect(find.text('暂时无法加载，请检查连接后重试。'), findsOneWidget);
    expect(find.text('重新加载'), findsOneWidget);
  });

  testWidgets('训练、续答、手动标记与场景入口均保留', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpPractice(tester, repository);

    await _scrollTo(tester, find.text('切换练习场景'));
    expect(find.text('对练与预演'), findsOneWidget);
    expect(find.text('本次自评与续答'), findsOneWidget);
    expect(find.text('手动标记'), findsOneWidget);
    expect(find.text('切换练习场景'), findsOneWidget);

    await tester.tap(find.text('手动标记'));
    await tester.pumpAndSettle();
    expect(find.byType(MarksPage), findsOneWidget);
    expect(find.text('先记下，不急着解释。'), findsOneWidget);
  });

  testWidgets('成功加载后无需预先滚动即可发现续答入口', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());

    await _pumpPractice(tester, repository);

    expect(find.text('本次自评与续答'), findsOneWidget);
  });

  testWidgets('四个快捷入口的语义节点均可通过 tap 导航', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
      const destinations = [
        ('对练与预演', '训练占位'),
        ('本次自评与续答', '测评占位'),
        ('手动标记', '先记下，不急着解释。'),
        ('切换练习场景', '场景占位'),
      ];

      await _pumpPractice(tester, repository);

      for (final (label, destination) in destinations) {
        await _scrollTo(tester, find.text(label));
        final finder = find.semantics.byLabel(label);
        expect(finder, findsOneWidget);
        final node = finder.evaluate().single;
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
          reason: '$label 应暴露语义 tap 动作',
        );

        tester.semantics.tap(finder);
        await tester.pumpAndSettle();
        expect(find.text(destination), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('今日数据加载中仍可从真实首页进入续答、对练和场景', (tester) async {
    final completer = Completer<GrowthSnapshot>();
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      loadCompleter: completer,
    );

    await _pumpPractice(tester, repository, settle: false);
    await tester.pump();

    expect(find.text('本次自评与续答'), findsOneWidget);
    expect(find.text('对练与预演'), findsOneWidget);
    expect(find.text('切换练习场景'), findsOneWidget);

    await _scrollTo(tester, find.text('本次自评与续答'));
    await tester.tap(find.text('本次自评与续答'));
    await _pumpRoute(tester);
    expect(find.text('测评占位'), findsOneWidget);

    await tester.pageBack();
    await _pumpRoute(tester);

    await _scrollTo(tester, find.text('对练与预演'));
    await tester.tap(find.text('对练与预演'));
    await _pumpRoute(tester);
    expect(find.text('训练占位'), findsOneWidget);

    await tester.pageBack();
    await _pumpRoute(tester);

    await _scrollTo(tester, find.text('切换练习场景'));
    await tester.tap(find.text('切换练习场景'));
    await _pumpRoute(tester);
    expect(find.text('场景占位'), findsOneWidget);

    completer.complete(sampleSnapshot());
    await _pumpRoute(tester);
  });

  testWidgets('单个 T26 接口 500 时仍保留不依赖今日数据的入口', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      loadError: const ApiFailure(500, 'unavailable', '暂不可用', true),
    );

    await _pumpPractice(tester, repository);

    expect(find.text('服务暂不可用，请稍后重试。').hitTestable(), findsOneWidget);
    expect(find.text('本次自评与续答'), findsOneWidget);
    expect(find.text('对练与预演'), findsOneWidget);
    expect(find.text('切换练习场景'), findsOneWidget);

    await _scrollTo(tester, find.text('本次自评与续答'));
    await tester.tap(find.text('本次自评与续答'));
    await tester.pumpAndSettle();
    expect(find.text('测评占位'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('切换练习场景'));
    await tester.tap(find.text('切换练习场景'));
    await tester.pumpAndSettle();
    expect(find.text('场景占位'), findsOneWidget);
  });

  testWidgets('计划中的对练关卡携带 content_id 导航', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    Object? trainingArgument;

    await tester.pumpWidget(
      _practiceApp(
        repository,
        onTrainingOpen: (argument) => trainingArgument = argument,
      ),
    );
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('对练 · 把拒绝说得清楚又不伤人'));
    await tester.tap(find.text('对练 · 把拒绝说得清楚又不伤人'));
    await tester.pumpAndSettle();

    expect(trainingArgument, 'level-content');
  });

  testWidgets('401 不读取旧缓存，清除授权数据并保留安全入口', (tester) async {
    final repository = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      cachedSnapshot: sampleSnapshot(planTitle: '不应展示的缓存计划', streak: 99),
      loadError: const ApiFailure(401, 'unauthenticated', '请重新登录', false),
    );

    await _pumpPractice(tester, repository);

    expect(find.text('登录凭证无效或已过期，请重新验证。'), findsOneWidget);
    expect(find.text('不应展示的缓存计划'), findsNothing);
    expect(find.text('连续 99 天'), findsNothing);
    expect(find.text('当前显示这台设备上的离线数据，历史成就会保留。'), findsNothing);
    expect(repository.cachedCalls, 0);
    expect(repository.clearCacheCalls, 1);
    expect(find.text('本次自评与续答'), findsOneWidget);
  });

  testWidgets('刷新收到 403 后立即清空已展示的敏感计划与分数', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpPractice(tester, repository);
    expect(find.text('读人小练习 · 听出弦外之音'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(StreakBadge),
        matching: find.text('连续 6 天'),
      ),
      findsOneWidget,
    );

    repository.loadError = const ApiFailure(403, 'forbidden', '无权访问', false);
    unawaited(
      tester.state<RefreshIndicatorState>(find.byType(RefreshIndicator)).show(),
    );
    await tester.pumpAndSettle();

    expect(find.text('没有获得所需授权，请重新确认。'), findsOneWidget);
    expect(find.text('读人小练习 · 听出弦外之音'), findsNothing);
    expect(find.text('连续 6 天'), findsNothing);
    expect(repository.clearCacheCalls, 1);
    expect(repository.cachedCalls, 0);
  });

  testWidgets('复测到期时首页显示按时提醒', (tester) async {
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpPractice(
      tester,
      repository,
      now: () => DateTime.utc(2026, 12, 10),
    );

    expect(find.text('四周复测已到期'), findsOneWidget);
    expect(find.text('去复测'), findsOneWidget);
  });

  testWidgets('复测到达截止时间后无需重新加载即可更新提醒', (tester) async {
    var current = DateTime.utc(2026, 12, 5, 23, 59, 59);
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpPractice(tester, repository, now: () => current);

    expect(find.text('四周复测已到期'), findsNothing);
    expect(find.text('今天的小练习还在等你'), findsOneWidget);

    current = DateTime.utc(2026, 12, 6);
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('四周复测已到期'), findsOneWidget);
  });

  testWidgets('仓库切换后重新加载，旧账号迟到响应不会覆盖新账号', (tester) async {
    final firstCompleter = Completer<GrowthSnapshot>();
    final first = FakeGrowthRepository(
      snapshot: sampleSnapshot(),
      loadCompleter: firstCompleter,
    );
    final second = FakeGrowthRepository(
      snapshot: sampleSnapshot(planTitle: 'B 账号计划', streak: 2),
    );

    await _pumpPractice(tester, first, settle: false);
    await tester.pumpWidget(_practiceApp(second));
    await tester.pumpAndSettle();

    expect(find.text('B 账号计划'), findsOneWidget);
    expect(first.loadCalls, 1);
    expect(second.loadCalls, 1);

    firstCompleter.complete(sampleSnapshot(planTitle: 'A 账号迟到计划'));
    await tester.pumpAndSettle();

    expect(find.text('B 账号计划'), findsOneWidget);
    expect(find.text('A 账号迟到计划'), findsNothing);
  });

  testWidgets('同账号打卡后忽略较早发起的刷新结果', (tester) async {
    final staleLoad = Completer<GrowthSnapshot>();
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());
    await _pumpPractice(tester, repository);

    repository.loadQueue.add(staleLoad);
    final refresh = tester
        .widget<RefreshIndicator>(find.byType(RefreshIndicator))
        .onRefresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(repository.loadCalls, 2);

    await tester.tap(find.text('读人小练习 · 听出弦外之音'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我听到你有点顾虑，要不要说说最担心哪一点？'));
    await tester.pump();
    await tester.tap(find.text('看看我读对了吗'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成今日练习'));
    await tester.pumpAndSettle();

    expect(find.text('读人小练习 · 已完成'), findsOneWidget);
    expect(find.text('已打卡 · 连续 7 天'), findsOneWidget);

    staleLoad.complete(sampleSnapshot());
    await refresh;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('读人小练习 · 已完成'), findsOneWidget);
    expect(find.text('已打卡 · 连续 7 天'), findsOneWidget);
    final title = tester.widget<Text>(find.text('读人小练习 · 听出弦外之音'));
    expect(title.style?.decoration, TextDecoration.lineThrough);
    expect(repository.savedSnapshot?.plan.completed, 1);
    expect(repository.savedSnapshot?.growth.streak, 7);
  });

  testWidgets('默认 800×600 首屏优先展示今日计划且入口可手势到达', (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());

    await _pumpPractice(tester, repository);

    expect(find.text('今日计划'), findsOneWidget);
    expect(find.text('读人小练习 · 听出弦外之音').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await _scrollTo(tester, find.text('切换练习场景'));
    await tester.tap(find.text('切换练习场景'));
    await tester.pumpAndSettle();
    expect(find.text('场景占位'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px 与 1.8 倍字号下练习首页可滚动且无溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FakeGrowthRepository(snapshot: sampleSnapshot());

    await tester.pumpWidget(_practiceApp(repository, textScale: 1.8));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _scrollTo(tester, find.text('本次自评与续答'));
    await tester.tap(find.text('本次自评与续答'));
    await tester.pumpAndSettle();
    expect(find.text('测评占位'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('切换练习场景'));
    await tester.tap(find.text('切换练习场景'));
    await tester.pumpAndSettle();
    expect(find.text('场景占位'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('坚持的痕迹'));
    expect(find.text('阶段成就不会因为断卡而清空。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPractice(
  WidgetTester tester,
  GrowthRepository repository, {
  DateTime Function()? now,
  bool settle = true,
}) async {
  await tester.pumpWidget(_practiceApp(repository, now: now));
  if (settle) await tester.pumpAndSettle();
}

Widget _practiceApp(
  GrowthRepository repository, {
  DateTime Function()? now,
  double textScale = 1,
  ValueChanged<Object?>? onTrainingOpen,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: HomeShell(
    Section.practice,
    content: PracticeHomePage(
      repository: repository,
      now: now ?? () => DateTime.utc(2026, 11, 22),
    ),
  ),
  routes: {
    '/marks': (_) => MarksPage(_EmptyMarkBook()),
    '/assessment': (_) => Scaffold(appBar: AppBar(), body: const Text('测评占位')),
    '/training': (context) {
      onTrainingOpen?.call(ModalRoute.of(context)?.settings.arguments);
      return Scaffold(appBar: AppBar(), body: const Text('训练占位'));
    },
    '/scene': (_) => Scaffold(appBar: AppBar(), body: const Text('场景占位')),
    '/growth': (_) => Scaffold(appBar: AppBar(), body: const Text('成长占位')),
  },
);

class _EmptyMarkBook extends Fake implements MarkBook {
  _EmptyMarkBook();

  @override
  bool get demo => false;

  @override
  Future<({List<Mark> items, String? next})> history([String? cursor]) async =>
      (items: const <Mark>[], next: null);
}

// Loading can remain pending across navigation, so an indeterminate spinner
// may continue to schedule frames even after the route animation has ended.
Future<void> _pumpRoute(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

Future<void> _scrollTo(
  WidgetTester tester,
  Finder target, {
  double delta = 320,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 30,
  );
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await _pumpRoute(tester);
}
