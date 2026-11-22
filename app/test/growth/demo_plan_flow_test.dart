import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/growth/demo.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/practice/demo.dart';
import 'package:high_eq/features/practice/lobby.dart';
import 'package:high_eq/features/practice/providers.dart';

import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  testWidgets('默认演示计划关卡可完成评分并回写今日计划', (tester) async {
    final directory = await tester.runAsync(
      () => Directory.systemTemp.createTemp('t27-demo-plan-'),
    );
    addTearDown(() => directory!.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), directory!);
    await tester.runAsync(() => sessions.activate(tokens('demo-plan')));

    final api = AppApi(
      Uri.https('example.invalid'),
      ExampleTransport(),
      sessions,
    );
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWith((_) async => api)],
    );
    addTearDown(container.dispose);
    await container.read(apiProvider.future);

    final growth = container.read(growthRepositoryProvider);
    final practice = container.read(demoPracticeProvider);
    expect(growth, isA<DemoGrowthRepository>());
    expect(practice, isA<DemoPractice>());
    expect((growth as DemoGrowthRepository).practice, same(practice));

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: HomeShell(
            Section.practice,
            content: PracticeHomePage(repository: growth),
          ),
          routes: {'/training': (_) => const PracticeRoute()},
        ),
      ),
    );
    await tester.pumpAndSettle();

    const planTitle = '对练 · 把拒绝说得清楚又不伤人';
    await _scrollTo(tester, find.text(planTitle));
    await tester.tap(find.text(planTitle));
    await tester.pumpAndSettle();

    expect(find.text('这项计划中的对练已删除或不可用，请返回今日计划重新选择。'), findsNothing);
    expect(find.text('情景预演'), findsOneWidget);
    expect(find.text('你的发言'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '我想和你商量一个双方都能接受的时间。');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('结束并评分'), findsOneWidget);

    await tester.tap(find.text('结束并评分'));
    await tester.pumpAndSettle();
    expect(find.text('整场反馈'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await _scrollTo(tester, find.text('对练关卡 · 已完成'));
    expect(find.text('对练关卡 · 已完成'), findsOneWidget);
    expect(find.text('1 / 3 已完成'), findsOneWidget);
  });
}

Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    320,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 30,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}
