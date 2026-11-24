import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/routes.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/features/practice/lobby.dart';
import 'package:high_eq/features/practice/providers.dart';
import 'package:high_eq/features/practice/repository.dart';

class TargetPractice extends DemoPractice {
  final creates = <Json>[];
  bool loseFirst = false;

  @override
  Future<Json> create(Json body) async {
    creates.add(body);
    final session = await super.create(body);
    if (loseFirst && creates.length == 1) throw const FormatException();
    return session;
  }
}

class FlakyTarget extends TargetPractice {
  int findCalls = 0;
  Completer<Json?>? retryGate;
  bool _retryGateServed = false;

  @override
  Future<Json?> findLevel(String id) async {
    findCalls++;
    if (findCalls == 1) {
      throw const ApiFailure(503, 'unavailable', '计划暂时无法加载，请重试。', true);
    }
    final gate = retryGate;
    if (gate != null && !_retryGateServed) {
      _retryGateServed = true;
      return gate.future;
    }
    return super.findLevel(id);
  }
}

class GatedTarget extends TargetPractice {
  int findCalls = 0;
  final gate = Completer<Json?>();

  @override
  Future<Json?> findLevel(String id) {
    findCalls++;
    return gate.future;
  }
}

class FailingTarget extends TargetPractice {
  FailingTarget(this.failure);
  final ApiFailure failure;
  int findCalls = 0;

  @override
  Future<Json?> findLevel(String id) {
    findCalls++;
    throw failure;
  }
}

class GatedCreateTarget extends DemoPractice {
  int findCalls = 0;
  final creates = <Json>[];
  final createStarted = Completer<void>();
  final createGate = Completer<void>();

  @override
  Future<Json?> findLevel(String id) {
    findCalls++;
    return super.findLevel(id);
  }

  @override
  Future<Json> create(Json body) async {
    creates.add(body);
    if (!createStarted.isCompleted) createStarted.complete();
    await createGate.future;
    return super.create(body);
  }
}

class AbandonWriteThenThrowTarget extends TargetPractice {
  int removals = 0;
  bool throwAfterWrite = true;

  @override
  Future<void> remember(String key, Json? value) async {
    if (key != 'creating' || value != null) {
      await super.remember(key, value);
      return;
    }
    removals++;
    await super.remember(key, value);
    if (throwAfterWrite) {
      throwAfterWrite = false;
      throw StateError('合成：删除已落盘但回执丢失');
    }
  }
}

class AbandonReadFailureTarget extends TargetPractice {
  int removals = 0;
  int verificationReads = 0;
  int verificationReadFailures = 2;
  bool _verifyAfterRemoval = false;

  @override
  Future<void> remember(String key, Json? value) async {
    await super.remember(key, value);
    if (key == 'creating' && value == null) {
      removals++;
      _verifyAfterRemoval = true;
    }
  }

  @override
  Future<Json?> read(String key) async {
    if (key == 'creating' && _verifyAfterRemoval) {
      verificationReads++;
      if (verificationReadFailures > 0) {
        verificationReadFailures--;
        throw StateError('合成：删除后连续读取失败');
      }
    }
    return super.read(key);
  }
}

class QueryRaceTarget extends TargetPractice {
  int findCalls = 0;
  final firstFind = Completer<Json?>();

  @override
  Future<Json?> findLevel(String id) {
    findCalls++;
    if (findCalls == 1) return firstFind.future;
    return super.findLevel(id);
  }
}

class GatedAbandonTarget extends TargetPractice {
  int removals = 0;
  final removeStarted = Completer<void>();
  final removeGate = Completer<void>();

  @override
  Future<void> remember(String key, Json? value) async {
    if (key == 'creating' && value == null) {
      removals++;
      if (!removeStarted.isCompleted) removeStarted.complete();
      await removeGate.future;
    }
    await super.remember(key, value);
  }
}

class GatedHistoryTarget extends TargetPractice {
  final historyGate = Completer<void>();
  int historyCalls = 0;

  @override
  Future<List<Json>> history() async {
    historyCalls++;
    if (historyCalls == 1) await historyGate.future;
    return super.history();
  }
}

class RefreshTick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

