import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/providers.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/forms.dart';
import 'package:high_eq/features/contacts/inference.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/contacts/profile.dart';
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/repository.dart';
import 'package:high_eq/features/contacts/routes.dart';
import 'package:high_eq/features/privacy/page.dart';
import 'package:high_eq/features/privacy/store.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';
import 'package:high_eq/features/replies/route.dart';
import 'package:http/http.dart' as http;

import '../../test/isolation_test.dart' show MemorySecret;
import '../t29/loopback_client.dart';
import 'contact_fixture.dart';

const _draft = '合成第1行\n合成第2行\n合成第3行\n合成第4行\n合成第5行\n合成第6行\n合成第7行';
const _contactDraft = '合成关系人片段：对方说周三再确认计划。';
const _switchContactDraft = '合成旧账号关系人草稿：切换前尚未提交。';
const _switchReplyDraft = '合成旧账号回复草稿：切换前尚未分析。';
const _ioTimeout = Duration(seconds: 20);

extension _BoundedRunAsync on WidgetTester {
  Future<T> runAsyncBounded<T>(Future<T> Function() callback) async {
    late T value;
    (Object, StackTrace)? failure;
    // runAsync reports callback failures to Flutter and returns null. Carry
    // the error across the boundary so the caller's awaited step also stops.
    await runAsync(() async {
      try {
        value = await callback().timeout(_ioTimeout);
      } catch (error, stack) {
        failure = (error, stack);
      }
    });
    if (failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
    return value;
  }
}

class _LiveBinding extends LiveTestWidgetsFlutterBinding {
  var _activeStage = 'setup';
  var _reportedFirstException = false;

  @override
  bool get overrideHttpClient => false;

  void stage(String name, String result) {
    _activeStage = name;
    stdout.writeln('D13_FLUTTER_STAGE stage=$name result=$result');
  }

  @override
  void reportExceptionNoticed(FlutterErrorDetails details) {
    if (!_reportedFirstException) {
      _reportedFirstException = true;
      final error = details.exception;
      final status = error is ApiFailure ? error.status : 'other';
      stdout.writeln(
        'D13_FLUTTER_FIRST_EXCEPTION stage=$_activeStage api_status=$status',
      );
    }
    super.reportExceptionNoticed(details);
  }
}

enum _InferenceResponse { pending, httpFailure, invalidBody, safety, profile }

class _ContactSubmissionTrace {
  final exchanges = <({AppOp op, int? status})>[];
  var inference = _InferenceResponse.pending;

  int? start(AppOp op) {
    if (op != AppOp.listConsents &&
        op != AppOp.inferProfile &&
        op != AppOp.listContacts &&
        op != AppOp.getEntitlements) {
      return null;
    }
    exchanges.add((op: op, status: null));
    return exchanges.length - 1;
  }

  void finish(int index, int status, List<int> body) {
    final op = exchanges[index].op;
    exchanges[index] = (op: op, status: status);
    if (op != AppOp.inferProfile) return;
    if (status != 200) {
      inference = _InferenceResponse.httpFailure;
      return;
    }
    inference = _InferenceResponse.invalidBody;
    try {
      final result = jsonDecode(utf8.decode(body));
      if (result is Json) {
        if (result['safety'] == true) {
          inference = _InferenceResponse.safety;
        } else if (result['summary'] is String && result['big_five'] is List) {
          inference = _InferenceResponse.profile;
        }
      }
    } on FormatException {
      // AppApi still receives the original body and enforces its own contract.
    }
  }

