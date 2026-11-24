import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'history_journey_support.dart';

void main() {
  const contactId = 'synthetic-contact';
  final origin = Uri.parse('http://synthetic-origin.invalid');
  final path = '/v1/contacts/$contactId';

  for (final (description, body) in [
    ('invalid JSON', utf8.encode('synthetic-private-body')),
    ('non-object JSON', utf8.encode('["synthetic-private-body"]')),
    ('invalid UTF-8', [0xff, ...utf8.encode('synthetic-private-body')]),
  ]) {
    test(
      'target DELETE records 200 with $description and still fails',
      () async {
        final wire = JourneyWire(
          origin,
          contactId: contactId,
          client: MockClient.streaming(
            (_, _) async => http.StreamedResponse(Stream.value(body), 200),
          ),
        );
        addTearDown(wire.close);

        Object? failure;
        final lines = await _captureOutput(() async {
          try {
            await wire.send(
              AppOp.deleteContact,
              http.Request('DELETE', origin.resolve(path)),
            );
          } catch (error) {
            failure = error;
          }
        });

        expect(lines, ['OBSERVED(page.delete-http): unacknowledged']);
        expect(wire.deletions, [(path: path, status: 200, ok: false)]);
        expect(failure, isA<FormatException>());
        expect(failure.toString(), isNot(contains('synthetic-private-body')));
        expect(failure.toString(), isNot(contains(origin.toString())));
        expect(failure.toString(), isNot(contains(path)));
      },
    );
  }

  test(
    'target DELETE leaves no observation when no response arrives',
    () async {
      final failure = StateError('synthetic transport failure');
      final wire = JourneyWire(
        origin,
        contactId: contactId,
        client: MockClient.streaming((_, _) async => throw failure),
      );
      addTearDown(wire.close);

      final lines = await _captureOutput(() async {
        await expectLater(
          wire.send(
            AppOp.deleteContact,
            http.Request('DELETE', origin.resolve(path)),
          ),
          throwsA(same(failure)),
        );
      });

      expect(lines, isEmpty);
      expect(wire.deletions, isEmpty);
    },
  );

  test('target DELETE reports and forwards a valid acknowledgement', () async {
    const body = '{"ok":true}';
    final wire = JourneyWire(
      origin,
      contactId: contactId,
      client: MockClient.streaming(
        (_, _) async =>
            http.StreamedResponse(Stream.value(utf8.encode(body)), 200),
      ),
    );
    addTearDown(wire.close);

    final lines = await _captureOutput(() async {
      final response = await wire.send(
        AppOp.deleteContact,
        http.Request('DELETE', origin.resolve(path)),
      );
      expect(response.statusCode, 200);
      expect(await response.stream.bytesToString(), body);
    });

    expect(lines, [
      'OBSERVED(page.delete-ack): DELETE returned 200 with ok=true',
    ]);
    expect(wire.deletions, [(path: path, status: 200, ok: true)]);
  });

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

Future<List<String>> _captureOutput(Future<void> Function() action) async {
  final lines = <String>[];
  await runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, line) => lines.add(line),
    ),
  );
  return lines;
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
