import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/repository.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  test('登出后成长仓库立即失效，重新登录使用新作用域', () async {
    final directory = await Directory.systemTemp.createTemp(
      't27-growth-scope-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), directory);
    final a = await sessions.activate(tokens('A'));
    final wire = Handler()..handle = (_, _) async => response({});
    final api = AppApi(Uri.https('wire.invalid'), wire, sessions);
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(container.dispose);
    await container.read(apiProvider.future);

    final oldRepository =
        container.read(growthRepositoryProvider)! as ApiGrowthRepository;
    expect(oldRepository.scope, same(a));

    await sessions.clear();
    expect(container.read(growthRepositoryProvider), isNull);
    await expectLater(oldRepository.load(), throwsA(isA<SessionChanged>()));

    final b = await sessions.activate(tokens('B', 'access-b'));
    final newRepository =
        container.read(growthRepositoryProvider)! as ApiGrowthRepository;
    expect(newRepository.scope, same(b));
    expect(newRepository.scope, isNot(same(a)));
  });

  testWidgets('练习首页仍挂载时真实登出过渡帧安全渲染且不展示旧计划', (tester) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('t27-practice-transition-'),
    );
    addTearDown(() => directory!.delete(recursive: true));
    final sessions = _MemoryCacheSessions(MemorySecret(), directory!);
    await tester.runAsync(() => sessions.activate(tokens('A')));
    final fixtureText = await tester.runAsync(
      () => File('assets/contract_examples.json').readAsString(),
    );
    final fixtures = jsonDecode(fixtureText!) as Map<String, dynamic>;
    final wire = Handler()
      ..handle = (op, _) async => response(fixtures[op.name] as Map);
    final api = AppApi(Uri.https('example.invalid'), wire, sessions);
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(container.dispose);
    await container.read(apiProvider.future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PracticeHomeRoute()),
      ),
    );
    final planHeading = find.text('今日计划');
    final planItem = find.text('沟通练习');
    await _pumpUntilPlanLoaded(tester, planHeading, planItem);
    expect(planHeading, findsOneWidget);
    expect(planItem, findsOneWidget);

    await tester.runAsync(() => api.logout(sessions.active!));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(sessions.active, isNull);
    expect(find.byType(PracticeHomeRoute), findsOneWidget);
    expect(planHeading, findsNothing);
    expect(planItem, findsNothing);
    expect(find.text('正在重新载入练习首页…'), findsOneWidget);
  });
}

Future<void> _pumpUntilPlanLoaded(
  WidgetTester tester,
  Finder planHeading,
  Finder planItem,
) async {
  const maxFrames = 20;
  for (var frame = 0; frame < maxFrames; frame++) {
    // Let real async callbacks run as well as advancing widget frames. The
    // loading spinner can keep scheduling frames without making progress.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull, reason: '加载练习首页时抛出异常');
    if (planHeading.evaluate().isNotEmpty && planItem.evaluate().isNotEmpty) {
      return;
    }
  }
  fail(
    '练习首页在 $maxFrames 帧内未加载今日计划：'
    '标题=${planHeading.evaluate().length}，计划条目=${planItem.evaluate().length}，'
    '加载指示器=${find.byType(CircularProgressIndicator).evaluate().length}',
  );
}

class _MemoryCacheSessions extends Sessions {
  // The superclass constructor exposes private field-formal names.
  // ignore: use_super_parameters
  _MemoryCacheSessions(SecretStore secret, Directory directory)
    : super(secret, directory);

  final Map<String, List<int>> _cache = {};

  String _key(CacheKind kind, String id) => '${kind.name}:$id';

  @override
  Future<void> put(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) async {
    require(scope);
    _cache[_key(kind, id)] = List<int>.of(bytes);
    require(scope);
  }

  @override
  Future<List<int>?> get(AccountScope scope, CacheKind kind, String id) async {
    require(scope);
    return _cache[_key(kind, id)]?.toList();
  }

  @override
  Future<void> remove(AccountScope scope, CacheKind kind, String id) async {
    require(scope);
    _cache.remove(_key(kind, id));
  }
}
