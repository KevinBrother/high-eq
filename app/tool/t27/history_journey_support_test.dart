import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/session.dart';

import 'history_journey_support.dart';

void main() {
  test(
    'journey storage keeps account deletion ownership across Sessions',
    () async {
      final root = await Directory.systemTemp.createTemp(
        't27-journey-storage-',
      );
      addTearDown(() => root.delete(recursive: true));
      final storage = JourneyStorage(root);

      final first = storage.open();
      final a = await first.activate(_tokens('A'));
      await first.prepareGrowthDeletion(a, contactId: 'contact-a');

      final reopenedA = storage.open();
      await reopenedA.restore();
      final restoredA = reopenedA.active!;
      expect(restoredA.account, a.account);
      expect(reopenedA.growthCacheInvalidated(restoredA), isTrue);

      final b = await reopenedA.activate(_tokens('B'));
      expect(reopenedA.growthCacheInvalidated(b), isFalse);
      final revision = reopenedA.growthCacheRevision(b);
      expect(
        await reopenedA.putGrowthCache(
          b,
          'growth.snapshot.v1',
          [7, 8, 9],
          revision: revision,
          recoverInvalidated: false,
        ),
        isTrue,
      );

      final reopenedB = storage.open();
      await reopenedB.restore();
      final restoredB = reopenedB.active!;
      expect(restoredB.account, b.account);
      expect(reopenedB.growthCacheInvalidated(restoredB), isFalse);
      expect(await reopenedB.getGrowthCache(restoredB, 'growth.snapshot.v1'), [
        7,
        8,
        9,
      ]);
    },
  );

  testWidgets('gestures resolve the current route during replacement', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final taps = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: _ProbePage(
          label: 'outgoing route',
          onTab: () => taps.add('outgoing'),
        ),
      ),
    );

    navigator.currentState!.pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(seconds: 1),
        pageBuilder: (_, _, _) => _ProbePage(
          label: 'incoming route',
          onTab: () => taps.add('incoming'),
        ),
      ),
    );
    final frames = JourneyFrames(tester);
    final target = find.text('仅当前路由可见');
    final tab = find.descendant(
      of: find.byType(NavigationBar),
      matching: find.text('我的'),
    );
    await frames.until(
      () => target.evaluate().length == 2 && tab.evaluate().length == 2,
      'both target and navigation copies during route replacement',
      limit: const Duration(seconds: 2),
    );
    expect(target, findsNWidgets(2));
    expect(tab, findsNWidgets(2));

    await frames.show(target, within: find.byType(_ProbePage));
    await frames.tap(tab);

    expect(taps, ['incoming']);
    expect(find.text('incoming route'), findsOneWidget);
  });

  testWidgets(
    'gestures ignore horizontal filters and editor scrollers beside history',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _LobbyLikeHistoryPage()));

      final frames = JourneyFrames(tester);
      final target = find.text('竖向历史目标');

      // Mirrors PracticeLobby: a page-level history ListView, a horizontal
      // filter list, and a multiline TextField with its own vertical Scrollable.
      expect(find.byType(Scrollable), findsAtLeastNWidgets(3));
      expect(target, findsNothing);

      await frames.show(target, within: find.byType(_LobbyLikeHistoryPage));

      expect(target, findsOneWidget);
      expect(target.hitTestable(), findsOneWidget);
    },
  );

  testWidgets('gestures reject two vertical history scrollables', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _AmbiguousHistoryPage()));

    final frames = JourneyFrames(tester);
    final target = find.text('嵌套历史目标');

    await expectLater(
      frames.show(target, within: find.byType(_AmbiguousHistoryPage)),
      throwsA(
        isA<TestFailure>().having(
          (error) => error.message,
          'message',
          contains('Ambiguous vertical history scrollable'),
        ),
      ),
    );
  });

  testWidgets('gestures reject duplicate matches on the current route', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: _DuplicatePage()));

    final frames = JourneyFrames(tester);
    final target = find.text('重复目标');
    final within = find.byType(_DuplicatePage);

    await expectLater(
      frames.show(target, within: within),
      throwsA(
        isA<TestFailure>().having(
          (error) => error.message,
          'message',
          contains('Ambiguous target'),
        ),
      ),
    );
    await expectLater(
      frames.tap(target),
      throwsA(
        isA<TestFailure>().having(
          (error) => error.message,
          'message',
          contains('Ambiguous control'),
        ),
      ),
    );
  });
}

Tokens _tokens(String account) => Tokens(
  account,
  'access',
  'refresh',
  DateTime.now().toUtc().add(const Duration(hours: 1)),
);

class _ProbePage extends StatelessWidget {
  const _ProbePage({required this.label, required this.onTab});

  final String label;
  final VoidCallback onTab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: [
            Text(label),
            const SizedBox(height: 1200),
            const Text('仅当前路由可见'),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: 0,
        onDestinationSelected: (_) => onTab(),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
          NavigationDestination(icon: Icon(Icons.spa_outlined), label: '成长'),
        ],
      ),
    );
  }
}

class _DuplicatePage extends StatelessWidget {
  const _DuplicatePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SingleChildScrollView(
        child: Column(
          children: const [Text('重复目标'), SizedBox(height: 1200), Text('重复目标')],
        ),
      ),
    );
  }
}

class _LobbyLikeHistoryPage extends StatelessWidget {
  const _LobbyLikeHistoryPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          const Text('对练与预演'),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: const [
                Padding(padding: EdgeInsets.all(8), child: Text('全部难度')),
                Padding(padding: EdgeInsets.all(8), child: Text('难度 1')),
                Padding(padding: EdgeInsets.all(8), child: Text('难度 2')),
              ],
            ),
          ),
          const TextField(
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(labelText: '预演自己的情境'),
          ),
          const SizedBox(height: 1200),
          const Text('竖向历史目标'),
        ],
      ),
    );
  }
}

class _AmbiguousHistoryPage extends StatelessWidget {
  const _AmbiguousHistoryPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
        children: [
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: const [Text('横向筛选')],
            ),
          ),
          SizedBox(
            height: 240,
            child: ListView(
              children: const [
                Text('第一份纵向历史'),
                SizedBox(height: 600),
                Text('嵌套历史目标'),
              ],
            ),
          ),
          const SizedBox(height: 800),
          const Text('同一当前路由上的第二份纵向历史'),
        ],
      ),
    );
  }
}
