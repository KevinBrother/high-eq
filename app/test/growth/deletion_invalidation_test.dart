import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/growth/cache.dart';
import 'package:high_eq/features/growth/growth_page.dart';
import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/repository.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import 'support/fakes.dart';

class _SwitchableSecret extends MemorySecret {
  bool rejectWrites = false;

  @override
  Future<void> replace(String? next) async {
    if (rejectWrites) {
      throw const FileSystemException('安全存储拒写');
    }
    await super.replace(next);
  }
}

void main() {
  test('连续删除各自阻止旧快照，晚到回执不能确认另一次删除', () async {
    final root = await Directory.systemTemp.createTemp('t27-sequential-');
    addTearDown(() => root.delete(recursive: true));
    final sessions = Sessions(
      MemorySecret(),
      Directory('${root.path}/cache'),
      growthDeletionDirectory: Directory('${root.path}/fences'),
    );
    final scope = await sessions.activate(tokens('A'));
    final cache = GrowthCache(sessions, scope);
    addTearDown(cache.dispose);

    final previous = await cache.prepareDeletion('previous');
    expect(await cache.resolveDeletion(previous), isTrue);
    final first = await cache.prepareDeletion('first');
    expect(await cache.resolveDeletion(first), isTrue);
    final second = await cache.prepareDeletion('second');
    final third = await cache.prepareDeletion('third');
    final beforeConfirmation = cache.invalidationRevision;
    expect(await cache.resolveDeletion(first), isFalse);
    expect(await cache.pendingDeletions(), [second, third]);
    expect(cache.invalidationRevision, beforeConfirmation);
    expect(await cache.resolveDeletion(third), isTrue);
    expect(await cache.pendingDeletions(), [second]);

    Future<bool> publish(int revision) => cache.writeIfCurrent(
      cache.generation,
      [1, 2, 3],
      invalidationRevision: revision,
    );

    expect(await publish(cache.invalidationRevision), isFalse);
    expect(await cache.read(), isNull);
    final retry = await cache.prepareDeletion('second', retry: second);
    expect(await cache.resolveDeletion(second), isFalse);
    expect(await cache.pendingDeletions(), [retry]);
    final beforeRetryResult = cache.invalidationRevision;
    expect(await cache.resolveDeletion(retry), isTrue);
    expect(await publish(beforeRetryResult), isFalse);
    expect(await publish(cache.invalidationRevision), isTrue);
    expect(await cache.read(), [1, 2, 3]);
  });

  test('同账号重新登录重新加载未定删除，换号不继承且旧句柄失效', () async {
    final root = await Directory.systemTemp.createTemp('t27-relogin-');
    addTearDown(() => root.delete(recursive: true));
    final sessions = Sessions(
      MemorySecret(),
      Directory('${root.path}/cache'),
      growthDeletionDirectory: Directory('${root.path}/fences'),
    );
    final a = GrowthCache(sessions, await sessions.activate(tokens('A')));
    final operation = await a.prepareDeletion('contact-a');
    await sessions.clear();
    final b = GrowthCache(sessions, await sessions.activate(tokens('B')));
    expect(await b.pendingDeletions(), isEmpty);
    expect(await b.resolveDeletion(operation), isFalse);
    await b.write([2]);
    expect(await b.read(), [2]);
    final newA = GrowthCache(sessions, await sessions.activate(tokens('A')));
    expect(await newA.pendingDeletions(), [operation]);
    await expectLater(
      a.resolveDeletion(operation),
      throwsA(isA<SessionChanged>()),
    );
    expect(await newA.read(), isNull);
    await expectLater(newA.write([1]), throwsA(isA<GrowthCacheInvalidated>()));
    a.dispose();
    b.dispose();
    newA.dispose();
  });

  test('确认删除后安全存储拒写且密文删除失败，新 Sessions 仍拒绝旧快照', () async {
    final root = await Directory.systemTemp.createTemp(
      't27-growth-deletion-fence-',
    );
    addTearDown(() => root.delete(recursive: true));
    final cacheDir = Directory('${root.path}/cache');
    final deletionDir = Directory('${root.path}/support/growth-deletion');
    final secret = _SwitchableSecret();
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final wire = Handler()
      ..handle = (op, _) async => response(fixtures[op.name] as Map);
    final sessions = Sessions(
      secret,
      cacheDir,
      growthDeletionDirectory: deletionDir,
      deleteCache: (_) async => throw const FileSystemException('权限不足'),
    );
    final scope = await sessions.activate(tokens('A'));
    final repository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, sessions),
      scope,
    );
    await repository.saveCache(sampleSnapshot());
    final cache = GrowthCache(sessions, scope);
    addTearDown(cache.dispose);

    final operation = await cache.prepareDeletion('contact');
    secret.rejectWrites = true;
    await expectLater(
      cache.resolveDeletion(operation),
      throwsA(isA<FileSystemException>()),
    );

    expect(await repository.cached(), isNull);
    expect(cacheDir.listSync().whereType<File>(), isNotEmpty);

    final restarted = Sessions(
      secret,
      cacheDir,
      growthDeletionDirectory: deletionDir,
      deleteCache: (_) async => throw const FileSystemException('权限不足'),
    );
    await restarted.restore();
    final restartedScope = restarted.active!;
    final restartedRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, restarted),
      restartedScope,
    );

    expect(await restartedRepository.cached(), isNull);
    secret.rejectWrites = false;
    await restartedRepository.load();
    expect(await restartedRepository.cached(), isNotNull);
  });

  test('pending 删除围栏不能被普通在线读回提前解除', () async {
    final root = await Directory.systemTemp.createTemp(
      't27-growth-pending-fence-',
    );
    addTearDown(() => root.delete(recursive: true));
    final cacheDir = Directory('${root.path}/cache');
    final deletionDir = Directory('${root.path}/support/growth-deletion');
    final secret = MemorySecret();
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final wire = Handler()
      ..handle = (op, _) async => response(fixtures[op.name] as Map);
    final sessions = Sessions(
      secret,
      cacheDir,
      growthDeletionDirectory: deletionDir,
    );
    final scope = await sessions.activate(tokens('A'));
    final repository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, sessions),
      scope,
    );
    await repository.saveCache(sampleSnapshot());
    final cache = GrowthCache(sessions, scope);
    addTearDown(cache.dispose);

    await cache.prepareDeletion('contact');
    await repository.load();
    expect(await repository.cached(), isNull);

    final restarted = Sessions(
      secret,
      cacheDir,
      growthDeletionDirectory: deletionDir,
    );
    await restarted.restore();
    final restartedScope = restarted.active!;
    final restartedRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, restarted),
      restartedScope,
    );
    await restartedRepository.load();
    expect(await restartedRepository.cached(), isNull);
  });

  test('A 的删除围栏不影响 B 在冷启动读取自己的快照', () async {
    final root = await Directory.systemTemp.createTemp('t27-growth-ab-fence-');
    addTearDown(() => root.delete(recursive: true));
    final deletionDir = Directory('${root.path}/support/growth-deletion');
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final wire = Handler()
      ..handle = (op, _) async => response(fixtures[op.name] as Map);

    final aSecret = MemorySecret();
    final aSessions = Sessions(
      aSecret,
      Directory('${root.path}/a'),
      growthDeletionDirectory: deletionDir,
    );
    final a = await aSessions.activate(tokens('A'));
    final aRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, aSessions),
      a,
    );
    await aRepository.saveCache(sampleSnapshot());
    final aCache = GrowthCache(aSessions, a);
    addTearDown(aCache.dispose);
    await aCache.prepareDeletion('contact-a');

    final bSecret = MemorySecret();
    final bCacheDir = Directory('${root.path}/b');
    final bSessions = Sessions(
      bSecret,
      bCacheDir,
      growthDeletionDirectory: deletionDir,
    );
    final b = await bSessions.activate(tokens('B'));
    final bRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, bSessions),
      b,
    );
    await bRepository.saveCache(sampleSnapshot(planTitle: 'B 的快照'));

    final restartedB = Sessions(
      bSecret,
      bCacheDir,
      growthDeletionDirectory: deletionDir,
    );
    await restartedB.restore();
    final restartedBScope = restartedB.active!;
    final restartedBRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, restartedB),
      restartedBScope,
    );

    expect(await restartedBRepository.cached(), isNotNull);
    expect(aSessions.growthCacheInvalidated(a), isTrue);
  });

  test('删除回报不存在但密文仍可读时必须报告清理失败', () async {
    final root = await Directory.systemTemp.createTemp(
      't27-growth-false-absent-',
    );
    addTearDown(() => root.delete(recursive: true));
    final cacheDir = Directory('${root.path}/cache');
    final deletionDir = Directory('${root.path}/support/growth-deletion');
    final sessions = Sessions(
      MemorySecret(),
      cacheDir,
      growthDeletionDirectory: deletionDir,
      deleteCache: (_) async =>
          throw const PathNotFoundException('stale', OSError('missing')),
    );
    final scope = await sessions.activate(tokens('A'));
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final wire = Handler()
      ..handle = (op, _) async => response(fixtures[op.name] as Map);
    final repository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, sessions),
      scope,
    );
    await repository.saveCache(sampleSnapshot());
    final cache = GrowthCache(sessions, scope);
    addTearDown(cache.dispose);

    final operation = await cache.prepareDeletion('contact');
    await expectLater(
      cache.resolveDeletion(operation),
      throwsA(isA<PathNotFoundException>()),
    );

    expect(cacheDir.listSync().whereType<File>(), isNotEmpty);
    expect(await repository.cached(), isNull);
  });

  test('删除清理失败后，跨 Sessions 仍拒绝旧快照且新在线快照可恢复缓存', () async {
    final dir = await Directory.systemTemp.createTemp(
      't27-growth-invalidation-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final secret = MemorySecret();
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final wire = Handler()
      ..handle = (op, _) async => response(fixtures[op.name] as Map);
    final firstSessions = Sessions(
      secret,
      dir,
      deleteCache: (_) async => throw const FileSystemException('权限不足'),
    );
    final firstScope = await firstSessions.activate(tokens('A'));
    final firstRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, firstSessions),
      firstScope,
    );
    await firstRepository.saveCache(sampleSnapshot());

    await expectLater(
      firstRepository.clearCache(),
      throwsA(isA<FileSystemException>()),
    );
    expect(dir.listSync().whereType<File>(), isNotEmpty);
    expect(firstSessions.growthCacheInvalidated(firstScope), isTrue);
    expect(await firstRepository.cached(), isNull);
    await expectLater(
      firstRepository.saveCache(sampleSnapshot()),
      throwsA(isA<GrowthCacheInvalidated>()),
    );

    final sameSessionRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, firstSessions),
      firstScope,
    );
    expect(await sameSessionRepository.cached(), isNull);
    await expectLater(
      sameSessionRepository.saveCache(sampleSnapshot()),
      throwsA(isA<GrowthCacheInvalidated>()),
    );

    final restarted = Sessions(secret, dir);
    await restarted.restore();
    final restartedScope = restarted.active!;
    final restartedRepository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, restarted),
      restartedScope,
    );

    expect(restarted.growthCacheInvalidated(restartedScope), isTrue);
    expect(await restartedRepository.cached(), isNull);
    await expectLater(
      restartedRepository.saveCache(sampleSnapshot()),
      throwsA(isA<GrowthCacheInvalidated>()),
    );

    await restartedRepository.load();
    expect(restarted.growthCacheInvalidated(restartedScope), isFalse);
    expect(await restartedRepository.cached(), isNotNull);
  });

  test('清理通知发出时 revision 已更新，通知触发的在线快照仍能恢复缓存', () async {
    final dir = await Directory.systemTemp.createTemp(
      't27-growth-notification-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final secret = MemorySecret();
    final fixtures =
        jsonDecode(await File('assets/contract_examples.json').readAsString())
            as Map<String, dynamic>;
    final wire = Handler()
      ..handle = (op, _) async => response(fixtures[op.name] as Map);
    final sessions = Sessions(
      secret,
      dir,
      deleteCache: (_) async => throw const FileSystemException('权限不足'),
    );
    final scope = await sessions.activate(tokens('A'));
    final cache = GrowthCache(sessions, scope);
    addTearDown(cache.dispose);
    final repository = ApiGrowthRepository(
      AppApi(Uri.https('test.invalid'), wire, sessions),
      scope,
      cache: cache,
    );
    await repository.saveCache(sampleSnapshot());

    int? notifiedRevision;
    cache.invalidations.addListener(() {
      notifiedRevision = cache.invalidationRevision;
    });
    final clearing = cache.clear();
    final clearFailure = expectLater(
      clearing,
      throwsA(isA<FileSystemException>()),
    );

    expect(notifiedRevision, sessions.growthCacheRevision(scope));
    final online = repository.load();
    expect((await online).plan.day, '2026-11-21');
    await clearFailure;

    expect((await repository.cached())?.plan.day, '2026-11-21');
    final restarted = Sessions(secret, dir);
    await restarted.restore();
    final restartedScope = restarted.active!;
    expect(restarted.growthCacheInvalidated(restartedScope), isFalse);
    expect(
      await ApiGrowthRepository(
        AppApi(Uri.https('test.invalid'), wire, restarted),
        restartedScope,
      ).cached(),
      isNotNull,
    );
  });

  testWidgets('401/403 清理触发的失效通知保留授权错误且不连锁重载', (tester) async {
    for (final status in [401, 403]) {
      for (final app in <Widget Function(GrowthRepository)>[
        _growthApp,
        _practiceApp,
      ]) {
        final repository = _AuthClearingGrowthRepository(status);
        await tester.pumpWidget(app(repository));
        await tester.pumpAndSettle();

        expect(
          find.text(status == 401 ? '登录凭证无效或已过期，请重新验证。' : '没有获得所需授权，请重新确认。'),
          findsOneWidget,
        );
        expect(find.text('暂时无法加载，请检查连接后重试。'), findsNothing);
        expect(repository.clearCacheCalls, 1);
        expect(repository.loadCalls, 1);
      }
    }
  });

  testWidgets('删除通知到达后，保留的成长页收到 503 不再显示内存旧分', (tester) async {
    final repository = _InvalidatingGrowthRepository(
      snapshot: sampleSnapshot(),
    );
    await tester.pumpWidget(_growthApp(repository));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.text('74 / 100'));

    repository
      ..loadError = StateError('offline')
      ..cachedSnapshot = null;
    repository.invalidate();

    await tester.pumpAndSettle();

    expect(find.text('74 / 100'), findsNothing);
    expect(find.text('20 / 25'), findsNothing);
    expect(find.text('暂时无法加载，请检查连接后重试。'), findsOneWidget);
  });

  testWidgets('删除通知到达后，保留的练习页不再用旧快照完成打卡写缓存', (tester) async {
    final repository = _DeletingOnCompleteRepository(
      snapshot: sampleSnapshot(),
    );
    await tester.pumpWidget(_practiceApp(repository));
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('知识卡 · 事实和评价要分开'));
    await tester.tap(find.text('知识卡 · 事实和评价要分开'));
    await tester.pumpAndSettle();
    repository
      ..loadError = StateError('offline')
      ..cachedSnapshot = null;
    await tester.tap(find.text('读完了，记为完成'));
    await tester.pumpAndSettle();

    expect(repository.saveCalls, 0);
    expect(repository.savedSnapshot, isNull);
    expect(find.text('74 / 100'), findsNothing);
  });
}

