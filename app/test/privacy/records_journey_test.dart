import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide within;
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/onboarding/login.dart';

import '../../tool/t27/history_journey_support.dart' show JourneyFrames;
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import 'account_journey_test.dart' show account, currentPage, within;
import 'records_journey_support.dart';

const _a = 'synthetic-A';
const _b = 'synthetic-B';
const _recordsPage = Key('owned-records-page');
const _confirm = Key('records-confirm-delete');
const _deleteSelected = Key('records-delete-selected');
const _idA = '00000000-0000-4000-8000-000000000001';
const _idB = '00000000-0000-4000-8000-000000000002';
const _idA2 = '00000000-0000-4000-8000-000000000003';
const _wireTime = '2026-11-21T01:30:00Z';
const _cursor = 'opaque+/?=next';

Finder _record(String id) =>
    find.byKey(ValueKey('owned-record-assessments:$id'));

Map<String, Object?> _page(List<String> ids, {String? cursor}) => {
  'items': [
    for (final id in ids)
      {
        'kind': 'assessments',
        'id': id,
        'label': '测评',
        'recorded_at': _wireTime,
      },
  ],
  'next_cursor': cursor,
};

Future<void> _browse(JourneyFrames frames, Finder privacy) async {
  final entry = within(privacy, find.byKey(browseRecords));
  await frames.show(entry, within: privacy);
  await frames.tap(entry);
  await frames.appeared(find.byKey(_recordsPage), 'record browser');
}

bool _enabled(WidgetTester tester, Key key) {
  final button = find.byKey(key);
  return button.evaluate().length == 1 &&
      tester.widget<FilledButton>(button).onPressed != null;
}

Future<void> _logout(JourneyFrames frames, Finder privacy) async {
  await frames.tap(within(privacy, find.byType(BackButton)));
  final me = currentPage<HomeShell>('/me');
  final logout = within(me, find.text('退出账号'));
  await frames.show(logout, within: me);
  await frames.tap(logout);
  await frames.tap(find.text('确认退出'));
  await frames.appeared(currentPage<LoginPage>('/'), 'signed-out login page');
}

