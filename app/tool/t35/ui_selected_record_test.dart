import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart' show newRequestId;
import 'package:high_eq/features/onboarding/surface.dart' show FlowSurface;
import 'package:high_eq/features/onboarding/repository.dart' show policyVersion;
import 'package:high_eq/features/privacy/export_namespace.dart';
import 'package:high_eq/features/privacy/page.dart';
import 'package:http/http.dart' as http;

import '../../test/privacy/export_test_support.dart'
    show reportPrivacyExportPresented;
import '../../test/privacy/records_journey_support.dart';
import '../t27/history_journey_support.dart' show JourneyFrames, MemorySecret;
import '../t29/loopback_client.dart';
import 'zip_reader.dart';

const _recordPath = '/v1/me/data/sessions';
const _pageSize = 20;
const _export = Key('privacy-export');
const _records = Key('owned-records-page');
const _bridge = MethodChannel('cn.higheq/mobile-commerce');
const _paths = MethodChannel('plugins.flutter.io/path_provider');

// Widget navigation starts real asynchronous IO. Use the real-time binding
// and let the numeric-loopback client enforce the network boundary.
class _LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

class _Exchange {
  _Exchange(this.op, http.Request request)
    : method = request.method,
      uri = request.url;

  final AppOp op;
  final String method;
  final Uri uri;
  int? status;
  Json? body;
}

class _PrivacyWire implements Transport {
  final _inner = HttpTransport(loopbackDirectClient());
  final exchanges = <_Exchange>[];

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    final recordsJson = op == AppOp.listDataRecords || op == AppOp.deleteSource;
    if (!recordsJson && op != AppOp.exportData) return _inner.send(op, request);

    final exchange = _Exchange(op, request);
    exchanges.add(exchange);
    final response = await _inner.send(op, request);
    exchange.status = response.statusCode;
    if (!recordsJson) {
      return response;
    }

    // Observe only the small locator/receipt responses and forward the exact
    // bytes to AppApi. The ZIP download stays on its original stream.
    final bytes = await response.stream.toBytes();
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is Json) exchange.body = decoded;
    } on FormatException {
      // The production decoder must still receive malformed responses.
    }
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() => _inner.close();
}

String _requiredEnv(String name) {
  final value = Platform.environment[name];
  if (value == null || value.trim().isEmpty) {
    throw TestFailure('$name is required for the selected-record live test');
  }
  return value;
}

Uri _origin() {
  final origin = Uri.tryParse(_requiredEnv('T35_ORIGIN'));
  if (origin == null ||
      origin.scheme != 'http' ||
      InternetAddress.tryParse(origin.host)?.isLoopback != true ||
      !origin.hasPort ||
      origin.port < 1 ||
      origin.port > 65535 ||
      origin.userInfo.isNotEmpty ||
      (origin.path.isNotEmpty && origin.path != '/') ||
      origin.hasQuery ||
      origin.hasFragment) {
    throw TestFailure('T35_ORIGIN must be a numeric loopback HTTP origin');
  }
  return origin;
}

Future<AccountScope> _login(AppApi api, String ticket) async {
  final response = await MobileEndpoints(api).login(
    body: {
      'credential': {'provider': 'apple', 'proof': ticket},
      'age_confirmed': true,
      'terms_version': policyVersion,
      'privacy_version': policyVersion,
    },
  );
  return api.sessions.activate(Tokens.fromJson(response));
}

Future<Map<String, String>> _createSessions(
  MobileEndpoints wire,
  AccountScope scope,
  String owner,
  int count,
) async {
  final grant = await wire.setConsent(
    scope: scope,
    purpose: 'practice',
    body: {'version': 'v1', 'granted': true},
  );
  expect(grant['purpose'], 'practice');
  expect(grant['granted'], isTrue);
  final sessions = <String, String>{};
  for (var i = 0; i < count; i++) {
    final scenario = 'T35 合成对练 $owner-${i + 1}';
    final created = await wire.createSession(
      scope: scope,
      body: {
        'request_id': newRequestId(),
        'scene': 'work',
        'scenario': scenario,
      },
    );
    sessions[created['session_id'] as String] = scenario;
  }
  expect(sessions, hasLength(count));
  return sessions;
}

List<Json> _items(Json page) => (page['items'] as List).cast<Json>();

Iterable<String> _ids(Iterable<Json> items) =>
    items.map((item) => item['id'] as String);

