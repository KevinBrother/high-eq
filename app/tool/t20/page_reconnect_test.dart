import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/routes.dart';
import 'package:high_eq/features/contacts/scene.dart';
import 'package:high_eq/features/growth/practice_home.dart';
import 'package:high_eq/features/growth/practice_home_actions.dart';
import 'package:high_eq/features/growth/repository.dart';
import 'package:high_eq/features/home/shell.dart';
import 'package:high_eq/features/practice/chat.dart';
import 'package:high_eq/features/practice/lobby.dart';
import 'package:high_eq/features/practice/providers.dart';
import 'package:high_eq/features/practice/repository.dart';
import 'package:http/http.dart' as http;

class _VolatileSecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? next) async => value = next;
}

// The real product routes run against the Go test's loopback service. Only
// that socket may be dialled from the card sandbox.
class _T20LiveBinding extends LiveTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

// A production Transport whose POST /messages carries an abort trigger. The
// test can therefore hang up its own SSE connection precisely, without a
// proxy, a fault endpoint, or a second account. Every response is still parsed
// by the product's own AppApi/decodeReply code.
class _AbortableTransport implements Transport {
  _AbortableTransport(this._client);
  final http.Client _client;
  final _abort = Completer<void>();
  final sent = <String>[];
  final readSessions = <String>[];
  final created = <String>[];

  void disconnect() {
    if (!_abort.isCompleted) _abort.complete();
  }

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) {
    final path = request.url.path;
    if (op == AppOp.sendMessage) {
      sent.add(path);
      final next = http.AbortableRequest(
        request.method,
        request.url,
        abortTrigger: _abort.future,
      )
        ..followRedirects = request.followRedirects
        ..maxRedirects = request.maxRedirects
        ..persistentConnection = request.persistentConnection
        ..headers.addAll(request.headers)
        ..bodyBytes = request.bodyBytes;
      return _client.send(next);
    }
    if (op == AppOp.getSession) readSessions.add(path);
    if (op == AppOp.createSession) created.add(path);
    return _client.send(request);
  }

  @override
  void close() => _client.close();
}

const _networkLimit = Duration(seconds: 60);
const _fragment = '合成甲。';
const _savedReply = '合成甲。合成乙。';

File? _phaseFile;

void _markPhase(String phase) {
  final file = _phaseFile;
  if (file != null) file.writeAsStringSync(phase, flush: true);
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready, {
  required String label,
}) async {
  _markPhase(label);
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < _networkLimit) {
    await tester.pump(const Duration(milliseconds: 20));
    if (ready()) return;
  }
  await tester.pump();
  final home = find.byType(PracticeHomePage).evaluate().length;
  final lobby = find.byType(PracticeLobby).evaluate().length;
  final chat = find.byType(PracticeChat).evaluate().length;
  final fields = find.byType(TextField).evaluate().length;
  _markPhase(
    'timeout: $label home=$home lobby=$lobby chat=$chat '
    'fields=$fields texts=${find.byType(Text).evaluate().length}',
  );
  fail('Timed out waiting for $label. No URL, token or message text is logged.');
}

Future<void> _waitForText(
  WidgetTester tester,
  String text, {
  required String stage,
}) => _waitUntil(
  tester,
  () => find.text(text).evaluate().isNotEmpty,
  label: stage,
);

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  final found = target.evaluate();
  if (found.isEmpty) {
    _markPhase('tap: target not built');
    fail('the target widget is not built');
  }
  await Scrollable.ensureVisible(found.first, alignment: 0.5);
  await tester.pump();
  await tester.pump();
  if (target.hitTestable().evaluate().isEmpty) {
    _markPhase('tap: target not hit-testable');
    fail('the target widget is covered or outside the viewport');
  }
  await tester.tap(target.last);
  await tester.pump();
  _markPhase('tap: sent');
}

// Observable transition state: the pushed page's route animation is done.
Future<void> _waitForRouteSettled(WidgetTester tester, Finder page) async {
  await _waitUntil(
    tester,
    () {
      final elements = page.evaluate();
      if (elements.isEmpty) return false;
      final route = ModalRoute.of(elements.first);
      final animation = route?.animation;
      return route != null && (animation == null || animation.isCompleted);
    },
    label: '${page.describeMatch(Plurality.many)} route transition',
  );
}

Finder _menuScroll() => find
    .descendant(of: find.byType(HomeShell), matching: find.byType(Scrollable))
    .first;

Finder _lobbyScroll() => find
    .descendant(
      of: find.byType(PracticeLobby),
      matching: find.byType(Scrollable),
    )
    .first;

Map<String, Object> _renderedText(WidgetTester tester, Finder target) {
  final rect = tester.getRect(target.first);
  final screen = Offset.zero &
      (tester.view.physicalSize / tester.view.devicePixelRatio);
  final inside =
      rect.width > 0 &&
      rect.height > 0 &&
      rect.left >= screen.left &&
      rect.top >= screen.top &&
      rect.right <= screen.right &&
      rect.bottom <= screen.bottom;
  final hit = target.hitTestable().evaluate().isNotEmpty;
  return {
    'text': tester.widget<Text>(target.first).data!,
    'left': rect.left,
    'top': rect.top,
    'right': rect.right,
    'bottom': rect.bottom,
    'inside_viewport': inside,
    'hit_testable': hit,
  };
}

