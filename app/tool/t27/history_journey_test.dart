import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/contacts/workspace.dart';
import 'package:high_eq/features/growth/growth_page.dart';
import 'package:high_eq/features/growth/models.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/growth/widgets.dart';
import 'package:high_eq/features/health/binding.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/onboarding/repository.dart';
import 'package:high_eq/features/practice/lobby.dart';
import 'package:high_eq/main.dart';

import 'history_journey_support.dart';
import 'history_trace.dart';

const _single = '最近一次 · 单项练习 · 观察';
const _full = '更早一次 · 整场对练';
const _legacy = '完成时间未记录 · 整场对练';
const _offline = '当前显示这台设备上的离线数据，历史成就会保留。';
const _outage = '服务暂不可用，请稍后重试。';

void main() {
  testWidgets(
    'T27 formal growth history and contact deletion journey',
    (tester) async {
      final frames = JourneyFrames(tester);
      final growth = find.byType(GrowthPage);
      final home = find.byType(PracticeHomePage);
      final lobby = find.byType(PracticeLobby);
      final contacts = find.byType(ContactsWorkspace);
      final offline = find.descendant(
        of: growth,
        matching: find.text(_offline),
      );
      final unavailable = find.descendant(
        of: growth,
        matching: find.text(_outage),
      );

      String input(String name) {
        final value = Platform.environment['T27_HISTORY_$name'];
        if (value == null || value.isEmpty) {
          throw StateError('Missing T27_HISTORY_$name, use history_journey.py');
        }
        return value;
      }

      late final JourneyWire wire;
      late final AppApi api;
      late final AccountScope a;
      late final JourneyStorage storage;
      late final ProviderContainer container;
      late final String singleId, fullId, legacyId, contactId, before, after;

      Future<AccountScope> login(String ticket) async => api.sessions.activate(
        Tokens.fromJson(
          await MobileEndpoints(api).login(
            body: {
              'credential': {'provider': 'apple', 'proof': ticket},
              'age_confirmed': true,
              'privacy_version': policyVersion,
              'terms_version': policyVersion,
            },
          ),
        ),
      );

      Future<void> tab(String label) => frames.tap(
        find.descendant(
          of: find.byType(NavigationBar),
          matching: find.text(label),
        ),
      );

      Finder semantics(String label) => find.descendant(
        of: growth,
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == label,
        ),
      );

      Finder reference(String score) => semantics('训练参考分 $score 分，满分 100 分');

      Future<GrowthSnapshot?> cache() {
        final repo = container.read(growthRepositoryProvider);
        expect(repo, isA<ApiGrowthRepository>());
        return frames.real(
          repo!.cached,
          'encrypted cache of active growth provider',
        );
      }

      void checkCache(GrowthSnapshot? snapshot, {required bool linked}) {
        expect(snapshot, isNotNull);
        final scores = snapshot!.scoredSessions;
        expect(scores.map((s) => s.sessionId), [
          singleId,
          if (linked) fullId,
          legacyId,
        ]);
        expect(scores.map((s) => (s.total, s.maximum)), [
          (15, 25),
          if (linked) (100, 100),
          (60, 100),
        ]);
        expect(scores.first.completedAt, isNotNull);
        if (linked) {
          expect(
            scores.first.completedAt!.isAfter(scores[1].completedAt!),
            isTrue,
          );
        }
        expect(scores.last.completedAt, isNull);
        expect(
          snapshot.growth.trainingReference?.round().toString(),
          linked ? before : after,
        );
        expect(snapshot.growth.validBehaviorCount, linked ? 2 : 1);
      }

      Future<void> checkScores({required bool linked}) async {
        final single = find.text(_single);
        final full = find.text(_full);
        final legacy = find.text(_legacy);
        await frames.show(single, within: growth);
        expect(single, findsOneWidget);
        expect(find.text('15 / 25'), findsOneWidget);
        expect(legacy, findsOneWidget);
        expect(semantics('$_legacy，60 分，满分 100 分'), findsOneWidget);
        expect(semantics('$_single，15 分，满分 25 分'), findsOneWidget);
        expect(
          tester.getTopLeft(single).dy,
          lessThan(tester.getTopLeft(legacy).dy),
        );
        if (linked) {
          expect(full, findsOneWidget);
          expect(find.text('100 / 100'), findsOneWidget);
          expect(semantics('$_full，100 分，满分 100 分'), findsOneWidget);
          expect(
            tester.getTopLeft(single).dy,
            lessThan(tester.getTopLeft(full).dy),
          );
          expect(
            tester.getTopLeft(full).dy,
            lessThan(tester.getTopLeft(legacy).dy),
          );
        } else {
          expect(full, findsNothing);
          expect(find.text('100 / 100'), findsNothing);
        }
      }

      Future<void> enterGrowth() async {
        await tab('成长');
        await frames.appeared(growth, 'formal GrowthPage route');
      }

      Future<void> waitFor503(int mark) async {
        await frames.until(
          () => wire.readsAfter(mark).any((read) => read.status == 503),
          'injected listSessions 503 from the formal route',
        );
        expect(
          wire.readsAfter(mark).every((read) => read.status == 503),
          isTrue,
        );
      }

      await frames.phase('fixture', () async {
        final origin = Uri.parse(input('ORIGIN'));
        expect(origin.scheme, 'http');
        expect(origin.host, '127.0.0.1');
        expect(origin.hasPort, isTrue);
        expect(origin.userInfo, isEmpty);
        singleId = input('SINGLE');
        fullId = input('FULL');
        legacyId = input('LEGACY');
        contactId = input('CONTACT');
        before = input('REFERENCE_BEFORE');
        after = input('REFERENCE_AFTER');
        expect(before, isNot(after));
        tester.view.physicalSize = const Size(900, 1350);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await frames.real(() async {
          final state = await Directory.systemTemp.createTemp('t27-history-');
          addTearDown(() => state.deleteSync(recursive: true));
          wire = JourneyWire(origin);
          addTearDown(wire.close);
          storage = JourneyStorage(state);
          api = AppApi(origin, wire, storage.open());
          a = await login(input('TICKET_A'));
          expect(a.account, input('ACCOUNT_A'));
          container = ProviderContainer(
            overrides: [
              apiProvider.overrideWith((_) async => api),
              healthProvider.overrideWith((_, _) async => null),
            ],
          );
          addTearDown(container.dispose);
          await container.read(apiProvider.future);
        }, 'real login, Sessions and app provider initialization');
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const HighEqApp(),
          ),
        );
        // A already has a real assessment. The production startup routes home.
        await frames.appeared(home, 'practice home after assessment startup');
      });

      await frames.phase('lobby-order-and-back', () async {
        await frames.tap(find.text('对练与预演'));
        await frames.appeared(lobby, 'real practice lobby');
        final laterCreated = find.text('合成较晚创建整场');
        final earlierCreated = find.text('合成较早创建单项');
        await frames.show(laterCreated, within: lobby);
        expect(earlierCreated, findsOneWidget);
        expect(
          tester.getTopLeft(laterCreated).dy,
          lessThan(tester.getTopLeft(earlierCreated).dy),
        );
        await frames.backTo(home, lobby);
        expect(find.byType(NavigationBar), findsOneWidget);
      });

      await frames.phase('growth-history', () async {
        final mark = wire.mark();
        await enterGrowth();
        await frames.appeared(
          find.byType(RefreshIndicator),
          'loaded growth data',
        );
        await frames.show(reference(before), within: growth);
        await checkScores(linked: true);
        final reads = wire.readsAfter(mark);
        final receipt = wire.historyReceipt(mark);
        debugPrintSynchronously('OBSERVED(page.history-requests): $receipt');
        expect(
          hasHistoryChain(
            reads,
            firstCount: 100,
            firstIds: {fullId, legacyId},
            lastId: singleId,
          ),
          isTrue,
          reason: receipt,
        );
        checkCache(await cache(), linked: true);
      });

      await frames.phase('offline-without-deletion', () async {
        // Leaving GrowthPage ensures this case reads the encrypted cache on a
        // fresh route, with no in-memory page snapshot to fall back to.
        await tab('我的');
        await frames.until(
          () => growth.evaluate().isEmpty,
          'closed online growth route',
        );
        final mark = wire.mark();
        wire.historyUnavailable = true;
        await enterGrowth();
        await frames.appeared(offline, 'offline banner on a fresh route');
        await waitFor503(mark);
        await frames.show(reference(before), within: growth);
        await checkScores(linked: true);
        checkCache(await cache(), linked: true);
        // Keep the outage active until the delete confirmation so no successful
        // pre-delete reads can create a replacement snapshot.
      });

      await frames.phase('contact-deleted', () async {
        await tab('我的');
        final me = find.byWidgetPredicate(
          (w) => w is HomeShell && w.section == Section.me,
        );
        final entry = find.text('关系人手记');
        await frames.show(entry, within: me);
        await frames.tap(entry);
        await frames.appeared(contacts, 'real contacts workspace');
        final person = find.text('合成关系人');
        await frames.tap(person);
        final remove = find.text('删除关系人');
        await frames.show(remove, within: contacts);
        await frames.tap(remove);
        await frames.tap(find.text('确认删除'));
        await frames.appeared(
          find.text('关系人已删除。'),
          'successful delete and cache cleanup notice',
        );
        expect(wire.deletions, [
          (path: '/v1/contacts/$contactId', status: 200, ok: true),
        ]);
        debugPrintSynchronously(
          'OBSERVED(page.delete-ack): DELETE returned 200 with ok=true',
        );
        expect(person, findsNothing);
        await frames.backTo(me, contacts);
      });

      await frames.phase('deleted-cache', () async {
        final mark = wire.mark();
        await enterGrowth();
        await frames.until(() {
          expect(find.text('100 / 100'), findsNothing);
          expect(reference(before), findsNothing);
          return offline.evaluate().isNotEmpty ||
              unavailable.evaluate().isNotEmpty;
        }, 'offline fallback or explicit 503 retry');
        await waitFor503(mark);
        expect(find.text('100 / 100'), findsNothing);
        expect(reference(before), findsNothing);
        if (offline.evaluate().isNotEmpty) {
          // Inspect the lazy sections even if initially below the fold.
          final referenceSection = find.byWidgetPredicate(
            (w) => w is Text && ['训练参考分', '训练参考分 · 待解锁'].contains(w.data),
          );
          await frames.show(referenceSection, within: growth);
          expect(reference(before), findsNothing);
          if (find.text('训练参考分').evaluate().isNotEmpty) {
            expect(reference(after), findsOneWidget);
          }
          final historyHeading = find.descendant(
            of: growth,
            matching: find.text('历次对练得分'),
          );
          await frames.show(historyHeading, within: growth);
          expect(find.text(_full), findsNothing);
          expect(find.text('100 / 100'), findsNothing);
        } else {
          expect(find.byType(FailurePane), findsOneWidget);
          expect(find.text('重新加载'), findsOneWidget);
        }
        void noDeletedData(GrowthSnapshot? stored) {
          if (stored == null) return;
          expect(
            stored.scoredSessions.map((score) => score.sessionId),
            isNot(contains(fullId)),
          );
          expect(
            stored.growth.trainingReference?.round().toString(),
            anyOf(isNull, after),
          );
          expect(stored.growth.validBehaviorCount, lessThanOrEqualTo(1));
        }

        noDeletedData(await cache());
        // Inspect the encrypted slot independently of the provider's trust
        // flag, so marking a stale file untrusted cannot hide a cleanup bug.
        noDeletedData(
          await frames.real(
            ApiGrowthRepository(api, a).cached,
            'encrypted growth slot after contact deletion',
          ),
        );
      });

      await frames.phase('growth-recovery', () async {
        final mark = wire.mark();
        wire.historyUnavailable = false;
        final retry = find.descendant(
          of: growth,
          matching: find.byWidgetPredicate(
            (w) =>
                w is ButtonStyleButton &&
                w.child is Text &&
                ['重新加载', '重试'].contains((w.child as Text).data),
          ),
        );
        await frames.show(retry, within: growth, scrollBack: true);
        await frames.tap(retry);
        await frames.until(
          () => wire
              .readsAfter(mark)
              .any(
                (read) =>
                    read.status == 200 &&
                    read.cursor == null &&
                    read.nextCursor == null &&
                    read.ids.length == 100 &&
                    read.ids.toSet().length == 100 &&
                    read.ids.contains(singleId) &&
                    read.ids.contains(legacyId) &&
                    !read.ids.contains(fullId),
              ),
          'real terminal page with 100 surviving sessions',
        );
        await frames.until(
          () =>
              find.byType(RefreshIndicator).evaluate().isNotEmpty &&
              offline.evaluate().isEmpty,
          'recovered growth list with cleared offline banner',
        );
        await frames.show(reference(after), within: growth);
        await checkScores(linked: false);
        expect(offline, findsNothing);
        expect(unavailable, findsNothing);
        checkCache(await cache(), linked: false);
      });

      await frames.phase('account-isolation', () async {
        final aRepo = container.read(growthRepositoryProvider)!;
        final b = await frames.real(
          () => login(input('TICKET_B')),
          'synthetic login and activate account B',
        );
        expect(b.account, isNot(a.account));
        await frames.until(
          () => growth.evaluate().isEmpty,
          'A growth route discarded on identity change',
        );
        final fenced = await frames.real(() async {
          try {
            await aRepo.cached();
            return false;
          } on SessionChanged {
            return true;
          }
        }, 'A cache fenced after account switch');
        expect(fenced, isTrue);
        // PracticeHomePage also reads growth. Check B's cache before entering
        // either route and keep both repositories offline until B's retry.
        expect(await cache(), isNull);
        wire.historyUnavailable = true;
        final blockedMark = wire.mark();
        await frames.tap(find.text('暂不测评'));
        await frames.appeared(home, 'practice home for B');
        await enterGrowth();
        await frames.appeared(
          unavailable,
          'B retry with empty cache and history outage',
        );
        await waitFor503(blockedMark);
        expect(offline, findsNothing);
        expect(find.text(_single), findsNothing);
        expect(find.text(_legacy), findsNothing);
        expect(reference(after), findsNothing);

        wire.historyUnavailable = false;
        final mark = wire.mark();
        await frames.tap(find.text('重新加载'));
        await frames.appeared(
          find.byType(RefreshIndicator),
          'B online growth list',
        );
        await frames.show(find.text('训练参考分 · 待解锁'), within: growth);
        await frames.show(find.text('还没有可展示的得分'), within: growth);
        expect(find.text(_single), findsNothing);
        expect(find.text(_legacy), findsNothing);
        expect(find.text('100 / 100'), findsNothing);
        expect(
          wire
              .readsAfter(mark)
              .any(
                (r) =>
                    r.status == 200 &&
                    r.cursor == null &&
                    r.nextCursor == null &&
                    r.ids.isEmpty,
              ),
          isTrue,
          reason: wire.historyReceipt(mark),
        );
        final stored = await cache();
        expect(stored, isNotNull);
        expect(stored!.scoredSessions, isEmpty);
        expect(stored.growth.trainingReference, isNull);
        expect(stored.growth.validBehaviorCount, 0);

        // Reopen the same storage root as a second Sessions. B must restore
        // the same account without inheriting A's deletion ownership, and the
        // product repository must read B's persisted cache back from disk.
        final reopened = storage.open();
        await frames.real(
          reopened.restore,
          'restored Sessions after B wrote its growth cache',
        );
        final restoredB = reopened.active!;
        expect(restoredB.account, b.account);
        expect(reopened.growthCacheInvalidated(restoredB), isFalse);
        final reopenedRepo = ApiGrowthRepository(
          AppApi(wire.origin, wire, reopened),
          restoredB,
        );
        addTearDown(reopenedRepo.cache.dispose);
        final coldStored = await frames.real(
          reopenedRepo.cached,
          'B encrypted cache after Sessions reopen',
        );
        expect(coldStored, isNotNull);
        expect(coldStored!.scoredSessions, isEmpty);
        expect(coldStored.growth.trainingReference, isNull);
        expect(coldStored.growth.validBehaviorCount, 0);
      });

      await frames.phase('journey', () async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
