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
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/lobby.dart';
import 'package:high_eq/main.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

const _account = '85b72033-9f07-4bbc-8567-fc31f26508ab';
const _firstLevel = '19000000-0000-4000-8000-000000000001';
const _secondLevel = '19000000-0000-4000-8000-000000000002';
const _firstName = '只说刚才发生的事';
const _secondName = '表达失约后的感受';
const _ordinary = '单项练习';
const _levelLabel = '对练关卡';

class _MemorySessions extends Sessions {
  _MemorySessions(Directory directory) : super(MemorySecret(), directory);

  final cache = <(CacheKind, String), List<int>>{};

  @override
  Future<List<int>?> get(AccountScope scope, CacheKind kind, String id) async {
    require(scope);
    return cache[(kind, id)];
  }

  @override
  Future<void> put(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) async {
    require(scope);
    cache[(kind, id)] = List.of(bytes);
  }

  @override
  Future<void> remove(AccountScope scope, CacheKind kind, String id) async {
    require(scope);
    cache.remove((kind, id));
  }
}

Json _planItem(
  String id,
  String kind,
  String title,
  String contentId,
  bool done,
) => {
  'id': id,
  'kind': kind,
  'title': title,
  'content_id': contentId,
  'completed': done,
};

Json _level(String id, String title, String scene, String skill) => {
  'id': id,
  'title': title,
  'scene': scene,
  'target_item': skill,
  'difficulty': 1,
  'mode': 'single_skill',
};