void main() {
  _T20LiveBinding().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;

  testWidgets('正式对练页断流后恢复同一会话并取回已保存回复', (tester) async {
    final environment = Platform.environment;
    final rawOrigin = environment['T20_ORIGIN'];
    final rawTokens = environment['T20_TOKENS'];
    final rawUserText = environment['T20_USER_TEXT'];
    final rawReceipt = environment['T20_RECEIPT'];
    final rawAborted = environment['T20_ABORTED'];
    final rawPhase = environment['T20_PHASE'];
    expect(rawOrigin, isNotNull);
    expect(rawTokens, isNotNull);
    expect(rawUserText, isNotNull);
    expect(rawReceipt, isNotNull);
    expect(rawAborted, isNotNull);
    expect(rawPhase, isNotNull);
    final userText = rawUserText!;
    final receiptPath = rawReceipt!;
    final abortedPath = rawAborted!;
    _phaseFile = File(rawPhase!);
    final origin = Uri.parse(rawOrigin!);
    expect(origin.scheme, 'http');
    expect(origin.host, '127.0.0.1');
    expect(origin.hasPort, isTrue);

    final directory = await Directory.systemTemp.createTemp('t20-reconnect-');
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final transport = _AbortableTransport(http.Client());
    addTearDown(transport.close);
    final sessions = Sessions(_VolatileSecret(), directory);
    final tokens = Tokens.fromJson(
      jsonDecode(rawTokens!) as Map<String, dynamic>,
    );
    final activated = await tester.runAsync(() => sessions.activate(tokens));
    final scope = activated!;
    final api = AppApi(origin, transport, sessions);
    final practice = ApiPractice(api, scope);
    final growth = ApiGrowthRepository(api, scope);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          practiceRepositoryProvider.overrideWithValue(practice),
          growthRepositoryProvider.overrideWithValue(growth),
          contactSpaceProvider.overrideWithValue((
            scene: SceneMemory(),
            repo: null,
            demo: false,
          )),
        ],
        child: MaterialApp(
          initialRoute: '/practice',
          routes: {
            '/practice': (_) => const PracticeHomeRoute(),
            '/training': (_) => const PracticeRoute(),
          },
        ),
      ),
    );

    // REAL HOME: the product practice home pushes its own /training route.
    final entry = find.descendant(
      of: find.byType(PracticeContinueActions),
      matching: find.text('对练与预演'),
    );
    await _waitUntil(
      tester,
      () => find.byType(PracticeHomePage).evaluate().isNotEmpty,
      label: 'the real practice home page',
    );
    await _waitForRouteSettled(tester, find.byType(PracticeHomePage));
    await tester.scrollUntilVisible(entry, 300, scrollable: _menuScroll());
    await _tapVisible(tester, entry);
    await _waitForText(tester, '选一个练习场景', stage: 'the lobby scenario list');
    await _waitForRouteSettled(tester, find.byType(PracticeLobby));

    // The lobby creates the one synthetic practice through its real UI. The
    // account already holds the practice consent granted by the Go fixture.
    final scenario = find.byType(TextField);
    await tester.scrollUntilVisible(
      scenario,
      300,
      scrollable: _lobbyScroll(),
    );
    await tester.enterText(scenario, '合成重连预演');
    await tester.pump();
    final start = find.text('开始预演');
    await _waitUntil(
      tester,
      () {
        final button = find.ancestor(
          of: start,
          matching: find.byType(FilledButton),
        );
        return button.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(button.first).onPressed != null;
      },
      label: 'the enabled start button',
    );
    await _tapVisible(tester, start);

    await _waitUntil(
      tester,
      () => find.byType(PracticeChat).evaluate().isNotEmpty,
      label: 'the practice chat page',
    );
    await _waitForRouteSettled(tester, find.byType(PracticeChat));
    final composer = find.byType(TextField);
    await _waitUntil(
      tester,
      () =>
          composer.evaluate().isNotEmpty &&
          tester.widget<TextField>(composer.first).enabled == true,
      label: 'the chat composer',
    );
    final chat = tester.widget<PracticeChat>(find.byType(PracticeChat));
    final sessionId = chat.initial['session_id'] as String;
    expect(transport.created, hasLength(1));
    expect(transport.created.single, '/v1/sessions');

    // One ordinary user turn, submitted by the real composer.
    await tester.enterText(composer.first, userText);
    await tester.pump();
    final send = find.byTooltip('发送');
    await _waitUntil(
      tester,
      () => send.evaluate().isNotEmpty,
      label: 'the send button',
    );
    await _tapVisible(tester, send);

    // The server has streamed the first fragment but has not persisted or
    // acknowledged the reply: the fixture holds the provider after this chunk.
    await _waitForText(tester, _fragment, stage: 'the first streamed fragment');
    const fragmentVisible = true;
    expect(
      find.text(_savedReply).evaluate().isEmpty,
      isTrue,
      reason: 'the saved reply appeared before the disconnect',
    );

    // The test client itself hangs up its SSE connection before reply_saved
    // can be delivered to the page.
    transport.disconnect();
    await _waitForText(tester, '连接中断，请恢复原会话。', stage: 'the disconnect notice');
    // Tell the scripted provider it may finish now; the page has already
    // witnessed the closed stream and cannot receive reply_saved.
    File(abortedPath).writeAsStringSync('aborted', flush: true);
    await _waitForText(tester, '恢复会话', stage: 'the recovery action');
    final noticeVisible = find.text('连接中断，请恢复原会话。').evaluate().isNotEmpty;
    final recoveryButtonBefore = find.text('恢复会话').evaluate().isNotEmpty;
    final assistantBeforeRecovery = find.text(_savedReply).evaluate().isNotEmpty;
    expect(assistantBeforeRecovery, isFalse);
    expect(transport.sent, hasLength(1));

    // Wait for the detached server worker to finish saving, then recover via
    // the page's own "恢复会话" button. This poll is test-only pacing; the
    // visible recovery below is the product request path.
    final saved = await _waitForSavedReply(tester, practice, sessionId);
    expect(saved['session_id'], sessionId);
    expect(
      find.text(_savedReply).evaluate().isEmpty,
      isTrue,
      reason: 'the saved reply was visible before the recovery action',
    );

    await _tapVisible(tester, find.text('恢复会话'));
    await _waitForText(tester, _savedReply, stage: 'the saved reply after recovery');
    await _waitUntil(
      tester,
      () => find.text('恢复会话').evaluate().isEmpty,
      label: 'the recovery button to close',
    );

    final userFinder = find.text(userText);
    final assistantFinder = find.text(_savedReply);
    expect(userFinder.evaluate().length, 1, reason: 'rendered user row count');
    expect(
      assistantFinder.evaluate().length,
      1,
      reason: 'rendered assistant row count',
    );
    await tester.ensureVisible(userFinder);
    await tester.pump();
    final userRendered = _renderedText(tester, userFinder);
    await tester.ensureVisible(assistantFinder);
    await tester.pump();
    final assistantRendered = _renderedText(tester, assistantFinder);
    expect(userRendered['inside_viewport'], isTrue);
    expect(assistantRendered['inside_viewport'], isTrue);
    expect(userRendered['hit_testable'], isTrue);
    expect(assistantRendered['hit_testable'], isTrue);
    await _waitForText(tester, '本场净扣 1 次', stage: 'the settlement line');

    final input = find.byType(TextField);
    expect(input.evaluate(), isNotEmpty);
    expect(tester.widget<TextField>(input.first).enabled, isTrue);
    final retryVisible = find.text('重试原发言').evaluate().isNotEmpty;
    expect(retryVisible, isFalse);
    expect(transport.sent, hasLength(1));
    expect(transport.created, hasLength(1));
    expect(
      transport.readSessions.every(
        (path) => path == '/v1/sessions/$sessionId',
      ),
      isTrue,
    );

    File(receiptPath).writeAsStringSync(
      jsonEncode({
        'session_id': sessionId,
        'user_text': userText,
        'assistant_text': _savedReply,
        'fragment_visible_before_abort': fragmentVisible,
        'aborted_marker': File(abortedPath).existsSync(),
        'notice_visible': noticeVisible,
        'recovery_button_before': recoveryButtonBefore,
        'assistant_before_recovery': assistantBeforeRecovery,
        'recovered': true,
        'user_rows_after': userFinder.evaluate().length,
        'assistant_rows_after': assistantFinder.evaluate().length,
        'input_enabled_after':
            tester.widget<TextField>(input.first).enabled == true,
        'retry_visible_after': retryVisible,
        'settlement_label': '本场净扣 1 次',
        'message_posts': transport.sent.length,
        'sent_paths': transport.sent,
        'create_posts': transport.created.length,
        'create_paths': transport.created,
        'session_gets': transport.readSessions,
        'user_rendered': userRendered,
        'assistant_rendered': assistantRendered,
      }),
      flush: true,
    );
  });
}

Future<Json> _waitForSavedReply(
  WidgetTester tester,
  PracticeRepository practice,
  String sessionId,
) async {
  _markPhase('waiting for the saved reply');
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  var messageCount = 0;
  var assistantRows = 0;
  while (DateTime.now().isBefore(deadline)) {
    final detail = await tester.runAsync(() => practice.get(sessionId));
    if (detail == null) fail('the saved session detail was null');
    final rows = (detail['messages'] as List).cast<Json>();
    messageCount = rows.length;
    assistantRows = rows.where((row) => row['role'] == 'assistant').length;
    if (assistantRows > 0) return detail;
    await tester.pump(const Duration(milliseconds: 250));
  }
  _markPhase('timeout: waiting for the saved reply');
  fail(
    'Timed out waiting for the server to save the reply; '
    'messages=$messageCount assistant_rows=$assistantRows',
  );
}