class _InvalidatingGrowthRepository extends FakeGrowthRepository
    implements GrowthInvalidationSource {
  _InvalidatingGrowthRepository({required super.snapshot});

  final _revision = ValueNotifier<int>(0);

  @override
  ValueListenable<int> get invalidations => _revision;

  void invalidate() => _revision.value++;
}

class _DeletingOnCompleteRepository extends _InvalidatingGrowthRepository {
  _DeletingOnCompleteRepository({required super.snapshot});

  @override
  Future<CompletionData> complete(String itemId) async {
    final completion = await super.complete(itemId);
    invalidate();
    return completion;
  }
}

class _AuthClearingGrowthRepository extends _InvalidatingGrowthRepository {
  _AuthClearingGrowthRepository(this.status)
    : super(snapshot: sampleSnapshot()) {
    loadError = ApiFailure(status, 'denied', '拒绝访问', false);
  }

  final int status;

  @override
  Future<void> clearCache() async {
    clearCacheCalls++;
    invalidate();
    throw StateError('缓存清理失败');
  }
}

Widget _growthApp(GrowthRepository repository) => MaterialApp(
  home: Scaffold(body: GrowthPage(repository: repository)),
);

Widget _practiceApp(GrowthRepository repository) => MaterialApp(
  home: Scaffold(body: PracticeHomePage(repository: repository)),
);

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    320,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 30,
  );
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}
