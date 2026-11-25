import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/privacy/records_adapter.dart';
import 'package:high_eq/features/privacy/records_page.dart';
import 'package:high_eq/features/privacy/store.dart';
import 'package:http/http.dart' as http;

import '../../tool/t27/history_journey_support.dart' show JourneyFrames;
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;
import 'account_journey_test.dart' show account;

const _id = '00000000-0000-4000-8000-000000000001';
const _other = '10000000-0000-4000-8000-000000000001';
const _time = '2026-11-21T09:00:00+08:00';

Map<String, Object?> _locator(
  OwnedDataKind kind, {
  String id = _id,
  String time = _time,
}) => {
  'kind': kind.wireName,
  'label': kind.label,
  'recorded_at': kind == OwnedDataKind.contacts ? null : time,
  if (kind.usesStableId) 'id': id else 'channel': 'voice',
};

Map<String, Object?> _locatorPage(List<Object> items) => {
  'items': items,
  'next_cursor': null,
};

void main() {
  late Handler wire;
  late PrivacyStore store;

  Future<void> start() async {
    final cache = await Directory.systemTemp.createTemp('t35-records-adapter.');
    addTearDown(() => cache.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), cache);
    final scope = await sessions.activate(tokens('synthetic-A'));
    wire = Handler();
    store = PrivacyStore(
      AppApi(Uri.https('example.invalid'), wire, sessions),
      scope,
    );
  }

  test(
    'all eight owned kinds use the same scoped list with opaque pagination',
    () async {
      await start();
      const kinds = [
        'assessments',
        'sessions',
        'reviews',
        'replies',
        'contacts',
        'manual_marks',
        'signal_events',
        'signal_windows',
      ];
      final adapter = OwnedDataRecordsAdapter(store);
      expect(OwnedDataKind.values.map((kind) => kind.wireName), kinds);
      for (final kind in OwnedDataKind.values) {
        wire.handle = (op, req) async {
          expect(op, AppOp.listDataRecords);
          expect(req.method, 'GET');
          expect(req.url.path, '/v1/me/data/${kind.wireName}');
          expect(req.url.queryParameters, {
            'cursor': 'opaque+/?=',
            'limit': '2',
          });
          expect(req.headers['Authorization'], 'Bearer access');
          return response({
            'items': [_locator(kind)],
            'next_cursor': 'opaque|next',
          });
        };
        final page = await adapter.loadPage(
          kind: kind,
          cursor: 'opaque+/?=',
          limit: 2,
        );
        expect(page.nextCursor, 'opaque|next');
        expect(page.items.single.kind, kind);
        expect(page.items.single.id, kind.usesStableId ? _id : null);
        expect(
          page.items.single.recordedAtIso,
          kind == OwnedDataKind.contacts ? null : _time,
        );
        expect(page.items.single.channel, kind.usesStableId ? null : 'voice');
      }
    },
  );

  test(
    'locator refuses private fields, category mismatches and invalid times',
    () async {
      await start();
      const kind = OwnedDataKind.sessions;
      final adapter = OwnedDataRecordsAdapter(store);
      for (final record in [
        {..._locator(kind), 'source_id': 'synthetic'},
        _locator(OwnedDataKind.assessments),
        _locator(kind, time: '2026-02-29T09:00:00+08:00'),
        _locator(kind, time: '2026-11-21T09:00:00'),
        _locator(kind, id: 'arbitrary'),
      ]) {
        wire.handle = (_, _) async => response(_locatorPage([record]));
        await expectLater(
          adapter.loadPage(kind: kind),
          throwsA(
            isA<OwnedDataRecordsFailure>().having(
              (error) => error.message,
              'message',
              ownedDataInvalidPageMessage,
            ),
          ),
        );
      }
      wire.handle = (_, _) async => response(
        _locatorPage([
          _locator(
            OwnedDataKind.signalWindows,
            time: '2026-11-21T09:00:01+08:00',
          ),
        ]),
      );
      await expectLater(
        adapter.loadPage(kind: OwnedDataKind.signalWindows),
        throwsA(isA<OwnedDataRecordsFailure>()),
      );
    },
  );

  test('both DELETE forms require a bare HTTP 200 acknowledgement', () async {
    await start();
    final adapter = OwnedDataRecordsAdapter(store);
    for (final kind in [OwnedDataKind.reviews, OwnedDataKind.signalWindows]) {
      final record = OwnedDataRecord.fromJson(
        _locator(kind),
        expectedKind: kind,
      );
      for (final (status, body) in <(int, Object)>[
        (202, {'ok': true}),
        (200, {'ok': false}),
        (200, {}),
        (200, {'ok': 'true'}),
        (200, {'ok': true, 'extra': true}),
        (200, []),
        (404, {'code': 'not_found'}),
        (503, {'code': 'unavailable'}),
        (200, {'ok': true}),
      ]) {
        final calls = <AppOp>[];
        final deletionOp = kind.usesStableId
            ? AppOp.deleteSource
            : AppOp.deleteWindow;
        wire.handle = (op, req) async {
          calls.add(op);
          if (op == AppOp.getMe) return response(account());
          expect(op, deletionOp);
          expect(req.method, 'DELETE');
          if (kind.usesStableId) {
            expect(req.url.path, '/v1/me/data/reviews/$_id');
            expect(req.url.hasQuery, isFalse);
          } else {
            expect(req.url.path, '/v1/signal-windows');
            expect(req.url.queryParameters, {
              'starts_at': _time,
              'channel': 'voice',
            });
          }
          return http.StreamedResponse(
            Stream.value(utf8.encode(jsonEncode(body))),
            status,
            headers: {'content-type': 'application/json'},
          );
        };
        if (status == 200 &&
            body is Map &&
            body.length == 1 &&
            body['ok'] == true) {
          await adapter.delete(record);
        } else {
          await expectLater(
            adapter.delete(record),
            throwsA(
              isA<OwnedDataRecordsFailure>()
                  .having(
                    (error) => error.status,
                    'HTTP error',
                    status >= 400 ? status : null,
                  )
                  .having(
                    (error) =>
                        error.message == privacyDeletionUnconfirmedMessage,
                    'invalid success receipt',
                    status < 300,
                  ),
            ),
          );
        }
        expect(calls, [AppOp.getMe, deletionOp]);
      }
    }
  });

  testWidgets(
    'same-name contacts are picked by number and need cascade acknowledgement',
    (tester) async {
      await tester.runAsync(start);
      var deletes = 0;
      wire.handle = (op, req) async {
        switch (op) {
          case AppOp.getMe:
            return response(account());
          case AppOp.listDataRecords:
            return response(
              _locatorPage([
                if (req.url.path.endsWith('/contacts'))
                  for (final id in [_id, if (deletes == 0) _other])
                    _locator(OwnedDataKind.contacts, id: id),
              ]),
            );
          case AppOp.listContacts:
            return response(
              _locatorPage([
                for (final id in [_id, _other])
                  {
                    'id': id,
                    'nickname': '同名同事',
                    'scene': 'work',
                    'editable': false,
                    'profile': {
                      'summary': '相同的合成手记',
                      'big_five': [],
                      'conflict_style': {'label': '合作型', 'confidence': 0.5},
                    },
                  },
              ]),
            );
          case AppOp.getEntitlements:
            return response({'tier': 'free', 'max_active_contacts': 1});
          case AppOp.deleteSource:
            deletes++;
            expect(req.url.path, '/v1/me/data/contacts/$_other');
            return response({'ok': true});
          default:
            throw StateError(op.name);
        }
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: TextButton(
                  onPressed: () =>
                      Navigator.of(context).push<OwnedDataDeleteResult>(
                        MaterialPageRoute(
                          builder: (_) => OwnedDataRecordsPage(store),
                        ),
                      ),
                  child: const Text('打开记录'),
                ),
              );
            },
          ),
        ),
      );
      final frames = JourneyFrames(tester);
      final tap = frames.tap;
      final host = find.text('打开记录');

      await tap(host);
      await tap(find.byKey(const Key('records-kind-contacts')));
      expect(find.text('同名同事'), findsNothing);
      await tap(find.byKey(const Key('records-open-contact-book')));
      await frames.appeared(find.text('关系人编号：$_other'), 'contact book');
      expect(find.text('同名同事'), findsNWidgets(2));
      expect(find.text('关系人编号：$_id'), findsOneWidget);
      expect(find.text('关系人编号：$_other'), findsOneWidget);
      await tap(find.byKey(const ValueKey('contact-list-row:$_other')));
      expect(find.text('关系人编号：$_other'), findsOneWidget);
      await tap(find.byKey(const Key('contact-select-for-deletion')));
      final confirm = find.byKey(const Key('records-confirm-delete'));
      final reference = find.byKey(
        const Key('records-confirmation-contact-reference'),
      );
      expect(reference, findsOneWidget);
      expect(
        find.descendant(of: reference, matching: find.text('关系人编号：$_other')),
        findsOneWidget,
      );
      expect(find.textContaining('高风险操作'), findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      expect(deletes, 0);
      await tap(find.byKey(const Key('records-contact-understood')));
      await frames.until(
        () => tester.widget<FilledButton>(confirm).onPressed != null,
        'enabled cascade confirmation',
      );
      await tap(confirm);
      await frames.until(() => deletes == 1, 'cascade DELETE');
      await frames.until(
        () => find.byKey(const Key('owned-records-page')).evaluate().isEmpty,
        'record route dismissed after readback',
      );
      await frames.appeared(host, 'record selection finished');
      expect(deletes, 1);
      expect(host, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