String _reference(String id) => '#${id.substring(id.length - 8)}';

String _displayTime(Json item) {
  final wireTime = item['recorded_at'] as String;
  final local = DateTime.parse(wireTime).toLocal().toString().substring(0, 19);
  final fraction = RegExp(r'\.\d+').firstMatch(wireTime)?.group(0) ?? '';
  return '$local$fraction';
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  do {
    await tester.pump(const Duration(milliseconds: 25));
    if (ready()) return;
  } while (DateTime.now().isBefore(deadline));
  final surface = find.byType(FlowSurface);
  final message = surface.evaluate().length == 1
      ? tester.widget<FlowSurface>(surface).message
      : null;
  fail(message == null ? reason : '$reason ($message)');
}

bool _buttonEnabled(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  return finder.evaluate().isNotEmpty &&
      tester.widget<FilledButton>(finder).onPressed != null;
}

Future<void> _showInList(
  WidgetTester tester,
  Finder page,
  Finder target, {
  bool scrollBack = false,
}) async {
  final list = find.descendant(of: page, matching: find.byType(ListView));
  final delta = Offset(0, scrollBack ? 350 : -350);
  for (var scroll = 0; target.evaluate().isEmpty && scroll < 12; scroll++) {
    await tester.dragFrom(tester.getRect(list).center, delta);
    await tester.pumpAndSettle();
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget);
}

Future<Finder> _showRecord(WidgetTester tester, Json item) async {
  final reference = find.text(_reference(item['id'] as String));
  await _showInList(tester, find.byKey(_records), reference);
  final card = find.ancestor(of: reference, matching: find.byType(Card));
  expect(find.descendant(of: card, matching: find.text('对练')), findsOneWidget);
  expect(
    find.descendant(of: card, matching: find.text(_displayTime(item))),
    findsOneWidget,
  );
  return reference;
}

Directory? _receiptDirectory() {
  final value = Platform.environment['T35_RECORD_EXPORT_RECEIPT_DIR'];
  if (value == null || value.trim().isEmpty) return null;
  return Directory(value)..createSync(recursive: true);
}

Map<String, String> _exportedSessions(Map<String, List<int>> archive) {
  final manifest = jsonDecode(utf8.decode(archive['manifest.json']!)) as Json;
  expect(manifest['files'], orderedEquals(archive.keys));
  expect(manifest['modules'], contains('training'));
  final training = jsonDecode(utf8.decode(archive['training.json']!)) as List;
  final sessions = {
    for (final row in training.cast<Json>())
      row['session_id'] as String: (row['setup'] as Json)['scenario'] as String,
  };
  expect(sessions, hasLength(training.length));
  return sessions;
}

Future<Map<String, String>> _downloadAccountExport(
  MobileEndpoints wire,
  AccountScope scope,
  String label,
) async {
  final bytes = await wire
      .exportData(scope: scope)
      .expand((chunk) => chunk)
      .toList();
  final directory = _receiptDirectory();
  if (directory != null) {
    await File(
      '${directory.path}/accepted-$label.zip',
    ).writeAsBytes(bytes, flush: true);
    return _exportedSessions(
      await readZipArchive('${directory.path}/accepted-$label.zip'),
    );
  }
  final temporary = await Directory.systemTemp.createTemp('t35-export-');
  try {
    final file = File('${temporary.path}/accepted-$label.zip');
    await file.writeAsBytes(bytes, flush: true);
    return _exportedSessions(await readZipArchive(file.path));
  } finally {
    await temporary.delete(recursive: true);
  }
}

