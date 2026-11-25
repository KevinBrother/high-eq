import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/repository.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/contacts/workspace.dart';
import 'package:http/http.dart' as http;

class _VolatileSecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? v) async => value = v;
}

// The real product routes need real sockets; only the disposable loopback
// service is reachable from the runner sandbox.
class _T18LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

const _networkLimit = Duration(seconds: 30);

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String label,
}) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < _networkLimit) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  await tester.pump();
  fail('Timed out waiting for $label. No URL, token or contact body is logged.');
}

Future<void> _waitForText(WidgetTester tester, String text) => _waitUntil(
  tester,
  () => find.text(text).evaluate().isNotEmpty,
  label: 'text "$text"',
);

Finder _row(String name) => find.widgetWithText(ListTile, name);

Future<void> _open(WidgetTester tester, String name) async {
  await _waitUntil(
    tester,
    () => _row(name).evaluate().isNotEmpty,
    label: 'contact row',
  );
  await tester.ensureVisible(_row(name));
  await tester.pump();
  await tester.tap(_row(name));
  await tester.pump();
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await _waitForText(tester, text);
  final target = find.text(text).last;
  await tester.ensureVisible(target);
  await tester.pump();
  await tester.tap(target);
  await tester.pump();
}

Map<String, dynamic> _snapshotBody(String raw, String phase) {
  final value = jsonDecode(raw);
  if (value is! Map<String, dynamic> || value['phase'] != phase) {
    throw StateError('fixture "$phase" returned an invalid readback');
  }
  return value;
}

Set<String> _editableIds(Book book) => {
  for (final person in book.people)
    if (person.editable) person.id,
};

Set<String> _snapshotEditable(Map<String, dynamic> snapshot) => {
  for (final id in snapshot['editable'] as List) id as String,
};

Future<Map<String, dynamic>> _advance(
  WidgetTester tester,
  Uri origin,
  String fixtureSecret,
  String phase,
) async {
  // FIXTURE ONLY: this control route evolves the synthetic membership interval.
  // It is not a product route and never touches a purchase or merchant.
  final response = await tester.runAsync(() => http.post(
    origin.replace(path: '/__t18_fixture/advance'),
    headers: {
      'content-type': 'application/json',
      'x-t18-fixture': fixtureSecret,
    },
    body: jsonEncode({'phase': phase}),
  ));
  if (response!.statusCode != 200) {
    fail('fixture "$phase" returned status ${response.statusCode}');
  }
  return _snapshotBody(response.body, phase);
}