  String describe() => exchanges
      .map((entry) => '${entry.op.name}:${entry.status ?? 'pending'}')
      .join(',');
}

class _ReplyProbe implements Transport {
  final _http = HttpTransport(loopbackDirectClient());
  final replyRequestIds = <String>[];
  final replyStatuses = <int>[];
  final profileRequestIds = <String>[];
  final profileStatuses = <int>[];
  _ContactSubmissionTrace? contactSubmission;

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) async {
    final trace = contactSubmission;
    final exchange = trace?.start(op);
    if (op == AppOp.createReply) {
      final input = jsonDecode(request.body) as Json;
      if (input['chat_text'] != _draft) {
        throw StateError('Unexpected test draft');
      }
      replyRequestIds.add(input['request_id'] as String);
    } else if (op == AppOp.inferProfile) {
      final input = jsonDecode(request.body) as Json;
      if (input['chat_text'] != _contactDraft) {
        throw StateError('Unexpected test contact draft');
      }
      profileRequestIds.add(input['request_id'] as String);
    }
    final reply = await _http.send(op, request);
    final body = await reply.stream.toBytes();
    if (op == AppOp.createReply) replyStatuses.add(reply.statusCode);
    if (op == AppOp.inferProfile) profileStatuses.add(reply.statusCode);
    if (exchange != null) trace!.finish(exchange, reply.statusCode, body);
    return http.StreamedResponse(
      Stream.value(body),
      reply.statusCode,
      headers: reply.headers,
    );
  }

  @override
  void close() => _http.close();
}

Future<ApiFailure?> _profileApiFailure(
  Future<ProfileInferenceResult> response,
) async {
  try {
    await response;
    return null;
  } on ApiFailure catch (failure) {
    return failure;
  }
}

Future<void> _waitFor(WidgetTester tester, Finder target) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    await tester.pump(const Duration(milliseconds: 16));
    if (target.evaluate().length == 1) return;
    await tester.runAsyncBounded(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
  }
  expect(target, findsOneWidget);
}

Finder _action(String key, String label) => find.byWidgetPredicate(
  (widget) =>
      widget is FilledButton &&
      widget.key == ValueKey(key) &&
      widget.onPressed != null &&
      (widget.child as Text).data == label,
  description: 'enabled button $label',
);

Future<void> _press(WidgetTester tester, Finder button) async {
  await _waitFor(tester, button);
  await tester.ensureVisible(button);
  await tester.pump();
  final visible = button.hitTestable();
  await _waitFor(tester, visible);
  await tester.tap(visible);
  await tester.pump();
}

Future<void> _tapLabel(WidgetTester tester, String label) async {
  final target = find.text(label).last;
  await _waitFor(tester, target);
  await tester.ensureVisible(target);
  await tester.pump();
  final visible = find.text(label).hitTestable().last;
  await _waitFor(tester, visible);
  await tester.tap(visible);
  await tester.pump();
}