void main() {
  const ios = TargetPlatformVariant({TargetPlatform.iOS});

  testWidgets(
    'formal login, second-page selection, cancellation, confirmation and list retry',
    (tester) async {
      final frames = JourneyFrames(tester);
      final directory = await frames.real(
        () => Directory.systemTemp.createTemp('t35-records-ui.'),
        'temporary account storage',
      );
      addTearDown(() => directory.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), directory);
      final transport = Handler();
      final firstCheck = Completer<void>();
      final confirmCheck = Completer<void>();
      final listRefresh = Completer<void>();
      var meReads = 0;
      var listReads = 0;
      var deletes = 0;
      var loginCount = 0;
      transport.handle = (op, req) async {
        switch (op) {
          case AppOp.login:
            loginCount++;
            expect((jsonDecode(req.body) as Map)['credential'], {
              'provider': 'apple',
              'proof': 'synthetic-proof-A',
            });
            return response(tokens(_a, 'access-A').toJson());
          case AppOp.getMe:
            meReads++;
            if (meReads == 3) await firstCheck.future;
            if (meReads == 5) await confirmCheck.future;
            return response(account(bindings: ['apple']));
          case AppOp.listConsents:
          case AppOp.listAssessments:
            return response(_page([]));
          case AppOp.getTodayPlan:
            return response({'code': 'not_found'}, 404);
          case AppOp.getEntitlements:
            return response({'tier': 'free'});
          case AppOp.listDataRecords:
            expect(req.method, 'GET');
            expect(req.url.path, '/v1/me/data/assessments');
            expect(req.headers['Authorization'], 'Bearer access-A');
            listReads++;
            expect(req.url.queryParameters, {
              'limit': '20',
              if (listReads == 2) 'cursor': _cursor,
            });
            return switch (listReads) {
              1 => response(_page([_idA], cursor: _cursor)),
              2 => response(_page([_idB])),
              3 => await listRefresh.future.then(
                (_) => response({'code': 'service_unavailable'}, 503),
              ),
              4 => response(_page([_idA])),
              _ => throw StateError('unexpected list refresh'),
            };
          case AppOp.deleteSource:
            deletes++;
            expect(req.method, 'DELETE');
            expect(req.url.path, '/v1/me/data/assessments/$_idB');
            expect(req.headers['Authorization'], 'Bearer access-A');
            return response({'ok': true});
          default:
            throw StateError(op.name);
        }
      };

      await mountRecordsApp(
        tester,
        AppApi(Uri.https('example.invalid'), transport, sessions),
      );
      await logInForRecords(frames, appleProof: 'synthetic-proof-A');
      expect(loginCount, 1);
      final privacy = await openRecordsPrivacy(frames, _a);
      await _browse(frames, privacy);

      final records = find.byKey(_recordsPage);
      final more = find.byKey(const Key('records-load-more'));
      await frames.show(more, within: records);
      await frames.tap(more);
      await frames.show(_record(_idB), within: records);
      expect(listReads, 2);
      expect(find.text('#00000001'), findsOneWidget);
      expect(find.text('#00000002'), findsOneWidget);
      await frames.tap(_record(_idB));
      await frames.tap(find.byKey(_deleteSelected));

      final dialog = find.byType(AlertDialog);
      final confirm = within(dialog, find.byKey(_confirm));
      await frames.appeared(confirm.hitTestable(), 'visible confirm button');
      expect(meReads, 3);
      expect(_enabled(tester, _confirm), isFalse);
      expect(within(dialog, find.text('#00000002')), findsOneWidget);
      expect(
        within(
          dialog,
          find.text(
            DateTime.parse(_wireTime).toLocal().toString().substring(0, 19),
          ),
        ),
        findsOneWidget,
      );
      expect(within(dialog, find.text('删除后不可恢复。')), findsOneWidget);
      await tester.tap(confirm.hitTestable());
      await frames.frame();
      expect(deletes, 0);
      firstCheck.complete();
      await frames.until(() => _enabled(tester, _confirm), 'initial admission');
      await frames.tap(within(dialog, find.text('取消')));
      await frames.until(
        () => dialog.evaluate().isEmpty,
        'cancelled confirmation',
      );
      expect(deletes, 0);

      await frames.tap(find.byKey(_deleteSelected));
      await frames.until(
        () => _enabled(tester, _confirm),
        'reopened admission',
      );
      await frames.tap(confirm);
      expect(meReads, 5);
      expect(_enabled(tester, _confirm), isFalse);
      expect(deletes, 0);
      // Finish the account check during the cancelled dialog's exit animation.
      await tester.tap(within(dialog, find.text('取消')).hitTestable());
      confirmCheck.complete();
      await frames.until(
        () => dialog.evaluate().isEmpty,
        'cancelled send-time check',
      );
      expect(records, findsOneWidget);
      expect(deletes, 0);

      await frames.tap(find.byKey(_deleteSelected));
      await frames.until(() => _enabled(tester, _confirm), 'third admission');
      await frames.tap(confirm);

      await frames.until(() => listReads == 3, 'post-delete list request');
      expect(deletes, 1);
      expect(records, findsOneWidget);
      final receipt = find.text('已删除所选测评记录。记录列表已刷新。');
      expect(receipt, findsNothing);
      listRefresh.complete();
      final retry = find.byKey(const Key('records-retry'));
      await frames.appeared(retry, 'failed list refresh');
      expect(receipt, findsNothing);
      await frames.tap(retry);
      await frames.appeared(
        within(privacy, receipt),
        'privacy refresh receipt',
      );
      await frames.until(
        () => records.evaluate().isEmpty,
        'closed record route',
      );
      expect(records, findsNothing);
      expect(deletes, 1);
      expect(listReads, 4);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: ios,
  );

  testWidgets('the same App isolates late responses across A to B to A', (
    tester,
  ) async {
    final frames = JourneyFrames(tester);
    final directory = await frames.real(
      () => Directory.systemTemp.createTemp('t35-records-switch.'),
      'temporary account storage',
    );
    addTearDown(() => directory.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), directory);
    final transport = Handler();
    final oldList = Completer<void>();
    final oldDelete = Completer<void>();
    final recordCalls = <String>[];
    final loginCalls = <String>[];
    final logoutCalls = <String>[];
    int deletes = 0;
    int oldResponses = 0;
    transport.handle = (op, req) async {
      final auth = req.headers['Authorization'];
      switch (op) {
        case AppOp.login:
          final proof =
              ((jsonDecode(req.body) as Map)['credential'] as Map)['proof']
                  as String;
          loginCalls.add(proof);
          return response(tokens(proof == 'B' ? _b : _a, proof).toJson());
        case AppOp.getMe:
          return response(account(userId: auth == 'Bearer B' ? _b : _a));
        case AppOp.listConsents:
        case AppOp.listAssessments:
          return response(_page([]));
        case AppOp.getTodayPlan:
          return response({'code': 'not_found'}, 404);
        case AppOp.getEntitlements:
          return response({'tier': 'free'});
        case AppOp.logout:
          logoutCalls.add(auth!);
          return response({'ok': true});
        case AppOp.listDataRecords:
          recordCalls.add(auth!);
          if (auth == 'Bearer A1') {
            await oldList.future;
            oldResponses++;
            return response(_page([_idA]));
          }
          return response(_page([auth == 'Bearer B' ? _idB : _idA2]));
        case AppOp.deleteSource:
          deletes++;
          expect(auth, 'Bearer B');
          expect(req.url.path, '/v1/me/data/assessments/$_idB');
          await oldDelete.future;
          oldResponses++;
          return response({'ok': true});
        default:
          throw StateError(op.name);
      }
    };
    await mountRecordsApp(
      tester,
      AppApi(Uri.https('example.invalid'), transport, sessions),
    );
    await logInForRecords(frames, appleProof: 'A1');
    final firstLease = sessions.active;
    final a = await openRecordsPrivacy(frames, _a);
    await _browse(frames, a);
    await frames.until(() => recordCalls.length == 1, 'old list in flight');
    await frames.tap(within(find.byKey(_recordsPage), find.byType(BackButton)));
    await _logout(frames, a);

    await logInForRecords(frames, appleProof: 'B');
    final b = await openRecordsPrivacy(frames, _b);
    await _browse(frames, b);
    await frames.appeared(_record(_idB), 'B record');
    oldList.complete();
    await frames.until(() => oldResponses == 1, 'late A list returned');
    expect(_record(_idA), findsNothing);
    expect(_record(_idB), findsOneWidget);

    await frames.tap(_record(_idB));
    await frames.tap(find.byKey(_deleteSelected));
    await frames.until(() => _enabled(tester, _confirm), 'B admission');
    await frames.tap(find.byKey(_confirm));
    await frames.until(() => deletes == 1, 'B deletion in flight');
    await frames.tap(within(find.byKey(_recordsPage), find.byType(BackButton)));
    await _logout(frames, b);

    await logInForRecords(frames, appleProof: 'A2');
    expect(sessions.active, isNot(same(firstLease)));
    final again = await openRecordsPrivacy(frames, _a);
    await _browse(frames, again);
    await frames.appeared(_record(_idA2), 'A record in a new lease');
    oldDelete.complete();
    await frames.until(() => oldResponses == 2, 'late B deletion returned');

    expect(_record(_idA2), findsOneWidget);
    expect(_record(_idA), findsNothing);
    expect(_record(_idB), findsNothing);
    expect(find.byKey(_confirm), findsNothing);
    expect(find.textContaining('记录列表已刷新'), findsNothing);
    expect(recordCalls, ['Bearer A1', 'Bearer B', 'Bearer A2']);
    expect(loginCalls, ['A1', 'B', 'A2']);
    expect(logoutCalls, ['Bearer A1', 'Bearer B']);
    expect(deletes, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: ios);
}