void main() {
  _T18LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets('普通会员到期改选与续费恢复走真实关系人页', (tester) async {
    final environment = Platform.environment;
    final rawOrigin = environment['T18_ORIGIN'];
    final ticket = environment['T18_TICKET'];
    final fixtureSecret = environment['T18_FIXTURE'];
    expect(rawOrigin, isNotNull);
    expect(ticket, isNotNull);
    expect(fixtureSecret, isNotNull);
    final origin = Uri.parse(rawOrigin!);
    final proof = ticket!;
    final secret = fixtureSecret!;
    expect(origin.scheme, 'http');
    expect(origin.host, '127.0.0.1');
    expect(origin.hasPort, isTrue);

    final directory = await Directory.systemTemp.createTemp('t18-live-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final wire = HttpTransport(http.Client());
    addTearDown(wire.close);
    final sessions = Sessions(_VolatileSecret(), directory);
    final api = MobileEndpoints(AppApi(origin, wire, sessions));
    final login = await tester.runAsync(() => api.login(body: {
      'credential': {'provider': 'apple', 'proof': proof},
      'age_confirmed': true,
      'terms_version': '2026-11',
      'privacy_version': '2026-11',
    }));
    final tokens = Tokens.fromJson(login!);
    final scope = await sessions.activate(tokens);
    final repo = ApiContacts(api, scope);

    final before = (await tester.runAsync(repo.load))!;
    expect(before.member, isTrue);
    expect(before.people.length, 2);
    expect(before.people.where((p) => p.editable).length, 2);
    final a = before.people.singleWhere((p) => p.name == '合成甲');
    final b = before.people.singleWhere((p) => p.name == '合成乙');

    Widget page() => MaterialApp(
      home: ContactsWorkspace(repo: repo, selection: SceneMemory()),
    );

    await tester.pumpWidget(page());
    await _waitForText(tester, '合成甲');
    await _waitForText(tester, '合成乙');
    expect(find.text('职场 · 可用'), findsNWidgets(2));

    // FIXTURE: expire the synthetic member interval. Both contacts remain in
    // the list; only the most recently used one may stay writable.
    final expired = await _advance(tester, origin, secret, 'expire');
    expect(expired['tier'], 'free');
    expect(expired['max_active_contacts'], 1);
    expect(_snapshotEditable(expired), {b.id});

    await tester.tap(find.byTooltip('刷新列表'));
    await tester.pump();
    await _waitUntil(
      tester,
      () => find.text('职场 · 只读').evaluate().isNotEmpty,
      label: 'expired list',
    );
    expect(
      find.descendant(of: _row('合成乙'), matching: find.text('职场 · 可用')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _row('合成甲'), matching: find.text('职场 · 只读')),
      findsOneWidget,
    );
    debugPrint('T18_STAGE expiry_observed');

    // ACTUAL PRODUCT UI: normal browsing of the read-only contact must not
    // change which contact remains default.
    await _open(tester, '合成甲');
    await _waitForText(tester, '只读 · 不能用于新练习、修改资料或接收反馈。');
    final afterBrowse = (await tester.runAsync(repo.load))!;
    expect(_editableIds(afterBrowse), {b.id});
    expect(_editableIds(afterBrowse), _snapshotEditable(expired));
    await tester.pageBack();
    await tester.pump();
    await _waitForText(tester, '合成甲');
    debugPrint('T18_STAGE browse_observed');

    // ACTUAL PRODUCT UI: cancel must leave the default untouched and send no
    // selection request.
    await _open(tester, '合成甲');
    await _waitForText(tester, '只读 · 不能用于新练习、修改资料或接收反馈。');
    await _tapText(tester, '改选为可用关系人');
    await _waitForText(tester, '确认改选');
    await _tapText(tester, '取消');
    await _waitForText(tester, '关系人手记');
    final afterCancel = (await tester.runAsync(repo.load))!;
    expect(_editableIds(afterCancel), {b.id});
    debugPrint('T18_STAGE cancel_observed');

    // ACTUAL PRODUCT UI: one explicit confirmation changes the default.
    await _tapText(tester, '改选为可用关系人');
    await _waitForText(tester, '确认改选');
    await _tapText(tester, '确认改选');
    await _waitForText(tester, '编辑资料');
    final afterChoose = (await tester.runAsync(repo.load))!;
    expect(_editableIds(afterChoose), {a.id});
    debugPrint('T18_STAGE choose_observed');

    // FIXTURE: renew the synthetic member interval. Re-entering the page must
    // agree with the Go list readback taken for the same state.
    final renewed = await _advance(tester, origin, secret, 'renew');
    expect(renewed['tier'], 'member');
    expect(_snapshotEditable(renewed), {a.id, b.id});

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pumpWidget(page());
    await _waitForText(tester, '合成甲');
    await _waitForText(tester, '合成乙');
    await _waitUntil(
      tester,
      () => find.text('职场 · 可用').evaluate().length == 2,
      label: 'renewed list',
    );
    final afterRenew = (await tester.runAsync(repo.load))!;
    expect(_editableIds(afterRenew), {a.id, b.id});
    expect(_editableIds(afterRenew), _snapshotEditable(renewed));
    debugPrint('T18_STAGE renew_observed');
    debugPrint('T18_STAGE complete');
  });
}
