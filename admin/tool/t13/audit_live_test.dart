import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq_admin/core/api.dart';
import 'package:high_eq_admin/features/workspace/shell.dart';
import 'package:http/http.dart' as http;

// T13: the shipped /audit page runs against the disposable Go service over
// real loopback HTTP. It enters one operator UUID, selects one local calendar
// day through the date range picker (calendar -> text input), presses "查询",
// and writes each visible result Card's three fields plus the audit GET
// boundary around the click. The Go parent compares every rendered row field
// with the synthetic admin_audit_logs rows PG returned for the request the
// click actually produced. No browser, account or real log.
void main() {
  testWidgets('T13 /audit page filters one actor and one local day over HTTP', (
    tester,
  ) async {
    HttpOverrides.global = null;
    final env = Platform.environment;
    final origin = Uri.parse(env['T13_ADMIN_ORIGIN']!);
    final token = env['T13_ADMIN_TOKEN']!;
    final actor = env['T13_ACTOR_ID']!;
    final day = env['T13_DAY']!;
    final receipt = env['T13_RECEIPT']!;
    final parts = day.split('-').map(int.parse).toList();
    String two(int v) => v.toString().padLeft(2, '0');
    final dayText =
        '${parts[0].toString().padLeft(4, '0')}/${two(parts[1])}/${two(parts[2])}';

    final client = _RecordingClient();
    final api = AdminApi(client, origin);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Workspace(
            path: '/audit',
            session: Session(
              token,
              'super_admin',
              DateTime.now().add(const Duration(hours: 1)),
            ),
          ),
        ),
      ),
    );

    await _until(tester, find.text('操作审计'), 'audit page load');
    for (var i = 0; i < 800; i++) {
      if (_loading.evaluate().isEmpty) break;
      if (i == 799) {
        fail(
          'T13 /audit did not finish its initial read; '
          'visible=${_visibleTexts(tester)}',
        );
      }
      await _tick(tester);
    }

    await tester.enterText(find.byType(TextFormField), actor);
    await tester.pump();

    await tester.tap(find.text('选择日期范围'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('切换到输入模式'));
    await tester.pumpAndSettle();

    final start = find.widgetWithText(TextField, '开始日期');
    final end = find.widgetWithText(TextField, '结束日期');
    if (start.evaluate().length != 1 || end.evaluate().length != 1) {
      fail(
        'T13 date range input fields missing; visible=${_visibleTexts(tester)}',
      );
    }
    await tester.enterText(start, dayText);
    await tester.enterText(end, dayText);
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // Selecting a range only stores it. Before the click there must be exactly
    // the page's single initialization GET, with no selected filters at all.
    final query = find.text('查询');
    await tester.ensureVisible(query);
    await tester.pump();
    final before = client.auditQueries.sublist(0);
    if (before.length != 1) {
      fail(
        'T13 /audit made ${before.length} audit GETs before "查询"; '
        'want only the initialization GET: $before',
      );
    }
    final initial = Uri.splitQueryString(before.single);
    for (final key in ['actor_id', 'from', 'until']) {
      if (initial.containsKey(key)) {
        fail('T13 initialization GET already carried $key: ${before.single}');
      }
    }

    // Attribute the filtered request to the query button's own gesture
    // release. The fake clock does not advance and we do not pump between
    // pointer up and reading the recorder, so a delayed date-confirm task
    // cannot explain the increment.
    final clickIndex = before.length;
    final gesture = await tester.startGesture(tester.getCenter(query));
    await gesture.up();
    final release = client.auditQueries.sublist(clickIndex);
    if (release.length != 1) {
      fail(
        'T13 query button release produced ${release.length} audit GETs, '
        'want 1: $release',
      );
    }

    List<List<String>> rows = const [];
    for (var i = 0; i < 800; i++) {
      rows = _visibleRowFields(tester);
      if (rows.length == 1 && _loading.evaluate().isEmpty) break;
      if (i == 799) {
        fail(
          'T13 /audit did not settle on one filtered row; '
          'rows=$rows visible=${_visibleTexts(tester)}',
        );
      }
      await _tick(tester);
    }

    final after = client.auditQueries.sublist(clickIndex);
    if (after.length != 1 || after.single != release.single) {
      fail(
        'T13 query window produced ${after.length} audit GETs: $after; '
        'release produced: $release',
      );
    }
    final click = Uri.splitQueryString(after.single);
    if (click['actor_id'] != actor ||
        !click.containsKey('from') ||
        !click.containsKey('until')) {
      fail('T13 query button release did not carry the selected filters: $click');
    }
    File(receipt).writeAsStringSync(
      jsonEncode({
        'rows': [
          for (final row in rows)
            {'title': row[0], 'time': row[1], 'selection': row[2]},
        ],
        'audit_gets_before_click': before,
        'audit_gets_during_click_release': release,
        'audit_gets_after_click': after,
      }),
    );

    // Close the real client so its keep-alive timer does not outlive the fake
    // clock, then drain the page's own animations.
    api.client.close();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  });
}

// Counts the real audit GETs and records their query strings in order.
// Byte-for-byte values let the Go parent match these against the service's
// own request log instead of assuming "the last request of the whole run".
class _RecordingClient extends http.BaseClient {
  final _inner = http.Client();
  final auditQueries = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method == 'GET' &&
        request.url.path == '/admin/v1/audit-logs') {
      auditQueries.add(request.url.query);
    }
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}

final _loading = find.byWidgetPredicate(
  (widget) => widget is LinearProgressIndicator && widget.value == null,
);
final _title = RegExp(r'^(成功|拒绝|失败)  ·  .+$');
final _time = RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$');

// Each shipped result row is one Card holding exactly three visible fields in
// order: result/action, local time, and actor/target. Collect per card so an
// extra visible row changes the row count instead of hiding in a whole-tree
// text match.
List<List<String>> _visibleRowFields(WidgetTester tester) {
  final rows = <List<String>>[];
  for (final element in find.byType(Card).evaluate()) {
    final texts = _subtreeTexts(element);
    if (texts.length != 3 ||
        !_title.hasMatch(texts[0]) ||
        !_time.hasMatch(texts[1]) ||
        !texts[2].startsWith('操作人：')) {
      fail('T13 /audit found a result card with unexpected fields: $texts');
    }
    rows.add(texts);
  }
  return rows;
}

List<String> _subtreeTexts(Element element) {
  final texts = <String>[];
  void visit(Element e) {
    final widget = e.widget;
    if (widget is Text) {
      final data = widget.data;
      if (data != null && data.isNotEmpty) texts.add(data);
      return;
    }
    if (widget is SelectableText) {
      final data = widget.data;
      if (data != null && data.isNotEmpty) texts.add(data);
      return;
    }
    e.visitChildElements(visit);
  }

  element.visitChildElements(visit);
  return texts;
}

List<String> _visibleTexts(WidgetTester tester) {
  final texts = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final data = (element.widget as Text).data;
    if (data != null && data.isNotEmpty) texts.add(data);
  }
  for (final element in find.byType(SelectableText).evaluate()) {
    final data = (element.widget as SelectableText).data;
    if (data != null && data.isNotEmpty) texts.add(data);
  }
  return texts;
}

// Pump while giving real sockets a turn on the real event loop. Widget tests
// otherwise run in fake async, where an HTTP response never arrives.
Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 25)),
  );
  await tester.pump(const Duration(milliseconds: 25));
}

Future<void> _until(WidgetTester tester, Finder finder, String label) async {
  for (var i = 0; i < 800; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await _tick(tester);
  }
  fail('T13 /audit timed out waiting for $label; visible=${_visibleTexts(tester)}');
}