Future<({String path, Map<String, String> sessions})> _exportFromPage(
  WidgetTester tester,
  Directory namespace,
  String label, {
  bool scrollBack = false,
}) async {
  const opening = '正在打开系统面板…';
  const presenting = '请在系统面板中完成保存或分享。';
  const success = '系统已完成保存或分享。';
  final messenger = tester.binding.defaultBinaryMessenger;
  final receipt = Completer<void>();
  ({String path, int id})? delivered;
  messenger.setMockMethodCallHandler(_bridge, (call) async {
    if (call.method == 'cleanupStatus') {
      return {'state': 'ok', 'removed': 0, 'failed': 0};
    }
    expect(call.method, 'shareExport');
    final args = (call.arguments as Map).cast<String, Object?>();
    expect(args['mimeType'], 'application/zip');
    expect(delivered, isNull);
    delivered = (path: args['path'] as String, id: args['requestId'] as int);
    await receipt.future;
    return null;
  });
  try {
    await _showInList(
      tester,
      find.byType(PrivacyPage),
      find.byKey(_export),
      scrollBack: scrollBack,
    );
    await tester.tap(find.byKey(_export));
    await _waitFor(
      tester,
      () => delivered != null && find.text(opening).evaluate().length == 1,
      'PrivacyPage did not open export delivery',
    );
    final file = delivered!;
    expect(find.text(presenting), findsNothing);
    expect(find.text(success), findsNothing);
    expect(File(file.path).parent.path, namespace.path);
    final archive = await readZipArchive(file.path);
    final sessions = _exportedSessions(archive);
    final receiptDirectory = _receiptDirectory();
    if (receiptDirectory != null) {
      File(file.path).copySync('${receiptDirectory.path}/accepted-$label.zip');
    }

    await reportPrivacyExportPresented(messenger, file.id);
    await _waitFor(
      tester,
      () => find.text(presenting).evaluate().length == 1,
      'PrivacyPage did not show the iOS presentation receipt',
    );
    expect(find.text(success), findsNothing);
    expect(await File(file.path).exists(), isTrue);
    receipt.complete();
    await _waitFor(
      tester,
      () => find.text(success).evaluate().length == 1,
      'PrivacyPage did not complete export after the system receipt',
    );
    expect(await File(file.path).exists(), isFalse);
    return (path: file.path, sessions: sessions);
  } finally {
    if (!receipt.isCompleted) receipt.complete();
    messenger.setMockMethodCallHandler(_bridge, null);
  }
}