Future<void> _waitForMarker(String dir, String name) async {
  final marker = File('$dir/$name');
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (await marker.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw TimeoutException('Timed out waiting for D13 marker $name');
}

Future<void> _mark(String dir, String name) =>
    File('$dir/$name').writeAsString('1');

void main() {
  final binding = _LiveBinding()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.onlyPumps;
  final stage = binding.stage;
  testWidgets('D13 Flutter → Go: reply lifecycle and contact invalidation', (
    tester,
  ) async {
    stage('setup', 'start');
    final origin = Uri.parse(Platform.environment['D13_REPLY_ORIGIN']!);
    expect(origin.scheme, 'http');
    expect(origin.host, '127.0.0.1');
    final fixtureDir = Platform.environment['D13_REPLY_FIXTURE_DIR']!;
    final tmp = await tester.runAsyncBounded(
      () => Directory.systemTemp.createTemp('d13-reply'),
    );
    addTearDown(() => tmp.delete(recursive: true));
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final probe = await tester.runAsyncBounded(() async => _ReplyProbe());
    addTearDown(probe.close);
    final sessions = Sessions(MemorySecret(), tmp);
    final api = AppApi(origin, probe, sessions);
    final wire = MobileEndpoints(api);
    stage('setup/login', 'start');
    final tokens = await tester.runAsyncBounded(
      () => wire.login(
        body: {
          'credential': {
            'provider': 'apple',
            'proof': Platform.environment['D13_REPLY_TICKET']!,
          },
          'age_confirmed': true,
          'privacy_version': '2026-11',
          'terms_version': '2026-11',
        },
      ),
    );
    stage('setup/login', 'pass');
    stage('setup/activate', 'start');
    final scope = await tester.runAsyncBounded(
      () => sessions.activate(Tokens.fromJson(tokens)),
    );
    stage('setup/activate', 'pass');
    Future<int> remaining() => tester.runAsyncBounded(() async {
      final quota = await ReplyService(api, scope).quota();
      return quota!.remaining!;
    });
    stage('setup/quota', 'start');
    final before = await remaining();
    stage('setup/quota', 'pass');

    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWith((_) => api),
          accountScopeProvider.overrideWithValue(scope),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          home: ReplyRoute(api, scope),
        ),
      ),
    );
    stage('setup', 'pass');
    stage('reply_outage', 'start');
    final approve = _action('reply-accept-import', '同意本次说明');
    final begin = _action('reply-analyze', '开始分析');
    final retry = _action('reply-analyze', '重试原请求');
    await _press(tester, approve);
    final draftField = find
        .byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.enabled == true &&
              widget.decoration?.labelText == '对方说了什么',
        )
        .hitTestable();
    await _waitFor(tester, draftField);
    await tester.enterText(draftField, _draft);
    await tester.pump();
    expect(probe.replyRequestIds, isEmpty);
    await _press(tester, begin);
    await _waitFor(tester, retry);
    final outage = find.text('服务暂不可用，可重试').hitTestable();
    expect(outage, findsOneWidget);
    final original = probe.replyRequestIds.single;
    await _press(tester, retry);
    await _waitFor(tester, retry);
    expect(outage, findsOneWidget);
    expect(probe.replyStatuses, [503, 503]);
    expect(probe.replyRequestIds, [original, original]);
    expect(await remaining(), before);
    stage('reply_outage', 'pass');
    stage('reply_consent_refresh', 'start');

    stage('reply_consent_refresh/revoke', 'start');
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => PrivacyPage(
            PrivacyStore(api, scope),
            onClosureSubmitted: (_) => fail('unexpected closure submission'),
            onClosureUnconfirmed: (_) {},
            onClosureCancelled: () => fail('unexpected closure cancellation'),
            onExit: () => fail('unexpected logout'),
          ),
        ),
      ),
    );
    final privacy = find.byType(PrivacyPage);
    await _waitFor(tester, privacy);
    final list = find
        .descendant(
          of: find.byKey(const Key('privacy-account-list')),
          matching: find.byType(Scrollable),
        )
        .first;
    final withdraw = find.byKey(const ValueKey('withdraw-reply_chat_import'));
    await tester.scrollUntilVisible(find.text('聊天导入授权'), 200, scrollable: list);
    await tester.scrollUntilVisible(withdraw, 180, scrollable: list);
    await _press(tester, withdraw);
    await _waitFor(tester, find.text('已撤回回复助手聊天分析授权。'));
    expect(probe.replyRequestIds, [original, original]);
    navigator.currentState!.pop();
    stage('reply_consent_refresh/revoke', 'pass');
    stage('reply_consent_refresh/ui', 'start');
    await _press(tester, retry);
    await _waitFor(tester, approve);
    expect(
      find.text('本次回复授权已撤回，请重新阅读说明并同意后再分析。').hitTestable(),
      findsOneWidget,
    );
    expect(probe.replyRequestIds, [original, original]);
    await _press(tester, approve);
    await _waitFor(tester, retry);
    expect(probe.replyRequestIds, [original, original]);
    stage('reply_consent_refresh/ui', 'pass');
    stage('reply_consent_refresh', 'pass');
    stage('reply_stale_key', 'start');

    await _press(tester, retry);
    await _waitFor(tester, begin);
    expect(find.text('原请求的授权已失效。草稿已保留，请重新开始分析。').hitTestable(), findsOneWidget);
    expect(find.text(_draft), findsOneWidget);
    expect(probe.replyStatuses, [503, 503, 403]);
    expect(probe.replyRequestIds, [original, original, original]);
    expect(await remaining(), before);
    stage('reply_stale_key', 'pass');
    stage('reply_fresh_key', 'start');

    await _press(tester, begin);
    await _waitFor(tester, find.text('先理解对方'));
    expect(probe.replyStatuses, [503, 503, 403, 200]);
    final fresh = probe.replyRequestIds.last;
    expect(fresh, isNot(original));
    expect(await remaining(), before - 1);
    stage('reply_fresh_key', 'pass');
    stage('reply_replay', 'start');

    final replayed = await tester.runAsyncBounded(
      () => ReplyService(
        api,
        scope,
      ).analyze({'request_id': fresh, 'chat_text': _draft}),
    );
    expect(replayed, isA<Approved>());
    expect(probe.replyStatuses, [503, 503, 403, 200, 200]);
    expect(probe.replyRequestIds, [original, original, original, fresh, fresh]);
    expect(await remaining(), before - 1);
    stage('reply_replay', 'pass');
    stage('contact_setup', 'start');

    stage('contact_setup/create', 'start');
    final contactId = await tester.runAsyncBounded(
      () => createFixtureContact(wire, scope),
    );
    stage('contact_setup/create', 'pass');
    final contacts = ApiContacts(wire, scope);

    stage('contact_setup/replace_view', 'start');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWith((_) => api),
          accountScopeProvider.overrideWithValue(scope),
        ],
        child: const MaterialApp(home: ContactRoute(sceneOnly: false)),
      ),
    );
    final contactRow = find.byKey(ValueKey('contact-list-row:$contactId'));
    await _waitFor(tester, contactRow);
    await tester.ensureVisible(contactRow);
    await tester.pump();
    await tester.tap(contactRow);
    await tester.pump();
    stage('contact_setup/replace_view', 'pass');
    stage('contact_setup/first_grant', 'start');
    await _tapLabel(tester, '导入聊天片段');
    await _waitFor(tester, find.text('允许使用聊天片段推断画像？'));
    expect(probe.profileRequestIds, isEmpty);
    expect(probe.profileStatuses, isEmpty);

    await _tapLabel(tester, '同意并继续');
    await _waitFor(tester, find.text('我已了解，并有权分享这段内容'));
    expect(probe.profileRequestIds, isEmpty);
    stage('contact_setup/first_grant', 'pass');
    stage('contact_setup', 'pass');
    stage('contact_stale_key', 'start');

    final oldContactKey = newRequestId();
    final staleFlow = await tester.runAsyncBounded(() async {
      final staleAuthorization =
          (await contacts.currentConsents()).inferenceGrant!;
      stage('contact_stale_key/in_flight', 'start');
      // The service can finish as soon as the release marker becomes visible,
      // before the asynchronous marker write returns to this test.
      final inFlight = _profileApiFailure(
        contacts.infer(
          contactId,
          oldContactKey,
          _contactDraft,
          authorization: staleAuthorization,
        ),
      );
      await _waitForMarker(fixtureDir, 'profile-started');
      stage('contact_stale_key/in_flight', 'pass');
      stage('contact_stale_key/revoke', 'start');
      await wire.setConsent(
        scope: scope,
        purpose: ContactPurpose.chatImport.wire,
        body: {'version': contactNoticeVersion, 'granted': false},
      );
      await expectLater(
        contacts.infer(
          contactId,
          oldContactKey,
          _contactDraft,
          authorization: staleAuthorization,
        ),
        throwsA(isA<ContactConsentChanged>()),
      );
      expect(probe.profileRequestIds, [oldContactKey]);
      stage('contact_stale_key/revoke', 'pass');
      stage('contact_stale_key/release', 'start');
      await _mark(fixtureDir, 'profile-release');
      expect((await inFlight)?.status, 409);
      stage('contact_stale_key/release', 'pass');
      stage('contact_stale_key/regrant', 'start');
      await wire.setConsent(
        scope: scope,
        purpose: ContactPurpose.chatImport.wire,
        body: {'version': contactNoticeVersion, 'granted': true},
      );
      final replacementAuthorization =
          (await contacts.currentConsents()).inferenceGrant!;
      final replay = await _profileApiFailure(
        contacts.infer(
          contactId,
          oldContactKey,
          _contactDraft,
          authorization: replacementAuthorization,
        ),
      );
      expect(replay?.status, 409);
      stage('contact_stale_key/regrant', 'pass');
      return true;
    });
    expect(staleFlow, isTrue);
    expect(probe.profileStatuses, [409, 409]);
    expect(probe.profileRequestIds, [oldContactKey, oldContactKey]);
    stage('contact_stale_key', 'pass');
    stage('contact_fresh_key', 'start');

    final detail = find.byType(ProfileView);
    final success = find.text('画像已更新，仅供参考。', skipOffstage: false);
    final staleTrace = _ContactSubmissionTrace();
    probe.contactSubmission = staleTrace;
    await _tapLabel(tester, '我已了解，并有权分享这段内容');
    final contactField = find.descendant(
      of: find.byType(ChatForm),
      matching: find.byType(TextField),
    );
    await _waitFor(tester, contactField);
    await tester.ensureVisible(contactField);
    await tester.pump();
    await _waitFor(tester, contactField.hitTestable());
    await tester.enterText(contactField.hitTestable(), _contactDraft);
    await tester.pump();
    expect(probe.profileRequestIds.length, 2);
    await _press(
      tester,
      find.ancestor(
        of: find.text('提交片段'),
        matching: find.byWidgetPredicate(
          (widget) => widget is FilledButton && widget.onPressed != null,
          description: 'enabled contact submit action',
        ),
      ),
    );

    final staleNotice = find.text('授权记录已变化，已清除旧片段，请重新导入。', skipOffstage: false);
    await _waitFor(tester, staleNotice);
    await tester.ensureVisible(staleNotice);
    await tester.pump();
    await _waitFor(tester, staleNotice.hitTestable());
    await _waitFor(tester, detail);
    expect(probe.profileStatuses, [409, 409]);
    expect(staleTrace.inference, _InferenceResponse.pending);
    expect(staleTrace.exchanges, [(op: AppOp.listConsents, status: 200)]);
    expect(staleNotice.hitTestable(), findsOneWidget);
    expect(find.text(_contactDraft), findsNothing);
    expect(tester.widget<ProfileView>(detail).contact.id == contactId, isTrue);
    probe.contactSubmission = null;

    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 568);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pump();

    final freshTrace = _ContactSubmissionTrace();
    probe.contactSubmission = freshTrace;
    await _tapLabel(tester, '导入聊天片段');
    await _waitFor(tester, find.byType(ChatForm));
    expect(probe.profileRequestIds.length, 2);
    await _tapLabel(tester, '我已了解，并有权分享这段内容');
    final freshContactField = find.descendant(
      of: find.byType(ChatForm),
      matching: find.byType(TextField),
    );
    await _waitFor(tester, freshContactField);
    await tester.ensureVisible(freshContactField);
    await tester.pump();
    await _waitFor(tester, freshContactField.hitTestable());
    await tester.enterText(freshContactField.hitTestable(), _contactDraft);
    await tester.pump();
    expect(probe.profileRequestIds.length, 2);
    await _press(
      tester,
      find.ancestor(
        of: find.text('提交片段'),
        matching: find.byWidgetPredicate(
          (widget) => widget is FilledButton && widget.onPressed != null,
          description: 'enabled contact submit action',
        ),
      ),
    );

    await _waitFor(tester, detail);
    debugPrintSynchronously(
      'D13_REPAIR_FRESH response=${freshTrace.inference.name} '
      'exchanges=${freshTrace.describe()} '
      'notice_mounted=${success.evaluate().length} '
      'notice_visible=${success.hitTestable().evaluate().length}',
    );
    // The return from import must show the result without another swipe.
    await _waitFor(tester, success.hitTestable());
    expect(success, findsOneWidget);
    expect(probe.profileStatuses, [409, 409, 200]);
    expect(probe.profileRequestIds.length, 3);
    expect(probe.profileRequestIds.last == oldContactKey, isFalse);
    expect(freshTrace.inference, _InferenceResponse.profile);
    expect(freshTrace.exchanges, [
      (op: AppOp.listConsents, status: 200),
      (op: AppOp.listConsents, status: 200),
      (op: AppOp.listConsents, status: 200),
      (op: AppOp.inferProfile, status: 200),
      (op: AppOp.listConsents, status: 200),
    ]);
    expect(tester.widget<ProfileView>(detail).contact.id == contactId, isTrue);
    expect(
      find.descendant(of: detail, matching: find.text('可能的倾向：愿意试试新办法')),
      findsOneWidget,
    );
    probe.contactSubmission = null;
    stage('contact_fresh_key', 'pass');

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();
    stage('account_switch', 'start');

    await _tapLabel(tester, '导入聊天片段');
    await _waitFor(tester, find.byType(ChatForm));
    await _tapLabel(tester, '我已了解，并有权分享这段内容');
    final switchContactField = find.descendant(
      of: find.byType(ChatForm),
      matching: find.byType(TextField),
    );
    await _waitFor(tester, switchContactField);
    await tester.ensureVisible(switchContactField);
    await tester.pump();
    await _waitFor(tester, switchContactField.hitTestable());
    await tester.enterText(
      switchContactField.hitTestable(),
      _switchContactDraft,
    );
    await tester.pump();
    expect(find.text(_switchContactDraft), findsOneWidget);

    final contactContext = tester.element(find.byType(ContactRoute));
    unawaited(
      Navigator.of(
        contactContext,
      ).push<void>(MaterialPageRoute(builder: (_) => ReplyRoute(api, scope))),
    );
    final replyDraftField = find
        .byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.enabled == true &&
              widget.decoration?.labelText == '对方说了什么',
        )
        .hitTestable();
    await _waitFor(tester, replyDraftField);
    await tester.enterText(replyDraftField, _switchReplyDraft);
    await tester.pump();
    expect(find.text(_switchReplyDraft), findsOneWidget);
    final switchReplyRequests = probe.replyRequestIds.length;
    expect(switchReplyRequests, 5);

    final logout = tester.runAsyncBounded(() => api.logout(scope));
    await tester.pump();
    await logout;
    expect(sessions.active, isNull);
    final switchTokens = await tester.runAsyncBounded(
      () => wire.login(
        body: {
          'credential': {
            'provider': 'apple',
            'proof': Platform.environment['D13_REPLY_SWITCH_TICKET']!,
          },
          'age_confirmed': true,
          'privacy_version': '2026-11',
          'terms_version': '2026-11',
        },
      ),
    );
    final scopeB = await tester.runAsyncBounded(
      () => sessions.activate(Tokens.fromJson(switchTokens)),
    );
    expect(scopeB.account == scope.account, isFalse);

    await tester.pumpWidget(
      ProviderScope(
        key: ObjectKey(scopeB),
        overrides: [
          apiProvider.overrideWith((_) => api),
          accountScopeProvider.overrideWithValue(scopeB),
        ],
        child: const MaterialApp(home: ContactRoute(sceneOnly: false)),
      ),
    );
    await _waitFor(tester, find.text('还没有关系人。从一个常交流的人开始吧。'));
    expect(find.text(_switchContactDraft), findsNothing);
    expect(find.text(_switchReplyDraft), findsNothing);
    expect(find.text('可能的倾向：愿意试试新办法'), findsNothing);
    expect(find.byKey(ValueKey('contact-list-row:$contactId')), findsNothing);

    await tester.pumpWidget(
      ProviderScope(
        key: ObjectKey(scopeB),
        overrides: [
          apiProvider.overrideWith((_) => api),
          accountScopeProvider.overrideWithValue(scopeB),
        ],
        child: MaterialApp(home: ReplyRoute(api, scopeB)),
      ),
    );
    final switchedReplyField = find
        .byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '对方说了什么',
        )
        .hitTestable();
    await _waitFor(tester, switchedReplyField);
    expect(
      tester.widget<TextField>(switchedReplyField).controller?.text,
      isEmpty,
    );
    expect(find.text(_switchReplyDraft), findsNothing);
    expect(find.text(_switchContactDraft), findsNothing);
    expect(find.text('我周三发计划。'), findsNothing);
    expect(probe.replyRequestIds.length, switchReplyRequests);
    expect(probe.profileStatuses, [409, 409, 200]);
    stage('account_switch', 'pass');
    stage('test', 'pass');
  });
}