void main() {
  testWidgets(
    '正式入口分时刷新后按目录名称分别打开两项到期重练',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Growth cache validation performs real local file checks, so advance
      // wall time while pumping UI frames until the page is quiet.
      Future<void> settle() async {
        var quietFrames = 0;
        for (var frame = 0; frame < 100; frame++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 3)),
          );
          await tester.pump(const Duration(milliseconds: 32));
          quietFrames = tester.binding.hasScheduledFrame ? 0 : quietFrames + 1;
          if (quietFrames >= 6) return;
        }
        fail('widget did not settle after advancing real I/O and test frames');
      }

      final semantics = tester.ensureSemantics();
      try {
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('t26-due-route-'),
        ))!;
        addTearDown(() => directory.delete(recursive: true));
        final sessions = _MemorySessions(directory);
        await tester.runAsync(() => sessions.activate(tokens(_account)));
        final fixtures =
            jsonDecode(
                  File('assets/contract_examples.json').readAsStringSync(),
                )
                as Json;
        final firstDue = DateTime.utc(2026, 11, 21, 8);
        final secondDue = firstDue.add(const Duration(minutes: 1));
        var replayTime = firstDue.subtract(const Duration(microseconds: 1));
        final planRequestTimes = <DateTime>[];
        final creates = <Json>[];
        final createdSessions = <String, Json>{};
        final catalog = [
          _level(_firstLevel, _firstName, 'work', 'observation'),
          _level(_secondLevel, _secondName, 'partner', 'feeling'),
        ];
        final empty = {'items': <Json>[], 'next_cursor': null};
        final wire = Handler()
          ..handle = (op, request) async {
            switch (op) {
              case AppOp.getTodayPlan:
                expect(request.method, 'GET');
                expect(request.url.path, '/v1/plans/today');
                planRequestTimes.add(replayTime);
                return response({
                  'day': '2026-11-21',
                  'personalized': true,
                  'items': [
                    _planItem(
                      '00000000-0000-4000-8000-0000000000e1',
                      'exercise',
                      '读人练习',
                      '00000000-0000-4000-8000-0000000000e2',
                      true,
                    ),
                    _planItem(
                      '059e4b0f-834e-5929-9da9-b7c6a5a762e6',
                      'level',
                      _ordinary,
                      '19000000-0000-4000-8000-000000000004',
                      true,
                    ),
                    _planItem(
                      '00000000-0000-4000-8000-0000000000f1',
                      'level',
                      '完整对练',
                      '19000000-0000-4000-8000-000000000005',
                      false,
                    ),
                    _planItem(
                      '00000000-0000-4000-8000-0000000000c1',
                      'card',
                      '知识卡',
                      '00000000-0000-4000-8000-0000000000c2',
                      true,
                    ),
                    if (!replayTime.isBefore(firstDue))
                      _planItem(
                        '7294e85a-31e3-5f3d-b2f8-8548f12586b7',
                        'level',
                        _ordinary,
                        _firstLevel,
                        false,
                      ),
                    if (!replayTime.isBefore(secondDue))
                      _planItem(
                        'd2176ef5-3030-51f9-9a86-327903d51469',
                        'level',
                        _ordinary,
                        _secondLevel,
                        false,
                      ),
                  ],
                });
              case AppOp.listLevels:
                expect(request.url.path, '/v1/levels');
                final scene = request.url.queryParameters['scene'];
                return response({
                  ...empty,
                  'items': catalog
                      .where(
                        (entry) => scene == null || entry['scene'] == scene,
                      )
                      .toList(),
                });
              case AppOp.listConsents:
                return response({
                  ...empty,
                  'items': [
                    ...((fixtures['listConsents'] as Json)['items'] as List),
                    {'purpose': 'practice', 'granted': true},
                  ],
                });
              case AppOp.listAssessments:
              case AppOp.listContacts:
              case AppOp.listSessions:
              case AppOp.listCards:
                return response(empty);
              case AppOp.createSession:
                expect(request.method, 'POST');
                expect(request.url.path, '/v1/sessions');
                final body = jsonDecode(request.body) as Json;
                expect(body.keys.toSet(), {'level_id', 'request_id'});
                final entry = catalog.singleWhere(
                  (row) => row['id'] == body['level_id'],
                );
                creates.add(body);
                final id = body['request_id'] as String;
                final session = {
                  ...fixtures['createSession'] as Json,
                  'session_id': id,
                  'level_id': entry['id'],
                  'target_item': entry['target_item'],
                };
                createdSessions[id] = session;
                return response(session);
              case AppOp.getSession:
                return response(
                  createdSessions[request.url.pathSegments.last]!,
                );
              default:
                return response((fixtures[op.name] as Json?) ?? {});
            }
          };
        final api = AppApi(Uri.https('wire.invalid'), wire, sessions);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [apiProvider.overrideWith((_) => api)],
            child: const HighEqApp(),
          ),
        );
        final navigator = find.byType(Navigator);
        for (
          var frame = 0;
          frame < 20 && navigator.evaluate().isEmpty;
          frame++
        ) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 16));
        }
        unawaited(
          tester.state<NavigatorState>(navigator).pushNamed('/practice'),
        );
        final planHeading = find.text('今日计划');
        for (
          var frame = 0;
          frame < 100 && planHeading.evaluate().isEmpty;
          frame++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(find.byType(PracticeHomeRoute), findsOneWidget);
        expect(planHeading, findsOneWidget);
        await settle();

        final rows = find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.onTap != null &&
              widget.title is Text &&
              (widget.title as Text).data == _ordinary &&
              widget.subtitle is Text &&
              ((widget.subtitle as Text).data ?? '').startsWith(_levelLabel) &&
              !((widget.subtitle as Text).data ?? '').contains('已完成'),
        );
        Finder rowNamed(String name) => find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.onTap != null &&
              widget.title is Text &&
              (widget.title as Text).data == _ordinary &&
              widget.subtitle is Text &&
              ((widget.subtitle as Text).data ?? '').contains(name),
        );

        void verifyPlan(int count) {
          expect(rows, findsNWidgets(count));
          expect(find.text('3 / ${4 + count} 已完成'), findsOneWidget);
          final regular = find.widgetWithText(ListTile, '对练关卡 · 已完成');
          expect(
            find.descendant(of: regular, matching: find.text(_ordinary)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.widgetWithText(ListTile, '读人小练习 · 已完成'),
              matching: find.text('读人练习'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.widgetWithText(ListTile, '知识卡 · 已完成'),
              matching: find.text('知识卡'),
            ),
            findsOneWidget,
          );
          final fullTile = tester.widget<ListTile>(
            find.widgetWithText(ListTile, '完整对练'),
          );
          expect((fullTile.subtitle as Text).data, startsWith(_levelLabel));
          expect(fullTile.onTap, isNotNull);
        }

        Future<void> refresh(DateTime next, int count) async {
          final before = planRequestTimes.length;
          replayTime = next;
          final scroll = find.descendant(
            of: find.byType(RefreshIndicator),
            matching: find.byType(Scrollable),
          );
          final position = tester.state<ScrollableState>(scroll).position;
          position.jumpTo(position.minScrollExtent);
          await tester.pump();
          await tester.timedDrag(
            scroll,
            const Offset(0, 440),
            const Duration(milliseconds: 600),
          );
          await settle();
          expect(planRequestTimes.sublist(before), [next]);
          verifyPlan(count);
          print(
            'REFRESH ${next.toIso8601String()} retry_rows=$count ordinary_unchanged=true',
          );
        }

        expect(planRequestTimes, [replayTime]);
        verifyPlan(0);
        print(
          'OPEN ${replayTime.toIso8601String()} retry_rows=0 ordinary_unchanged=true',
        );
        await refresh(firstDue, 1);
        await refresh(secondDue.subtract(const Duration(microseconds: 1)), 1);
        await refresh(secondDue, 2);

        final firstRow = rowNamed(_firstName);
        final secondRow = rowNamed(_secondName);
        expect(firstRow, findsOneWidget);
        expect(secondRow, findsOneWidget);
        await tester.ensureVisible(firstRow);
        await settle();
        expect(firstRow.hitTestable(), findsOneWidget);
        expect(tester.getSemantics(firstRow).label, contains(_firstName));
        await tester.ensureVisible(secondRow);
        await settle();
        expect(secondRow.hitTestable(), findsOneWidget);
        expect(tester.getSemantics(secondRow).label, contains(_secondName));
        print(
          'PRE-TAP NAMES firstName=${jsonEncode(_firstName)} secondName=${jsonEncode(_secondName)}',
        );

        Future<void> open(Finder row, String expected, String heading) async {
          await tester.ensureVisible(row);
          await settle();
          await tester.tap(row);
          await settle();
          expect(
            tester
                .widget<PracticeLobby>(
                  find.byType(PracticeLobby, skipOffstage: false),
                )
                .targetLevelId,
            expected,
          );
          expect(find.byType(PracticeChat), findsOneWidget);
          expect(find.text(heading), findsOneWidget);
          expect(creates.last['level_id'], expected);
          print('CREATE POST /v1/sessions level=$expected chat=$heading');
        }

        Future<void> backToPlan() async {
          final beforeBack = planRequestTimes.length;
          await tester.tap(find.byType(BackButton));
          await settle();
          expect(find.byType(PracticeLobby), findsOneWidget);
          await tester.tap(find.byType(BackButton));
          await settle();
          expect(find.byType(PracticeHomeRoute), findsOneWidget);
          expect(planRequestTimes.sublist(beforeBack), [secondDue]);
          verifyPlan(2);
          expect(rowNamed(_firstName), findsOneWidget);
          expect(rowNamed(_secondName), findsOneWidget);
          print('BACK GET /v1/plans/today reloaded both names selectable');
        }

        await open(firstRow, _firstLevel, '观察练习');
        expect(creates, hasLength(1));
        await backToPlan();
        await open(secondRow, _secondLevel, '感受练习');
        expect(creates, hasLength(2));
        expect(creates.map((body) => body['request_id']).toSet(), hasLength(2));
        expect(creates[0]['level_id'], _firstLevel);
        expect(creates[1]['level_id'], _secondLevel);
        await backToPlan();
        await tester.pumpWidget(const SizedBox.shrink());
        await settle();
      } finally {
        semantics.dispose();
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