void main() {
  _LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  testWidgets(
    'PrivacyPage selects a second-page session, confirms, refreshes and re-exports',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 568);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final origin = _origin();
      final ticketA = _requiredEnv('T35_RECORD_DEV_TICKET_A');
      final ticketB = _requiredEnv('T35_RECORD_DEV_TICKET_B');
      expect(
        ticketA != ticketB,
        isTrue,
        reason: 'use distinct synthetic tickets',
      );

      final directory = await Directory.systemTemp.createTemp('t35-records-');
      addTearDown(() => directory.delete(recursive: true));
      final observed = _PrivacyWire();
      addTearDown(observed.close);
      final control = HttpTransport(loopbackDirectClient());
      addTearDown(control.close);
      final apiA = AppApi(
        origin,
        observed,
        Sessions(MemorySecret(), Directory('${directory.path}/a')),
      );
      final apiB = AppApi(
        origin,
        control,
        Sessions(MemorySecret(), Directory('${directory.path}/b')),
      );
      final frames = JourneyFrames(tester);
      await apiA.sessions.restore();
      await mountRecordsApp(tester, apiA);
      await logInForRecords(frames, appleProof: ticketA);
      final a = apiA.sessions.active!;
      final b = await _login(apiB, ticketB);
      expect(a.account, isNot(b.account));
      final wireB = MobileEndpoints(apiB);
      final own = await _createSessions(
        MobileEndpoints(apiA),
        a,
        'A',
        _pageSize + 1,
      );
      final other = await _createSessions(wireB, b, 'B', 1);
      final otherBefore = await wireB.listDataRecords(
        scope: b,
        kind: 'sessions',
      );
      expect(_ids(_items(otherBefore)), orderedEquals(other.keys));
      expect(otherBefore['next_cursor'], isNull);

      Future<void> phase(String name, Future<void> Function() action) async {
        debugPrintSynchronously('BEGIN(page.$name)');
        await action();
        debugPrintSynchronously('PASS(page.$name)');
      }

      final staging = Directory('${directory.path}/exports')..createSync();
      final namespace = await privacyExportAccountDirectory(staging, a.account);
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_paths, (call) async {
        expect(call.method, 'getTemporaryDirectory');
        expect(call.arguments, isNull);
        return staging.path;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(_paths, null));

      await openRecordsPrivacy(frames, a.account);

      late Map<String, String> otherExportedBefore;
      await phase('account-b.before', () async {
        otherExportedBefore = await _downloadAccountExport(
          wireB,
          b,
          'b-before',
        );
        expect(otherExportedBefore, other);
        expect(otherExportedBefore.keys, isNot(contains(anyOf(own.keys))));
      });

      late ({String path, Map<String, String> sessions}) before;
      await phase('account-a.before', () async {
        before = await _exportFromPage(tester, namespace, 'a-before');
        expect(before.sessions, own);
      });

      final privacy = find.byType(PrivacyPage);
      final recordsPage = find.byKey(_records);
      final sessionsChip = find.byKey(const Key('records-kind-sessions'));
      await _showInList(tester, privacy, find.byKey(browseRecords));
      await tester.tap(find.byKey(browseRecords));
      await _waitFor(
        tester,
        () =>
            sessionsChip.evaluate().isNotEmpty &&
            tester.widget<ChoiceChip>(sessionsChip).onSelected != null,
        'browse did not open the production records page',
      );
      await _showInList(tester, recordsPage, sessionsChip);
      await tester.tap(sessionsChip);

      final loadMore = find.byKey(const Key('records-load-more'));
      List<_Exchange> sessionPages() => observed.exchanges
          .where(
            (request) =>
                request.op == AppOp.listDataRecords &&
                request.uri.path == _recordPath,
          )
          .toList();
      await _waitFor(
        tester,
        () =>
            sessionPages().isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
        'the session list did not settle',
      );
      final first = sessionPages().single;
      expect(first.method, 'GET');
      expect(first.status, 200);
      expect(first.uri.queryParameters, {'limit': '$_pageSize'});
      final firstItems = _items(first.body!);
      expect(firstItems, hasLength(_pageSize));
      final cursor = first.body!['next_cursor'];
      expect(
        cursor,
        isA<String>().having((value) => value, 'cursor', isNotEmpty),
      );

      final keeper = firstItems.first;
      final keeperId = keeper['id'] as String;
      await _showRecord(tester, keeper);
      await _showInList(tester, recordsPage, loadMore);
      await tester.tap(loadMore);

      final endOfList = find.text('已显示全部记录');
      await _waitFor(
        tester,
        () =>
            sessionPages().length >= 2 &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
        'load more did not settle',
      );
      final next = sessionPages().last;
      expect(sessionPages(), hasLength(2));
      expect(next.method, 'GET');
      expect(next.status, 200);
      expect(next.uri.queryParameters, {
        'limit': '$_pageSize',
        'cursor': cursor,
      });
      expect(next.body!['next_cursor'], isNull);
      final target = _items(next.body!).single;
      final targetId = target['id'] as String;
      expect([..._ids(firstItems), targetId], unorderedEquals(own.keys));
      expect(_reference(targetId), isNot(_reference(keeperId)));
      await _showInList(tester, recordsPage, endOfList);

      final targetReference = await _showRecord(tester, target);
      final deleteSelected = find.byKey(const Key('records-delete-selected'));
      await tester.tap(targetReference);
      await _waitFor(
        tester,
        () => deleteSelected.hitTestable().evaluate().isNotEmpty,
        'tapping the visible reference did not select the record',
      );

      final dialog = find.byType(AlertDialog);
      final confirm = find.byKey(const Key('records-confirm-delete'));
      Iterable<_Exchange> deletes() =>
          observed.exchanges.where((r) => r.op == AppOp.deleteSource);
      Future<void> openConfirmation() async {
        await tester.tap(deleteSelected);
        // Admission starts after the dialog mounts. Hit-testable does not mean
        // enabled, and tapping while onPressed is null would be a silent no-op.
        await _waitFor(
          tester,
          () =>
              confirm.hitTestable().evaluate().isNotEmpty &&
              _buttonEnabled(tester, const Key('records-confirm-delete')),
          'the selected record did not open confirmation',
        );
        for (final text in [
          '删除这条对练？',
          _reference(targetId),
          _displayTime(target),
          '删除后不可恢复。',
        ]) {
          expect(
            find.descendant(of: dialog, matching: find.text(text)),
            findsOneWidget,
          );
        }
        expect(
          find.descendant(
            of: dialog,
            matching: find.text(_reference(keeperId)),
          ),
          findsNothing,
        );
        expect(
          deletes(),
          isEmpty,
          reason: 'DELETE must wait for explicit confirmation',
        );
      }

      await phase('account-a.delete', () async {
        await openConfirmation();
        await tester.tap(
          find.descendant(of: dialog, matching: find.text('取消')),
        );
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);
        expect(deletes(), isEmpty);
        await openConfirmation();
        await tester.tap(confirm);
      });

      final refreshed = find.text('已删除所选对练记录。记录列表已刷新。');
      await _waitFor(
        tester,
        () =>
            refreshed.evaluate().isNotEmpty &&
            recordsPage.evaluate().isEmpty &&
            _buttonEnabled(tester, browseRecords),
        'PrivacyPage did not return with a confirmed list refresh',
      );

      final deletion = deletes().single;
      expect(deletion.method, 'DELETE');
      expect(deletion.uri.path, '$_recordPath/$targetId');
      expect(deletion.status, 200);
      expect(deletion.body, {'ok': true});
      expect(sessionPages(), hasLength(3));
      final readback = sessionPages().last;
      expect(
        observed.exchanges.indexOf(readback),
        greaterThan(observed.exchanges.indexOf(deletion)),
      );
      expect(readback.method, 'GET');
      expect(readback.status, 200);
      expect(readback.uri.queryParameters, {'limit': '$_pageSize'});
      expect(
        readback.body!['next_cursor'],
        isNull,
        reason: 'the post-delete first page must now contain all 20 sessions',
      );
      final remaining = {...own}..remove(targetId);
      expect(_ids(_items(readback.body!)), unorderedEquals(remaining.keys));

      // A user can continue down to the privacy controls after the readback.
      // From the bottom of a compact page, export is above the viewport.
      await tester.pumpAndSettle();
      final privacyList = find.byKey(const Key('privacy-account-list'));
      final privacyScroll = find
          .descendant(of: privacyList, matching: find.byType(Scrollable))
          .first;
      final privacyPosition = tester.state<ScrollableState>(privacyScroll).position;
      for (var swipe = 0; swipe < 6; swipe++) {
        await tester.drag(privacyList, const Offset(0, -420));
        await tester.pumpAndSettle();
        if (privacyPosition.pixels >= privacyPosition.maxScrollExtent) break;
      }
      expect(privacyPosition.pixels, privacyPosition.maxScrollExtent);
      expect(find.byKey(_export).hitTestable(), findsNothing);
      debugPrintSynchronously(
        'T35_RETURN_SCROLL offset=${privacyPosition.pixels} '
        'export_hittable=false',
      );

      late ({String path, Map<String, String> sessions}) after;
      await phase('account-a.after', () async {
        after = await _exportFromPage(
          tester,
          namespace,
          'a-after',
          scrollBack: true,
        );
        expect(after.sessions, remaining);
        expect(after.path, isNot(before.path));
        expect(await File(before.path).exists(), isFalse);
      });
      final exports = observed.exchanges.where((r) => r.op == AppOp.exportData);
      expect(exports.map((r) => (r.method, r.uri.path, r.status)), [
        ('GET', '/v1/me/export', 200),
        ('GET', '/v1/me/export', 200),
      ]);
      expect(
        observed.exchanges.indexOf(exports.last),
        greaterThan(observed.exchanges.indexOf(readback)),
      );

      final otherAfter = await wireB.listDataRecords(
        scope: b,
        kind: 'sessions',
      );
      expect(
        otherAfter,
        otherBefore,
        reason: 'account B must retain its own session',
      );
      await phase('account-b.after', () async {
        final otherExportedAfter = await _downloadAccountExport(
          wireB,
          b,
          'b-after',
        );
        expect(otherExportedAfter, otherExportedBefore);
        expect(otherExportedAfter, other);
        expect(otherExportedAfter.keys, isNot(contains(anyOf(own.keys))));
      });

      final receiptDirectory = _receiptDirectory();
      if (receiptDirectory != null) {
        await File('${receiptDirectory.path}/journey.json').writeAsString(
          '${const JsonEncoder.withIndent('  ').convert({
            'schema': 't35-selected-record-journey-v1',
            'account_a': a.account,
            'account_b': b.account,
            'target_session_id': targetId,
            'a_before': own,
            'a_after': remaining,
            'b_before_list': _ids(_items(otherBefore)).toList(),
            'b_after_list': _ids(_items(otherAfter)).toList(),
            'exports': ['accepted-b-before.zip', 'accepted-a-before.zip', 'accepted-a-after.zip', 'accepted-b-after.zip'],
          })}\n',
          flush: true,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 4)),
    variant: const TargetPlatformVariant({TargetPlatform.iOS}),
  );
}