Future<void> openTrainingRoute(
  WidgetTester t,
  PracticeRepository repo,
  String targetId,
) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        practiceRepositoryProvider.overrideWithValue(repo),
        contactSpaceProvider.overrideWithValue((
          scene: SceneMemory(),
          repo: null,
          demo: true,
        )),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.pushNamed(
                  context,
                  '/training',
                  arguments: targetId,
                ),
                child: const Text('打开今日计划'),
              ),
            ),
          ),
        ),
        routes: {'/training': (_) => const PracticeRoute()},
      ),
    ),
  );
  await t.tap(find.text('打开今日计划'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('计划目标瞬时查询失败后只允许一次显式手势重试', (t) async {
    final r = FlakyTarget();
    final target = (await r.levels(Scene.social, null)).last;
    r.retryGate = Completer<Json?>();

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: r,
          scene: SceneMemory(),
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(r.findCalls, 1);
    expect(r.creates, isEmpty);
    final retry = find.text('重试打开计划中的对练');
    expect(retry, findsOneWidget);

    await t.tap(retry);
    await t.tap(retry);
    await t.pump();
    expect(r.findCalls, 2);
    expect(find.text('正在打开计划中的对练…'), findsOneWidget);
    expect(retry, findsNothing);

    final gate = r.retryGate;
    expect(gate, isNotNull);
    gate!.complete(target);
    await t.pumpAndSettle();
    expect(r.creates, hasLength(1));
    expect(r.creates.single['level_id'], target['id']);
  });

  testWidgets('计划目标重试再次失败后不再提供第三次入口', (t) async {
    final r = FailingTarget(
      const ApiFailure(503, 'unavailable', '计划暂时无法加载，请重试。', true),
    );

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: r,
          scene: SceneMemory(),
          targetLevelId: 'retrying-level',
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(r.findCalls, 1);
    await t.tap(find.text('重试打开计划中的对练'));
    await t.pumpAndSettle();

    expect(r.findCalls, 2);
    expect(r.creates, isEmpty);
    expect(find.text('重试打开计划中的对练'), findsNothing);
    expect(find.text('暂时无法打开计划中的对练，请返回今日计划稍后再试。'), findsOneWidget);
  });

  testWidgets('正式返回按钮退场时迟到的目标查询不创建也不打开聊天', (t) async {
    final r = GatedTarget();
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    expect(r.findCalls, 1);
    expect(find.byType(BackButton), findsOneWidget);

    await t.tap(find.byType(BackButton));
    await t.pump();
    r.gate.complete(target);
    await t.pumpAndSettle();

    expect(r.creates, isEmpty);
    expect(find.text('情景预演'), findsNothing);
  });

  testWidgets('正式返回按钮退场时迟到的创建回执不打开聊天', (t) async {
    final r = GatedCreateTarget();
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    expect(r.createStarted.isCompleted, isTrue);
    expect(r.creates, hasLength(1));
    expect(find.byType(BackButton), findsOneWidget);

    await t.tap(find.byType(BackButton));
    await t.pump();
    r.createGate.complete();
    await t.pumpAndSettle();

    expect(r.creates, hasLength(1));
    expect(find.text('情景预演'), findsNothing);
  });

  testWidgets('正式返回按钮退场时迟到的历史比对不打开聊天', (t) async {
    final r = GatedHistoryTarget();
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    expect(r.creates, hasLength(1));
    expect(r.historyCalls, greaterThanOrEqualTo(1));
    expect(find.byType(BackButton), findsOneWidget);

    await t.tap(find.byType(BackButton));
    await t.pump();
    r.historyGate.complete();
    await t.pumpAndSettle();

    expect(find.text('情景预演'), findsNothing);
  });

  testWidgets('旧 pending 冲突后放弃会继续打开原计划目标', (t) async {
    final r = TargetPractice();
    await r.remember('creating', {
      'input': {
        'scenario': '无关的旧草稿',
        'scene': 'work',
        'request_id': 'stale-pending',
      },
    });
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    await t.pumpAndSettle();

    expect(r.creates, isEmpty);
    expect(find.text('先恢复上次创建，或放弃后继续打开今日计划中的对练。'), findsOneWidget);
    expect(find.text('恢复会打开上次的练习；放弃后会继续打开今日计划中的对练。'), findsOneWidget);

    await t.tap(find.text('放弃创建请求'));
    await t.pumpAndSettle();

    expect(r.creates, hasLength(1));
    expect(r.creates.single['level_id'], target['id']);
    expect(find.text('情景预演'), findsOneWidget);
  });

  testWidgets('恢复旧目标取消授权时保留放弃并继续的说明', (t) async {
    final r = TargetPractice();
    await r.remember('creating', {
      'input': {
        'scenario': '无关的旧草稿',
        'scene': 'work',
        'request_id': 'restore-cancel',
      },
    });
    final target = (await r.levels(Scene.social, null)).last;

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          repo: r,
          scene: SceneMemory(),
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pumpAndSettle();
    const hint = '恢复会打开上次的练习；放弃后会继续打开今日计划中的对练。';
    expect(find.text(hint), findsOneWidget);

    await t.tap(find.text('恢复上次创建'));
    await t.pumpAndSettle();
    expect(find.text('开始前，先了解记录方式'), findsOneWidget);
    await t.tap(find.text('暂不开始'));
    await t.pumpAndSettle();

    expect(find.text(hint), findsOneWidget);
    expect(find.text('放弃创建请求'), findsOneWidget);
    expect(r.creates, isEmpty);
  });

  testWidgets('正式大厅放弃写后抛错时零续开并保留可重试状态', (t) async {
    final r = AbandonWriteThenThrowTarget();
    await r.remember('creating', {
      'input': {
        'scenario': '无关的旧草稿',
        'scene': 'work',
        'request_id': 'write-then-throw',
      },
    });
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    await t.pumpAndSettle();
    expect(find.text('放弃创建请求'), findsOneWidget);

    await t.tap(find.text('放弃创建请求'));
    await t.pumpAndSettle();

    expect(r.removals, 1);
    expect(r.creates, isEmpty);
    expect(find.text('未能确认上次创建请求已放弃，请重试。'), findsOneWidget);
    expect(find.text('重试放弃并继续'), findsOneWidget);
    expect(find.text('情景预演'), findsNothing);

    await t.tap(find.text('重试放弃并继续'));
    await t.pumpAndSettle();

    expect(r.removals, greaterThanOrEqualTo(2));
    expect(r.creates, hasLength(1));
    expect(r.creates.single['level_id'], target['id']);
    expect(find.text('情景预演'), findsOneWidget);
  });

  testWidgets('正式大厅删除后连续读取失败时零续开且重试后只开一次', (t) async {
    final r = AbandonReadFailureTarget();
    await r.remember('creating', {
      'input': {
        'scenario': '无关的旧草稿',
        'scene': 'work',
        'request_id': 'read-failure',
      },
    });
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    await t.pumpAndSettle();

    await t.tap(find.text('放弃创建请求'));
    await t.pumpAndSettle();
    expect(r.verificationReads, 1);
    expect(r.creates, isEmpty);
    expect(find.text('未能确认上次创建请求已放弃，请重试。'), findsOneWidget);
    expect(find.text('重试放弃并继续'), findsOneWidget);
    expect(find.text('情景预演'), findsNothing);

    await t.tap(find.text('重试放弃并继续'));
    await t.pumpAndSettle();
    expect(r.verificationReads, 2);
    expect(r.creates, isEmpty);
    expect(find.text('未能确认上次创建请求已放弃，请重试。'), findsOneWidget);
    expect(find.text('重试放弃并继续'), findsOneWidget);

    await t.tap(find.text('重试放弃并继续'));
    await t.pumpAndSettle();
    expect(r.verificationReads, greaterThanOrEqualTo(3));
    expect(r.creates, hasLength(1));
    expect(find.text('情景预演'), findsOneWidget);
  });

  testWidgets('正式大厅目标查询未完成时不提前放弃旧请求', (t) async {
    final r = QueryRaceTarget();
    await r.remember('creating', {
      'input': {
        'scenario': '无关的旧草稿',
        'scene': 'work',
        'request_id': 'query-race',
      },
    });
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    await t.pump();
    await t.pump();
    expect(r.findCalls, 1);
    final abandon = t.widget<TextButton>(
      find.widgetWithText(TextButton, '放弃创建请求'),
    );
    expect(abandon.onPressed, isNull);
    expect(r.creates, isEmpty);

    r.firstFind.complete(target);
    await t.pumpAndSettle();
    expect(find.text('先恢复上次创建，或放弃后继续打开今日计划中的对练。'), findsOneWidget);
    expect(find.text('恢复会打开上次的练习；放弃后会继续打开今日计划中的对练。'), findsOneWidget);

    await t.tap(find.text('放弃创建请求'));
    await t.pumpAndSettle();
    expect(r.findCalls, 2);
    expect(r.creates, hasLength(1));
    expect(r.creates.single['level_id'], target['id']);
    expect(find.text('情景预演'), findsOneWidget);
  });

  testWidgets('正式大厅放弃双击只删除一次且只续开一次', (t) async {
    final r = GatedAbandonTarget();
    await r.remember('creating', {
      'input': {
        'scenario': '无关的旧草稿',
        'scene': 'work',
        'request_id': 'double-click',
      },
    });
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    await t.pumpAndSettle();
    await t.tap(find.text('放弃创建请求'));
    await t.tap(find.text('放弃创建请求'));
    await t.pump();
    expect(r.removeStarted.isCompleted, isTrue);
    expect(r.removals, 1);

    r.removeGate.complete();
    await t.pumpAndSettle();
    expect(r.creates, hasLength(1));
    expect(find.text('情景预演'), findsOneWidget);
  });

  testWidgets('正式返回退场后迟到的放弃确认不再续开目标', (t) async {
    final r = GatedAbandonTarget();
    await r.remember('creating', {
      'input': {
        'scenario': '无关的旧草稿',
        'scene': 'work',
        'request_id': 'abandon-route-exit',
      },
    });
    final target = (await r.levels(Scene.social, null)).last;

    await openTrainingRoute(t, r, target['id'] as String);
    await t.pumpAndSettle();
    await t.tap(find.text('放弃创建请求'));
    await t.pump();
    expect(r.removeStarted.isCompleted, isTrue);

    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    r.removeGate.complete();
    await t.pumpAndSettle();

    expect(r.creates, isEmpty);
    expect(find.text('情景预演'), findsNothing);
  });

  testWidgets('正式大厅换号后迟到的放弃确认不清除或续开新账号', (t) async {
    final scene = SceneMemory();
    final target = (await TargetPractice().levels(Scene.social, null)).last;
    final oldAccount = GatedAbandonTarget();
    await oldAccount.remember('creating', {
      'input': {
        'scenario': 'A 账号旧草稿',
        'scene': 'work',
        'request_id': 'account-a-pending',
      },
    });

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: oldAccount,
          scene: scene,
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('放弃创建请求'));
    await t.pump();
    expect(oldAccount.removeStarted.isCompleted, isTrue);

    final nextAccount = TargetPractice();
    await nextAccount.remember('creating', {
      'input': {
        'scenario': 'B 账号旧草稿',
        'scene': 'work',
        'request_id': 'account-b-pending',
      },
    });
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: nextAccount, scene: scene),
      ),
    );
    await t.pumpAndSettle();

    oldAccount.removeGate.complete();
    await t.pumpAndSettle();

    expect(oldAccount.creates, isEmpty);
    expect(nextAccount.creates, isEmpty);
    expect(await nextAccount.read('creating'), isNotNull);
    expect(find.text('情景预演'), findsNothing);
    expect(
      t.widget<TextButton>(find.widgetWithText(TextButton, '放弃创建请求')).onPressed,
      isNotNull,
    );
  });

  testWidgets('正式路由恢复不在当前大厅列表中的计划目标且只建一次会话', (t) async {
    final r = FlakyTarget();
    final target = (await r.levels(Scene.social, null)).last;
    r.retryGate = Completer<Json?>();

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          practiceRepositoryProvider.overrideWithValue(r),
          contactSpaceProvider.overrideWithValue((
            scene: SceneMemory(),
            repo: null,
            demo: true,
          )),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.pushNamed(
                    context,
                    '/training',
                    arguments: target['id'],
                  ),
                  child: const Text('打开今日计划'),
                ),
              ),
            ),
          ),
          routes: {'/training': (_) => const PracticeRoute()},
        ),
      ),
    );
    await t.tap(find.text('打开今日计划'));
    await t.pumpAndSettle();

    expect(find.text('重试打开计划中的对练'), findsOneWidget);
    expect(r.creates, isEmpty);
    await t.tap(find.text('重试打开计划中的对练'));
    await t.pump();
    expect(r.findCalls, 2);

    final gate = r.retryGate;
    expect(gate, isNotNull);
    gate!.complete(target);
    await t.pumpAndSettle();

    expect(r.creates, hasLength(1));
    expect(r.creates.single['level_id'], target['id']);
    expect(find.text('情景预演'), findsOneWidget);
  });

  testWidgets('正式路由同账号重建不会重置计划目标重试状态', (t) async {
    final r = FlakyTarget();
    final target = (await r.levels(Scene.social, null)).last;
    final scene = SceneMemory();
    final refreshTick = NotifierProvider<RefreshTick, int>(RefreshTick.new);
    final container = ProviderContainer(
      overrides: [
        practiceRepositoryProvider.overrideWithValue(r),
        contactSpaceProvider.overrideWith((ref) {
          ref.watch(refreshTick);
          return (scene: scene, repo: null, demo: true);
        }),
      ],
    );
    addTearDown(container.dispose);

    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => Navigator.pushNamed(
                    context,
                    '/training',
                    arguments: target['id'],
                  ),
                  child: const Text('打开今日计划'),
                ),
              ),
            ),
          ),
          routes: {'/training': (_) => const PracticeRoute()},
        ),
      ),
    );
    await t.tap(find.text('打开今日计划'));
    await t.pumpAndSettle();

    expect(r.findCalls, 1);
    expect(find.text('重试打开计划中的对练'), findsOneWidget);

    container.read(refreshTick.notifier).bump();
    await t.pumpAndSettle();

    expect(r.findCalls, 1);
    expect(r.creates, isEmpty);
    expect(find.text('重试打开计划中的对练'), findsOneWidget);
  });

  testWidgets('计划目标删除、鉴权或额度拒绝时不提供原地重试', (t) async {
    for (final failure in [
      const ApiFailure(401, 'unauthenticated', '请重新登录', false),
      const ApiFailure(429, 'quota_exceeded', '额度不足', false),
      const ApiFailure(429, 'quota_exceeded', '额度不足', true),
    ]) {
      final r = FailingTarget(failure);
      await t.pumpWidget(
        MaterialApp(
          home: PracticeLobby(
            demo: true,
            repo: r,
            scene: SceneMemory(),
            targetLevelId: 'protected-level',
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(r.findCalls, 1);
      expect(r.creates, isEmpty);
      expect(
        find.text(
          failure.status == 429 ? '今日对练剩余 0 次，请在额度重置后再试。' : failure.message,
        ),
        findsOneWidget,
      );
      expect(find.text('重试打开计划中的对练'), findsNothing);
      expect(
        find.text('查看额度与重置时间'),
        failure.status == 429 ? findsOneWidget : findsNothing,
      );
    }

    final missing = TargetPractice();
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: missing,
          scene: SceneMemory(),
          targetLevelId: 'deleted-level',
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(missing.creates, isEmpty);
    expect(find.text('这项计划中的对练已删除或不可用，请返回今日计划重新选择。'), findsOneWidget);
    expect(find.text('重试打开计划中的对练'), findsNothing);
  });

  testWidgets('计划目标在授权说明处取消后不再查询或创建', (t) async {
    final r = TargetPractice();
    final target = (await r.levels(Scene.family, null)).last;

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          repo: r,
          scene: SceneMemory(),
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('开始前，先了解记录方式'), findsOneWidget);
    await t.tap(find.text('暂不开始'));
    await t.pumpAndSettle();

    expect(r.creates, isEmpty);
    expect(find.text('重试打开计划中的对练'), findsNothing);
  });

  testWidgets('计划目标查询未返回时换账号或退页不会打开旧目标', (t) async {
    final scene = SceneMemory();
    final target = (await TargetPractice().levels(Scene.social, null)).last;
    final oldAccount = GatedTarget();
    final nextAccount = TargetPractice();

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: oldAccount,
          scene: scene,
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pump();
    await t.pump();
    expect(oldAccount.findCalls, 1);

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(demo: true, repo: nextAccount, scene: scene),
      ),
    );
    await t.pumpAndSettle();
    oldAccount.gate.complete(target);
    await t.pumpAndSettle();
    expect(oldAccount.creates, isEmpty);
    expect(nextAccount.creates, isEmpty);

    final pageExit = GatedTarget();
    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: pageExit,
          scene: scene,
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pump();
    await t.pump();
    expect(pageExit.findCalls, 1);
    await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await t.pump();
    pageExit.gate.complete(target);
    await t.pumpAndSettle();
    expect(pageExit.creates, isEmpty);
  });

  testWidgets('计划目标创建回执丢失后复用同一请求且不重复建会话', (t) async {
    final r = TargetPractice()..loseFirst = true;
    final target = (await r.levels(Scene.friends, null)).last;

    await t.pumpWidget(
      MaterialApp(
        home: PracticeLobby(
          demo: true,
          repo: r,
          scene: SceneMemory(),
          targetLevelId: target['id'] as String,
        ),
      ),
    );
    await t.pumpAndSettle();

    expect(r.creates, hasLength(1));
    expect(find.text('恢复上次创建'), findsOneWidget);
    await t.tap(find.text('恢复上次创建'));
    await t.pumpAndSettle();

    expect(r.creates, hasLength(2));
    expect(r.creates[0], r.creates[1]);
    expect(r.creates.last['level_id'], target['id']);
    expect(find.text('情景预演'), findsOneWidget);
  });
}
