import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/replies/page.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

class Fixture implements ReplyRepository {
  final calls = <Json>[];
  final ratings =
      <({String id, int index, String outcome, String? selfReport})>[];
  var consent = false;
  var available = <Contact>[];
  var consentChecks = 0;
  Object? allowedFailure;
  Future<bool>? pendingAllowed;
  ReplyQuota? quotaValue;
  Object? quotaFailure;
  Object? feedbackFailure;
  Object? contactsFailure;
  var contactLoads = 0;
  Future<ReplyResult> Function(Json)? analyzeWith;
  late Completer<ReplyResult> response;
  @override
  Future<bool> allowed() async {
    consentChecks++;
    if (allowedFailure != null) throw allowedFailure!;
    final pending = pendingAllowed;
    return pending == null ? consent : await pending;
  }

  @override
  Future<String?> replyConsentId() async =>
      await allowed() ? 'fixture-reply' : null;

  @override
  Future<ReplyContactAccess> contactAccess() async => (
    consentId: 'fixture-contact',
    people: await contacts(verifyConsent: true),
  );

  @override
  Future<void> grant() async {
    consent = true;
  }

  @override
  Future<List<Contact>> contacts({bool verifyConsent = false}) async {
    contactLoads++;
    if (contactsFailure != null) throw contactsFailure!;
    return List.of(available);
  }

  @override
  Future<ReplyQuota?> quota() async {
    if (quotaFailure != null) throw quotaFailure!;
    return quotaValue;
  }

  @override
  Future<ReplyResult> analyze(
    Json input, {
    ReplyAuthorization? authorization,
    void Function()? checkBeforeSend,
  }) {
    checkBeforeSend?.call();
    calls.add(input);
    final delegate = analyzeWith;
    if (delegate != null) return delegate(input);
    response = Completer();
    return response.future;
  }

  @override
  Future<void> feedback(
    String id,
    int index,
    String outcome, [
    String? selfReport,
  ]) async {
    if (feedbackFailure != null) throw feedbackFailure!;
    ratings.add((
      id: id,
      index: index,
      outcome: outcome,
      selfReport: selfReport,
    ));
  }
}

Contact person(String id, String name) => Contact.fromJson({
  'id': id,
  'nickname': name,
  'scene': 'work',
  'editable': true,
  'profile': <String, Object?>{},
});

Future<void> tap(WidgetTester t, String label) async {
  final f = find.text(label);
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump();
}

Future<void> tapKey(WidgetTester t, String key) async {
  final f = find.byKey(ValueKey(key));
  expect(f, findsOneWidget);
  await t.ensureVisible(f);
  await t.tap(f);
  await t.pump();
}

Future<ReplyService> wireReply(Handler wire) async {
  final dir = await Directory.systemTemp.createTemp();
  addTearDown(() => dir.delete(recursive: true));
  final sessions = Sessions(MemorySecret(), dir);
  final scope = await sessions.activate(tokens('fixture'));
  return ReplyService(
    AppApi(Uri.https('offline.invalid'), wire, sessions),
    scope,
  );
}

class _ConsentWire extends Handler {
  _ConsentWire() {
    handle = (op, request) async {
      switch (op) {
        case AppOp.listConsents:
          checks++;
          expect(request.body, isEmpty);
          await pendingCheck?.future;
          return response({
            'items': [decision],
            'next_cursor': null,
          });
        case AppOp.setConsent:
          grants++;
          expect(request.url.path, '/v1/me/consents/reply_chat_import');
          expect(jsonDecode(request.body), {
            'granted': true,
            'version': '2026-11-reply',
          });
          granted = true;
          return response({
            'purpose': 'reply_chat_import',
            'granted': true,
            'version': '2026-11-reply',
            'updated_at': '2026-11-21T09:00:00+08:00',
          });
        case AppOp.listContacts:
          return response({'items': []});
        case AppOp.getEntitlements:
          return response({'tier': 'free', 'max_active_contacts': 1});
        case AppOp.createReply:
          replies.add(jsonDecode(request.body) as Json);
          final reject = rejectReply;
          if (reject != null) {
            return response({
              'code': reject(),
              'message': '合成服务错误内容',
              'retryable': false,
            }, 403);
          }
          return response({
            'code': 'moderation_unavailable',
            'message': '合成审核服务异常',
            'retryable': true,
          }, 503);
        default:
          throw StateError('Unexpected operation: ${op.name}');
      }
    };
  }

  var granted = true;
  var checks = 0;
  var grants = 0;
  Completer<void>? pendingCheck;
  String Function()? rejectReply;
  final replies = <Json>[];

  Json get decision => {
    'purpose': 'reply_chat_import',
    'granted': granted,
    'version': '2026-11-reply',
    'updated_at': '2026-11-21T09:00:00+08:00',
    'decision_id': '90ed4318-470a-4ec1-8da5-b4798ee63a75',
  };
}

Future<void> settleWire(WidgetTester t) async {
  await t.runAsync(t.pumpAndSettle);
}

const _longDraft = '合成第1行\n合成第2行\n合成第3行\n合成第4行\n合成第5行\n合成第6行\n合成第7行';

Future<void> _openCompactDraft(WidgetTester t, _ConsentWire wire) async {
  t.view.physicalSize = const Size(320, 568);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final service = (await t.runAsync(() => wireReply(wire)))!;
  await t.pumpWidget(MaterialApp(home: ReplyPage(service)));
  await settleWire(t);
  await t.enterText(find.byType(TextField).first, _longDraft);
  await t.pumpAndSettle();
  expect(wire.replies, isEmpty);
}

Future<void> waitForReplyTest(
  WidgetTester tester,
  bool Function() ready,
) async {
  for (var attempt = 0; attempt < 20 && !ready(); attempt++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }
  expect(ready(), isTrue);
}

final _requestUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

void main() {
  testWidgets('320×568 手输七行后，各类 403 和 503 原因在按钮旁可见', (t) async {
    final wire = _ConsentWire();
    await _openCompactDraft(t, wire);
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(find.text('服务暂不可用，可重试').hitTestable(), findsOneWidget);
    expect(find.text('重试原请求').hitTestable(), findsOneWidget);

    wire.rejectReply = () => 'forbidden';
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, hasLength(2));
    expect(wire.replies.last, wire.replies.first);
    expect(find.text('授权或关系人权限已变更，请检查后重试。').hitTestable(), findsOneWidget);
    expect(find.text('重试原请求').hitTestable(), findsOneWidget);
    expect(find.text('合成服务错误内容'), findsNothing);

    wire.rejectReply = () {
      wire.granted =
          false; // Withdrawal races the POST after a successful check.
      return 'forbidden';
    };
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, hasLength(3));
    expect(wire.replies.last, wire.replies.first);
    expect(
      find.text('本次回复授权已撤回，请重新阅读说明并同意后再分析。').hitTestable(),
      findsOneWidget,
    );
    expect(find.text('同意本次说明').hitTestable(), findsOneWidget);

    await tapKey(t, 'reply-accept-import');
    await settleWire(t);
    expect(wire.replies, hasLength(3));
    wire.rejectReply = () => 'reply_consent_expired';
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, hasLength(4));
    expect(wire.replies.last, wire.replies.first);
    expect(find.text('原请求的授权已失效。草稿已保留，请重新开始分析。').hitTestable(), findsOneWidget);

    wire.rejectReply = null;
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, hasLength(5));
    expect(
      wire.replies.last['request_id'],
      isNot(wire.replies.first['request_id']),
    );
  });

  testWidgets('服务明确旧绑定失效才换键，重新同意和收到 403 都不会提交草稿', (t) async {
    final wire = _ConsentWire();
    await _openCompactDraft(t, wire);
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    final original = wire.replies.single;

    wire.granted = false;
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, hasLength(1));
    await tapKey(t, 'reply-accept-import');
    await settleWire(t);
    expect(wire.replies, hasLength(1));

    wire.rejectReply = () => 'reply_consent_expired';
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, hasLength(2));
    expect(wire.replies.last, original);
    expect(find.text('原请求的授权已失效。草稿已保留，请重新开始分析。').hitTestable(), findsOneWidget);
    expect(find.text('开始分析').hitTestable(), findsOneWidget);
    expect(find.text(_longDraft), findsOneWidget);

    wire.rejectReply = null;
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, hasLength(3));
    expect(wire.replies.last['request_id'], isNot(original['request_id']));
    expect(wire.replies.last['chat_text'], _longDraft);
  });
  testWidgets('已有关系人旧授权仍显示本次回复说明且不自动发送', (t) async {
    final wire = Handler();
    wire.handle = (op, request) async {
      switch (op) {
        case AppOp.listConsents:
          return response({
            'items': [
              {
                'purpose': 'chat_import',
                'granted': true,
                'version': '2026-11',
                'updated_at': '2026-11-21T09:00:00+08:00',
              },
            ],
            'next_cursor': null,
          });
        case AppOp.listContacts:
          return response({'items': []});
        default:
          throw StateError('Unexpected operation: ${op.name}');
      }
    };
    final service = (await t.runAsync(() => wireReply(wire)))!;
    await t.pumpWidget(
      MaterialApp(home: ReplyPage(service, sharedText: '合成旧授权草稿')),
    );
    await settleWire(t);

    expect(find.text('本次回复说明'), findsOneWidget);
    expect(find.textContaining('只有你点「开始分析」后'), findsOneWidget);
    expect(find.byKey(const ValueKey('reply-accept-import')), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNull,
    );
  });
  testWidgets('关系人已撤回授权但仍可读取旧手记时，分析前拦住正文', (t) async {
    final wire = _ConsentWire();
    final personId = '85b72033-9f07-4bbc-8567-fc31f26508ab';
    var contactsGranted = true;
    final fallback = wire.handle;
    wire.handle = (op, request) async {
      if (op == AppOp.listConsents) {
        return response({
          'items': [
            wire.decision,
            {
              'purpose': 'contacts',
              'version': '2026-11',
              'granted': contactsGranted,
              'decision_id': 'a0afb27f-12b7-4edc-a3a2-dddf1dfaae32',
            },
          ],
          'next_cursor': null,
        });
      }
      if (op == AppOp.listContacts) {
        return response({
          'items': [
            {
              'id': personId,
              'nickname': '合成旧手记',
              'scene': 'work',
              'editable': true,
              'profile': <String, Object?>{},
            },
          ],
        });
      }
      return fallback(op, request);
    };
    final service = (await t.runAsync(() => wireReply(wire)))!;
    await t.pumpWidget(
      MaterialApp(home: ReplyPage(service, sharedText: '合成保留草稿')),
    );
    await settleWire(t);
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('合成旧手记').last);
    await t.pumpAndSettle();

    contactsGranted = false;
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies, isEmpty);
    expect(find.text('合成保留草稿'), findsOneWidget);
    expect(find.text('请改选或取消关联'), findsOneWidget);
    await tap(t, '取消关联');
    expect(wire.replies, isEmpty);
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies.single['chat_text'], '合成保留草稿');
    expect(wire.replies.single.containsKey('contact_id'), isFalse);
  });
  for (final duringConsent in [true, false]) {
    final check = duringConsent ? '授权查询' : '关系人查询';
    testWidgets('$check中名册移除已选关系人，必须重新选择后点击才 POST', (t) async {
      final wire = _ConsentWire();
      const draft = '合成保留草稿';
      const old = {
        'id': 'old',
        'nickname': '合成甲',
        'scene': 'work',
        'editable': true,
        'profile': <String, Object?>{},
      };
      const replacement = {
        'id': 'new',
        'nickname': '合成乙',
        'scene': 'work',
        'editable': true,
        'profile': <String, Object?>{},
      };
      var roster = <Json>[old];
      var failRoster = false;
      Completer<void>? pendingConsent;
      Completer<List<Json>>? pendingRoster;
      final fallback = wire.handle;
      wire.handle = (op, request) async {
        if (op == AppOp.listConsents) {
          final pending = pendingConsent;
          pendingConsent = null;
          await pending?.future;
          return response({
            'items': [
              wire.decision,
              {
                'purpose': 'contacts',
                'version': '2026-11',
                'granted': true,
                'updated_at': '2026-11-21T09:00:00+08:00',
                'decision_id': 'a0afb27f-12b7-4edc-a3a2-dddf1dfaae32',
              },
            ],
          });
        }
        if (op == AppOp.listContacts) {
          if (failRoster) {
            return response({'code': 'unavailable'}, 503);
          }
          final pending = pendingRoster;
          pendingRoster = null;
          return response({'items': await pending?.future ?? roster});
        }
        return fallback(op, request);
      };

      final service = (await t.runAsync(() => wireReply(wire)))!;
      await t.pumpWidget(
        MaterialApp(home: ReplyPage(service, sharedText: draft)),
      );
      await settleWire(t);
      final dropdown = find.byType(DropdownButtonFormField<String>);
      Future<void> choose(String name) async {
        await t.ensureVisible(dropdown);
        await t.tap(dropdown);
        await t.pumpAndSettle();
        await t.tap(find.text(name).last);
        await t.pumpAndSettle();
      }

      Future<void> waitFor(bool Function() ready) async {
        for (var attempt = 0; attempt < 20 && !ready(); attempt++) {
          await t.runAsync(() => Future<void>.delayed(Duration.zero));
          await t.pump();
        }
        expect(ready(), isTrue);
      }

      await choose('合成甲');
      await t.enterText(find.byType(TextField).last, '合成回复目的');
      await t.pumpAndSettle();
      wire.rejectReply = () {
        failRoster = true;
        return 'forbidden';
      };
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      final original = wire.replies.single;
      expect(original, containsPair('contact_id', 'old'));
      final retry = find.text('关系人未载入 · 重试（也可不选）');
      expect(retry, findsOneWidget);

      wire.rejectReply = null;
      failRoster = false;
      final rosterRefresh = pendingRoster = Completer<List<Json>>();
      await t.ensureVisible(retry);
      await t.tap(retry);
      await waitFor(() => pendingRoster == null);

      final consentCheck = Completer<void>();
      final contactCheck = Completer<List<Json>>();
      if (duringConsent) {
        pendingConsent = consentCheck;
      } else {
        pendingRoster = contactCheck;
      }
      await tapKey(t, 'reply-analyze');
      await waitFor(() => pendingConsent == null && pendingRoster == null);
      expect(wire.replies, hasLength(1));

      roster = [replacement];
      rosterRefresh.complete(roster);
      await waitFor(() => find.text('请改选或取消关联').evaluate().isNotEmpty);
      if (duringConsent) {
        consentCheck.complete();
      } else {
        contactCheck.complete([old]);
      }
      await settleWire(t);
      expect(wire.replies, hasLength(1));
      expect(find.text(draft), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
            .onPressed,
        isNull,
      );

      await choose('合成乙');
      expect(wire.replies, hasLength(1));
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(wire.replies, hasLength(2));
      final submitted = wire.replies.last;
      expect(submitted, containsPair('chat_text', draft));
      expect(submitted, containsPair('goal', '合成回复目的'));
      expect(submitted, containsPair('contact_id', 'new'));
      expect(submitted['request_id'], isNot(original['request_id']));
    });
  }

  for (final change in [
    '撤权',
    '同版本重授',
    '关系人降权',
    '关系人同版本重授',
    '授权读取失败',
    '授权未变',
    '关联关系人且授权未变',
  ]) {
    final unchanged = change.endsWith('授权未变');
    final contactChanged = change.startsWith('关系人');
    final hasContact = contactChanged || change.startsWith('关联关系人');
    final outcome = unchanged ? '允许同键同体重放一次' : '禁止自动重放正文';
    testWidgets('401 刷新期间$change，$outcome', (t) async {
      const draft = '合成刷新前草稿';
      const selected = '85b72033-9f07-4bbc-8567-fc31f26508ab';
      var replyDecision = '90ed4318-470a-4ec1-8da5-b4798ee63a75';
      var contactDecision = 'a0afb27f-12b7-4edc-a3a2-dddf1dfaae32';
      var contactUsable = true;
      var failConsentRead = false;
      final wire = _ConsentWire();
      final releaseRefresh = Completer<void>();
      var refreshes = 0;
      var consentReads = 0;
      final consentReadsAtSend = <int>[];
      final fallback = wire.handle;
      wire.handle = (op, request) async {
        switch (op) {
          case AppOp.refreshTokens:
            refreshes++;
            await releaseRefresh.future;
            return response(tokens('fixture', 'refreshed').toJson());
          case AppOp.listConsents:
            consentReads++;
            if (failConsentRead) return response({'code': 'unavailable'}, 503);
            return response({
              'items': [
                {...wire.decision, 'decision_id': replyDecision},
                {
                  'purpose': 'contacts',
                  'version': '2026-11',
                  'granted': true,
                  'updated_at': '2026-11-21T09:00:00+08:00',
                  'decision_id': contactDecision,
                },
              ],
            });
          case AppOp.listContacts:
            return response({
              'items': [
                {
                  'id': selected,
                  'nickname': '合成联系人',
                  'scene': 'work',
                  'editable': contactUsable,
                  'profile': <String, Object?>{},
                },
              ],
            });
          case AppOp.createReply:
            expect(request.method, 'POST');
            final body = jsonDecode(request.body) as Json;
            wire.replies.add(body);
            consentReadsAtSend.add(consentReads);
            if (wire.replies.length == 1) return response({}, 401);
            return response({
              'request_id': body['request_id'],
              'status': 'in_progress',
            }, 202);
          default:
            return fallback(op, request);
        }
      };

      final service = (await t.runAsync(() => wireReply(wire)))!;
      await t.pumpWidget(
        MaterialApp(home: ReplyPage(service, sharedText: draft)),
      );
      await settleWire(t);
      if (hasContact) {
        await tap(t, '不关联关系人');
        await t.pumpAndSettle();
        await t.tap(find.text('合成联系人').last);
        await t.pumpAndSettle();
      }
      await t.enterText(find.byType(TextField).last, '合成处理目的');
      await t.pumpAndSettle();
      await tapKey(t, 'reply-analyze');
      await waitForReplyTest(t, () => refreshes == 1);
      final first = wire.replies.single;
      expect(first['request_id'], matches(_requestUuid));
      expect(first['chat_text'], draft);
      expect(first['goal'], '合成处理目的');
      expect(first['reply_consent_id'], replyDecision);
      if (hasContact) {
        expect(first['contact_id'], selected);
        expect(first['contacts_consent_id'], contactDecision);
      } else {
        expect(first.containsKey('contacts_consent_id'), isFalse);
      }
      switch (change) {
        case '撤权':
          wire.granted = false;
        case '同版本重授':
          replyDecision = 'd152a427-cdfa-4abf-b591-000dd9f6e7b9';
        case '关系人降权':
          contactUsable = false;
        case '关系人同版本重授':
          contactDecision = '196861dc-3c91-4db0-94b9-cbfcba0d3834';
        case '授权读取失败':
          failConsentRead = true;
      }

      releaseRefresh.complete();
      await settleWire(t);
      if (unchanged) {
        expect(wire.replies, [first, first]);
        expect(consentReadsAtSend.first, hasContact ? 4 : 3);
        expect(consentReadsAtSend.last, hasContact ? 5 : 4);
        expect(refreshes, 1);
        expect(find.text('查看原请求结果'), findsOneWidget);
        return;
      }
      expect(wire.replies.length, 1);
      expect(find.text(draft), findsOneWidget);
      final goalField = find.widgetWithText(TextField, '合成处理目的');
      await t.scrollUntilVisible(
        goalField,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(t.widget<TextField>(goalField).controller!.text, '合成处理目的');
      final analyze = find.byKey(const ValueKey('reply-analyze'));
      expect(t.widget<FilledButton>(analyze).onPressed, isNull);

      if (contactChanged) {
        expect(find.text('请改选或取消关联'), findsOneWidget);
        await tap(t, '取消关联');
      } else {
        failConsentRead = false;
        await tapKey(t, 'reply-accept-import');
      }
      await settleWire(t);
      expect(wire.replies.length, 1);
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(refreshes, 1);
      expect(wire.replies, hasLength(2));
      final explicit = wire.replies.last;
      expect(explicit['request_id'], matches(_requestUuid));
      expect(explicit['chat_text'], draft);
      expect(explicit['goal'], '合成处理目的');
      if (contactChanged) {
        expect(explicit.containsKey('contact_id'), isFalse);
        expect(explicit['request_id'], isNot(first['request_id']));
      } else if (change == '授权读取失败') {
        expect(explicit, first);
      } else {
        expect(explicit['reply_consent_id'], replyDecision);
        expect(explicit['request_id'], isNot(first['request_id']));
      }
    });
  }

  for (final failureOp in [AppOp.listContacts, AppOp.getEntitlements]) {
    testWidgets('发送守卫 ${failureOp.name} 超时保留已建操作', (t) async {
      const draft = '合成超时草稿';
      const selected = '85b72033-9f07-4bbc-8567-fc31f26508ab';
      const contactDecision = 'a0afb27f-12b7-4edc-a3a2-dddf1dfaae32';
      final wire = _ConsentWire();
      final fallback = wire.handle;
      final reads = <AppOp>[];
      var readsUntilTimeout = 0;
      wire.handle = (op, req) async {
        reads.add(op);
        if (op == failureOp &&
            readsUntilTimeout > 0 &&
            --readsUntilTimeout == 0) {
          throw TimeoutException('合成读取超时');
        }
        switch (op) {
          case AppOp.listConsents:
            return response({
              'items': [
                wire.decision,
                {
                  'purpose': 'contacts',
                  'version': '2026-11',
                  'granted': true,
                  'decision_id': contactDecision,
                },
              ],
            });
          case AppOp.listContacts:
            return response({
              'items': [
                {
                  'id': selected,
                  'nickname': '合成超时关系人',
                  'scene': 'work',
                  'editable': true,
                  'profile': <String, Object?>{},
                },
              ],
            });
          case AppOp.createReply when failureOp == AppOp.getEntitlements:
            final body = jsonDecode(req.body) as Json;
            wire.replies.add(body);
            return response({
              'request_id': body['request_id'],
              'status': 'in_progress',
            }, 202);
          default:
            return fallback(op, req);
        }
      };
      final service = (await t.runAsync(() => wireReply(wire)))!;
      await t.pumpWidget(
        MaterialApp(home: ReplyPage(service, sharedText: draft)),
      );
      await settleWire(t);
      await tap(t, '不关联关系人');
      await t.pumpAndSettle();
      await t.tap(find.text('合成超时关系人').last);
      await t.pumpAndSettle();
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      final original = wire.replies.single;

      readsUntilTimeout =
          2; // First read is the page preflight; second is the guard.
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(wire.replies, [original]);
      expect(find.text(draft), findsOneWidget);
      expect(find.text('合成超时关系人'), findsOneWidget);
      expect(find.text('重试原请求'), findsOneWidget);
      expect(find.textContaining('暂时无法确认关系人权限'), findsOneWidget);

      reads.clear();
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(wire.replies, [original, original]);
      expect(original['contacts_consent_id'], contactDecision);
      expect(reads.sublist(reads.length - 4), [
        AppOp.listConsents,
        AppOp.listContacts,
        AppOp.getEntitlements,
        AppOp.createReply,
      ]);
    });
  }

  for (final phase in ['预检', '守卫']) {
    testWidgets('$phase 名册权益不一致时零 POST 并保留原请求', (t) async {
      const draft = '合成不一致草稿';
      const goal = '合成原目的';
      const selected = '85b72033-9f07-4bbc-8567-fc31f26508ab';
      const other = '1a6d4f8f-70c2-4fa3-9197-2586b0125412';
      final wire = _ConsentWire();
      final fallback = wire.handle;
      var readsUntilChange = 0;
      var confirmedDowngrade = false;
      var completedChanges = 0;
      Json personRow(String id, String name, bool editable) => {
        'id': id,
        'nickname': name,
        'scene': 'work',
        'editable': editable,
        'profile': <String, Object?>{},
      };
      wire.handle = (op, req) async {
        switch (op) {
          case AppOp.listConsents:
            return response({
              'items': [
                wire.decision,
                {
                  'purpose': 'contacts',
                  'version': '2026-11',
                  'granted': true,
                  'decision_id': 'a0afb27f-12b7-4edc-a3a2-dddf1dfaae32',
                },
              ],
            });
          case AppOp.listContacts:
            final changed = readsUntilChange == 1;
            return response({
              'items': [
                personRow(selected, '合成已选关系人', !changed || !confirmedDowngrade),
                personRow(other, '合成另一关系人', changed),
              ],
            });
          case AppOp.getEntitlements:
            if (readsUntilChange > 0 && --readsUntilChange == 0) {
              completedChanges++;
            }
            // During inconsistency both people appear editable, but the limit is one.
            return response({'tier': 'free', 'max_active_contacts': 1});
          default:
            return fallback(op, req);
        }
      };
      final service = (await t.runAsync(() => wireReply(wire)))!;
      await t.pumpWidget(
        MaterialApp(home: ReplyPage(service, sharedText: draft)),
      );
      await settleWire(t);
      await tap(t, '不关联关系人');
      await t.pumpAndSettle();
      await t.tap(find.text('合成已选关系人').last);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField).last, goal);
      await t.pumpAndSettle();
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      final original = wire.replies.single;
      expect(original['request_id'], matches(_requestUuid));
      expect(original['contact_id'], selected);
      expect(original['chat_text'], draft);
      expect(original['goal'], goal);

      final changeRead = phase == '预检' ? 1 : 2;
      readsUntilChange = changeRead;
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(completedChanges, 1);
      expect(wire.replies, [original]);
      expect(find.text('合成已选关系人'), findsOneWidget);
      expect(find.text(draft), findsOneWidget);
      expect(find.text(goal), findsOneWidget);
      expect(find.textContaining('暂时无法确认关系人权限'), findsOneWidget);
      expect(find.text('重试原请求'), findsOneWidget);
      expect(find.text('请改选或取消关联'), findsNothing);

      // The fixture is consistent again. Recovery itself never starts an analysis.
      await settleWire(t);
      expect(wire.replies, [original]);
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(wire.replies, [original, original]);

      // A consistent roster that makes only the other contact editable is a
      // confirmed loss of permission, rather than an unavailable snapshot.
      confirmedDowngrade = true;
      readsUntilChange = changeRead;
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(completedChanges, 2);
      expect(wire.replies, [original, original]);
      expect(find.text('合成已选关系人'), findsNothing);
      expect(find.text('请改选或取消关联'), findsOneWidget);
      await tap(t, '取消关联');
      expect(wire.replies, [original, original]);
      await tapKey(t, 'reply-analyze');
      await settleWire(t);
      expect(wire.replies, hasLength(3));
      expect(wire.replies.last['request_id'], matches(_requestUuid));
      expect(wire.replies.last['request_id'], isNot(original['request_id']));
      expect(wire.replies.last.containsKey('contact_id'), isFalse);
      expect(wire.replies.last['chat_text'], draft);
      expect(wire.replies.last['goal'], goal);
    });
  }

  testWidgets('迟到 403 授权查询不覆盖取消关联后的界面', (t) async {
    final selected = person('old', '合成旧关系人');
    final f = Fixture()
      ..consent = true
      ..available = [selected];
    final pending = Completer<bool>();
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成待确认草稿')));
    await t.pumpAndSettle();
    await tap(t, '不关联关系人');
    await t.pumpAndSettle();
    await t.tap(find.text(selected.name).last);
    await t.pumpAndSettle();
    f.analyzeWith = (_) async {
      f.pendingAllowed = pending.future;
      throw const ApiFailure(403, 'reply_consent_expired', '', false);
    };
    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(1));
    expect(pending.isCompleted, isFalse);
    await tap(t, selected.name);
    await t.pump(const Duration(milliseconds: 300));
    final unlinked = find.text('不关联关系人').hitTestable();
    expect(unlinked, findsOneWidget);
    await t.tap(unlinked);
    await t.pump(const Duration(milliseconds: 300));
    pending.complete(false);
    f.pendingAllowed = null;
    await t.pumpAndSettle();
    expect(find.text('本次回复说明'), findsNothing);
    expect(find.textContaining('原请求的授权已失效'), findsNothing);
    expect(find.text('合成待确认草稿'), findsOneWidget);
    expect(f.calls, hasLength(1));
    f.analyzeWith = (_) async => Processing();
    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(2));
    expect(f.calls.last.containsKey('contact_id'), isFalse);
    expect(f.calls.last['request_id'], isNot(f.calls.first['request_id']));
  });

  testWidgets('首发前发现回复决定已替换，零 POST 并保留草稿', (t) async {
    const draft = '合成首次提交草稿';
    final wire = _ConsentWire();
    var checks = 0;
    final fallback = wire.handle;
    wire.handle = (op, request) async {
      if (op != AppOp.listConsents) return fallback(op, request);
      checks++;
      return response({
        'items': [
          {
            ...wire.decision,
            if (checks >= 3)
              'decision_id': 'd152a427-cdfa-4abf-b591-000dd9f6e7b9',
          },
        ],
      });
    };
    final service = (await t.runAsync(() => wireReply(wire)))!;
    await t.pumpWidget(
      MaterialApp(home: ReplyPage(service, sharedText: draft)),
    );
    await settleWire(t);
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(checks, 3);
    expect(wire.replies, isEmpty);
    expect(find.text(draft), findsOneWidget);
    expect(find.byKey(const ValueKey('reply-accept-import')), findsOneWidget);

    await tapKey(t, 'reply-accept-import');
    await settleWire(t);
    expect(wire.replies, isEmpty);
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.replies.single['request_id'], matches(_requestUuid));
    expect(wire.replies.single['chat_text'], draft);
  });

  testWidgets('授权确认离线时不发送正文，恢复后可继续同一草稿', (t) async {
    final f = Fixture()
      ..consent = true
      ..allowedFailure = StateError('synthetic offline');
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成离线授权草稿')));
    await t.pumpAndSettle();

    expect(f.consentChecks, 1);
    expect(f.calls, isEmpty);
    expect(find.text('未能确认本次回复授权，请重试。'), findsOneWidget);
    expect(find.textContaining('synthetic offline'), findsNothing);
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNull,
    );

    f.allowedFailure = null;
    await t.tap(find.text('重新检查本次授权'));
    await t.pumpAndSettle();
    expect(f.consentChecks, 2);
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNotNull,
    );

    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(1));
    expect(f.calls.single['chat_text'], '合成离线授权草稿');
    f.response.complete(NoResult());
    await t.pumpAndSettle();
  });
  testWidgets('本次回复提示区分回复服务与关系人入口原文留存', (t) async {
    final f = Fixture();
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成导入边界')));
    await t.pumpAndSettle();

    expect(find.text('本次回复说明'), findsOneWidget);
    expect(find.textContaining('只有你点「开始分析」后，才会提交聊天文字和可选目的'), findsOneWidget);
    expect(find.textContaining('所选关系人的画像摘要也会用于生成建议'), findsOneWidget);
    expect(find.textContaining('回复服务不保存提交的聊天原文和目的'), findsOneWidget);
    expect(find.textContaining('关系人入口的既有导入记录满 24 小时后尝试清除'), findsOneWidget);
    expect(find.textContaining('故障时会重试'), findsOneWidget);
    expect(find.textContaining('供应商、日志、备份或物理介质中的副本'), findsOneWidget);
    expect(find.textContaining('应用不会自动发给对方'), findsOneWidget);
    expect(find.text('首次导入说明'), findsNothing);
    expect(find.textContaining('聊天原文在 24 小时内删除'), findsNothing);
    expect(f.calls, isEmpty);
  });
  testWidgets('紧凑屏首屏显示完整边界，继续与撤回固定可达且不自动发送', (t) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final f = Fixture();
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成小屏导入')));
    await t.pumpAndSettle();

    final notice = find.byKey(const ValueKey('reply-import-notice'));
    expect(notice, findsOneWidget);
    final noticeRect = t.getRect(notice);
    final listRect = t.getRect(find.byType(ListView));
    expect(noticeRect.top, greaterThanOrEqualTo(listRect.top));
    expect(noticeRect.bottom, lessThanOrEqualTo(listRect.bottom));
    for (final key in [
      'reply-defer-import',
      'reply-accept-import',
      'reply-analyze',
    ]) {
      final target = find.byKey(ValueKey(key));
      expect(target, findsOneWidget);
      final rect = t.getRect(target);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(568));
    }
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNull,
    );

    await tapKey(t, 'reply-accept-import');
    await t.pumpAndSettle();
    expect(f.calls, isEmpty);
    expect(find.byKey(const ValueKey('reply-import-notice')), findsNothing);
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNotNull,
    );
    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(1));
    f.response.complete(NoResult());
    await t.pumpAndSettle();
  });
  testWidgets('分享只填草稿；授权不发送；503、202、危机同键重试，修改后新键', (t) async {
    final f = Fixture();
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成分享')));
    await t.pumpAndSettle();
    expect(find.text('合成分享'), findsOneWidget);
    expect(f.calls, isEmpty);
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNull,
    );
    await tapKey(t, 'reply-accept-import');
    await t.pumpAndSettle();
    expect(f.calls, isEmpty);
    await tapKey(t, 'reply-analyze');
    expect(f.calls.length, 1);
    expect(find.textContaining('待整份审核'), findsOneWidget);
    f.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '未审核片段', true),
    );
    await t.pumpAndSettle();
    expect(find.text('服务暂不可用，可重试'), findsOneWidget);
    expect(find.text('未审核片段'), findsNothing);
    expect(find.textContaining('12356'), findsNothing);
    await tapKey(t, 'reply-analyze');
    f.response.complete(Processing());
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.complete(Crisis());
    await t.pumpAndSettle();
    expect(f.calls.toSet().length, 1);
    expect(find.textContaining('12356'), findsOneWidget);
    expect(find.text('复制建议'), findsNothing);
    final field = find.byType(TextField).first;
    await t.ensureVisible(field);
    await t.enterText(field, '新的合成内容');
    await t.pumpAndSettle();
    expect(find.textContaining('12356'), findsNothing);
    await tapKey(t, 'reply-analyze');
    expect(f.calls.last['request_id'], isNot(f.calls.first['request_id']));
    f.response.complete(NoResult());
    await t.pumpAndSettle();
    expect(find.textContaining('暂无完整'), findsOneWidget);
  });
  testWidgets('只复制主动选中的建议；反馈使用零基下标', (t) async {
    final f = Fixture()..consent = true;
    final copied = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add(call.arguments['text']);
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '示例')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    // With eager children in the viewport, locate both suggestion actions.
    await t.drag(find.byType(ListView), const Offset(0, -800));
    await t.pumpAndSettle();
    expect(copied, isEmpty);
    final copy = find.text('复制建议').last;
    await t.ensureVisible(copy);
    await t.tap(copy);
    await t.pump();
    expect(copied, ['想先看提纲吗？']);
    final use = find.text('我用了这条').last;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();
    await tap(t, '提交效果反馈');
    expect(f.ratings.single.index, 1);
    expect(f.ratings.single.outcome, '更清楚了');
    expect(f.ratings.single.selfReport, isNull);
  });
  testWidgets('提交前重新确认本次回复授权；撤回后不发送正文', (t) async {
    t.view.physicalSize = const Size(320, 568);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    const draft = '合成授权文字';
    final wire = _ConsentWire();
    final service = (await t.runAsync(() => wireReply(wire)))!;
    await t.pumpWidget(
      MaterialApp(home: ReplyPage(service, sharedText: draft)),
    );
    await settleWire(t);
    expect(wire.checks, 1);

    final pending = wire.pendingCheck = Completer<void>();
    await tapKey(t, 'reply-analyze');
    expect(wire.checks, 2);
    expect(wire.replies, isEmpty);
    final analyze = find.byKey(const ValueKey('reply-analyze'));
    expect(t.widget<FilledButton>(analyze).onPressed, isNull);

    wire.granted = false;
    pending.complete();
    await settleWire(t);

    expect(wire.checks, 2);
    expect(wire.replies, isEmpty);
    expect(wire.grants, 0);
    expect(find.text('本次回复说明'), findsOneWidget);
    final withdrawal = find.text('本次回复授权已撤回，请重新阅读说明并同意后再分析。');
    expect(withdrawal.hitTestable(), findsOneWidget);
    expect(t.widget<FilledButton>(analyze).onPressed, isNull);
    final draftFields = find.byType(TextField);
    await t.scrollUntilVisible(
      draftFields,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await t.pumpAndSettle();
    final draftField = draftFields.first;
    expect(draftField.hitTestable(), findsOneWidget);
    expect(t.widget<TextField>(draftField).controller?.text, draft);
    expect(withdrawal.hitTestable(), findsOneWidget);

    await tapKey(t, 'reply-accept-import');
    await settleWire(t);
    expect(wire.grants, 1);
    expect(wire.replies, isEmpty);
    expect(withdrawal, findsNothing);
    expect(t.widget<FilledButton>(analyze).onPressed, isNotNull);
  });
  testWidgets('重试前重新确认本次回复授权；撤回后不重复发送', (t) async {
    const draft = '合成重试文字';
    final wire = _ConsentWire();
    final service = (await t.runAsync(() => wireReply(wire)))!;
    await t.pumpWidget(
      MaterialApp(home: ReplyPage(service, sharedText: draft)),
    );
    await settleWire(t);
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.checks, 3);
    expect(wire.replies, hasLength(1));
    expect(wire.replies.single['chat_text'], draft);
    expect(find.text('重试原请求'), findsOneWidget);

    wire.granted = false;
    await tapKey(t, 'reply-analyze');
    await settleWire(t);

    expect(wire.checks, 4);
    expect(wire.replies, hasLength(1));
    expect(wire.grants, 0);
    expect(find.text('本次回复说明'), findsOneWidget);
    final withdrawal = find.text('本次回复授权已撤回，请重新阅读说明并同意后再分析。');
    expect(withdrawal.hitTestable(), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNull,
    );
    expect(find.text(draft), findsOneWidget);

    await tapKey(t, 'reply-accept-import');
    await settleWire(t);
    expect(wire.grants, 1);
    expect(wire.replies, hasLength(1));
    expect(withdrawal, findsNothing);
    await tapKey(t, 'reply-analyze');
    await settleWire(t);
    expect(wire.checks, 6);
    expect(wire.replies, hasLength(2));
    expect(wire.replies.last, wire.replies.first);
  });
  testWidgets('按最终 JSON 字节数阻止超限请求', (t) async {
    final f = Fixture()..consent = true;
    // The text itself is below 32 KiB, but the frozen JSON envelope is over it.
    final text = List.filled((32 << 10) - 60, 'a').join();
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: text)));
    await t.pumpAndSettle();

    await tapKey(t, 'reply-analyze');
    await t.pump();

    expect(f.calls, isEmpty);
    expect(find.textContaining('内容过长'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );
  });
  testWidgets('400 不显示断线文案，也不鼓励原样重试', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成格式错误')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.completeError(
      const ApiFailure(400, 'invalid_argument', '合成错误正文', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('请求内容不符合要求'), findsOneWidget);
    expect(find.textContaining('连接未完成'), findsNothing);
    expect(find.text('合成错误正文'), findsNothing);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );

    await t.enterText(find.byType(TextField).first, '修改后的合成内容');
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('仅改首尾空白时复用原请求 ID；真实内容变化才换 ID', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成原请求')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '未审核片段', true),
    );
    await t.pumpAndSettle();

    await t.enterText(find.byType(TextField).first, '  合成原请求  ');
    await t.pumpAndSettle();
    expect(find.text('重试原请求'), findsOneWidget);
    await tapKey(t, 'reply-analyze');
    expect(f.calls.length, 2);
    expect(f.calls.last, first);

    f.response.completeError(
      const ApiFailure(503, 'moderation_unavailable', '未审核片段', true),
    );
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).first, '合成新的请求');
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    expect(f.calls.length, 3);
    expect(f.calls.last['request_id'], isNot(first['request_id']));
    expect(f.calls.last['chat_text'], '合成新的请求');
    f.response.complete(NoResult());
    await t.pumpAndSettle();
  });
  testWidgets('409 后必须修改规范化内容才能继续', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成冲突请求')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.completeError(
      const ApiFailure(409, 'conflict', '同键不同输入', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('与原操作不一致'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );
    await t.enterText(find.byType(TextField).first, ' 合成冲突请求 ');
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '请先修改输入'))
          .onPressed,
      isNull,
    );

    await t.enterText(find.byType(TextField).first, '合成冲突请求已修改');
    await t.pumpAndSettle();
    expect(
      t
          .widget<FilledButton>(find.byKey(const ValueKey('reply-analyze')))
          .onPressed,
      isNotNull,
    );
  });
  testWidgets('非契约 500 不把结果误判为终止，可用原请求重试', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成网关错误')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.completeError(
      const ApiFailure(500, 'unavailable', '暂时无法连接，请重试', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('连接未完成'), findsOneWidget);
    expect(find.textContaining('本次分析已结束'), findsNothing);
    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(2));
    expect(f.calls.last, first);
    f.response.complete(NoResult());
    await t.pumpAndSettle();
  });
  testWidgets('T21 已确认终止的 500 不提示原请求可重试', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成终止失败')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.completeError(
      const ApiFailure(500, 'internal_error', '生成已终止', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('本次分析已结束'), findsOneWidget);
    expect(find.textContaining('连接未完成'), findsNothing);
    expect(find.text('重试原请求'), findsNothing);
    expect(find.text('查看原请求结果'), findsNothing);

    await t.enterText(find.byType(TextField).first, '合成终止后新请求');
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(2));
    expect(f.calls.last['request_id'], isNot(first['request_id']));
    f.response.complete(Processing());
    await t.pumpAndSettle();
  });
  testWidgets('完整终止 500 经真实 HTTP 解析后显示终止', (t) async {
    final wire = _ConsentWire();
    final bodies = <Json>[];
    final fallback = wire.handle;
    wire.handle = (op, req) async {
      if (op == AppOp.listConsents) return fallback(op, req);
      expect(op, AppOp.createReply);
      final body = jsonDecode(req.body) as Json;
      bodies.add(body);
      if (bodies.length == 1) {
        return response({
          'code': 'internal_error',
          'message': '生成已终止',
          'retryable': false,
        }, 500);
      }
      return response({
        'request_id': body['request_id'],
        'status': 'in_progress',
      }, 202);
    };
    final service = await t.runAsync(() => wireReply(wire));
    final f = Fixture()
      ..consent = true
      ..analyzeWith = service!.analyze;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成完整终止')));
    await t.pumpAndSettle();

    await tapKey(t, 'reply-analyze');
    await settleWire(t);

    expect(bodies, hasLength(1));
    expect(find.textContaining('本次分析已结束'), findsOneWidget);
    expect(find.textContaining('连接未完成'), findsNothing);
    expect(find.text('重试原请求'), findsNothing);
    expect(find.text('查看原请求结果'), findsNothing);
    expect(find.textContaining('成功'), findsNothing);
    expect(find.textContaining('扣次'), findsNothing);

    await t.enterText(find.byType(TextField).first, '合成终止后的新请求');
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    await settleWire(t);

    expect(bodies, hasLength(2));
    expect(bodies.last['request_id'], isNot(bodies.first['request_id']));
    expect(find.text('查看原请求结果'), findsOneWidget);
  });
  testWidgets('retryable 缺失或错类型的 500 经真实 HTTP 解析后保留原请求', (t) async {
    final wire = _ConsentWire();
    final bodies = <Json>[];
    final fallback = wire.handle;
    wire.handle = (op, req) async {
      if (op == AppOp.listConsents) return fallback(op, req);
      expect(op, AppOp.createReply);
      final body = jsonDecode(req.body) as Json;
      bodies.add(body);
      if (bodies.length == 1) {
        return response({
          'code': 'internal_error',
          'message': 'upstream error',
        }, 500);
      }
      if (bodies.length == 2) {
        return response({
          'code': 'internal_error',
          'message': 'upstream error',
          'retryable': 'false',
        }, 500);
      }
      return response({
        'request_id': body['request_id'],
        'status': 'in_progress',
      }, 202);
    };
    final service = await t.runAsync(() => wireReply(wire));
    final f = Fixture()
      ..consent = true
      ..analyzeWith = service!.analyze;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成未知结果')));
    await t.pumpAndSettle();

    await tapKey(t, 'reply-analyze');
    await settleWire(t);

    expect(bodies, hasLength(1));
    expect(find.textContaining('连接未完成'), findsOneWidget);
    expect(find.textContaining('本次分析已结束'), findsNothing);
    expect(find.textContaining('成功'), findsNothing);
    expect(find.textContaining('扣次'), findsNothing);
    expect(find.text('重试原请求'), findsOneWidget);

    await tapKey(t, 'reply-analyze');
    await settleWire(t);

    expect(bodies, hasLength(2));
    expect(bodies.last['request_id'], bodies.first['request_id']);
    expect(find.textContaining('连接未完成'), findsOneWidget);
    expect(find.textContaining('本次分析已结束'), findsNothing);
    expect(find.text('重试原请求'), findsOneWidget);

    await tapKey(t, 'reply-analyze');
    await settleWire(t);

    expect(bodies, hasLength(3));
    expect(
      bodies.every((body) => body['request_id'] == bodies.first['request_id']),
      isTrue,
    );
    expect(find.text('查看原请求结果'), findsOneWidget);
  });
  testWidgets('429 显示当前剩余额度和权益重置时间', (t) async {
    final f = Fixture()..consent = true;
    final reset = DateTime.now().add(const Duration(hours: 3));
    f.quotaValue = (remaining: 0, resetsAt: reset);
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成额度请求')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.completeError(
      const ApiFailure(429, 'quota_exceeded', '今日次数已用完', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('剩余 0 次'), findsOneWidget);
    expect(find.textContaining('重置'), findsOneWidget);
    expect(find.text('今日次数已用完'), findsNothing);
  });
  testWidgets('429 额度查询失败时不编造重置时间', (t) async {
    final f = Fixture()
      ..consent = true
      ..quotaFailure = StateError('synthetic quota failure');
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成额度查询失败')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.completeError(
      const ApiFailure(429, 'quota_exceeded', '今日次数已用完', false),
    );
    await t.pumpAndSettle();

    expect(find.textContaining('请按会员页显示的重置时间'), findsOneWidget);
    expect(find.textContaining('将在'), findsNothing);
    expect(find.text('今日次数已用完'), findsNothing);
  });
  testWidgets('关联关系人变为只读后关闭反馈入口且不发送 POST', (t) async {
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人请求')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    final use = find.text('我用了这条').first;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();

    f.available = [];
    await tap(t, '提交效果反馈');

    expect(f.ratings, isEmpty);
    expect(find.textContaining('只读'), findsOneWidget);
    expect(find.text('提交效果反馈'), findsNothing);
  });
  testWidgets('普通 403 后立即清出失效关系人并等待用户改选', (t) async {
    final first = person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A');
    final replacement = person('1a6d4f8f-70c2-4fa3-9197-2586b0125412', '同事 B');
    final f = Fixture()
      ..consent = true
      ..available = [first];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人降权')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();
    expect(f.contactLoads, 1);

    var loadsBeforeDenial = 0;
    f.analyzeWith = (_) async {
      loadsBeforeDenial = f.contactLoads;
      f.available = [replacement];
      throw const ApiFailure(403, 'forbidden', '关系人已降为只读', false);
    };
    await tapKey(t, 'reply-analyze');
    await t.pumpAndSettle();

    expect(f.calls, hasLength(1));
    expect(f.contactLoads, loadsBeforeDenial + 1);
    expect(find.text('合成关系人降权'), findsOneWidget);
    expect(find.text('同事 A'), findsNothing);
    expect(find.textContaining('原关联关系人已不可用'), findsOneWidget);
    expect(find.text('请改选或取消关联'), findsOneWidget);
    expect(find.text('重试原请求'), findsNothing);

    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 B').last);
    await t.pumpAndSettle();

    expect(find.text('同事 B'), findsWidgets);
    expect(find.text('请先修改输入'), findsNothing);
    expect(find.text('开始分析'), findsOneWidget);
    expect(f.calls, hasLength(1));
  });
  testWidgets('普通 403 不误清仍有效关系人和原请求', (t) async {
    final current = person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A');
    final f = Fixture()
      ..consent = true
      ..available = [current];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人仍有效')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();

    var loadsBeforeDenial = 0;
    f.analyzeWith = (_) async {
      loadsBeforeDenial = f.contactLoads;
      throw const ApiFailure(403, 'forbidden', '其他权限不足', false);
    };
    await tapKey(t, 'reply-analyze');
    await t.pumpAndSettle();

    expect(f.calls, hasLength(1));
    expect(f.contactLoads, loadsBeforeDenial + 1);
    expect(find.text('同事 A'), findsOneWidget);
    expect(find.text('重试原请求'), findsOneWidget);
    expect(find.text('请先修改输入'), findsNothing);

    f.analyzeWith = null;
    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(2));
    expect(f.calls.last, f.calls.first);
    f.response.complete(Processing());
    await t.pumpAndSettle();
  });
  testWidgets('关联关系人分析前降权时不发送聊天正文', (t) async {
    final replacement = person('1a6d4f8f-70c2-4fa3-9197-2586b0125412', '同事 B');
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人请求')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();

    f.available = [replacement];
    await tapKey(t, 'reply-analyze');

    expect(f.calls, isEmpty);
    expect(find.textContaining('关系人权限已变更'), findsOneWidget);
    expect(find.text('合成关系人请求'), findsOneWidget);
    await t.enterText(find.byType(TextField).first, '合成改写正文');
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    expect(f.calls.length, 0);
    expect(find.text('请改选或取消关联'), findsOneWidget);

    await tap(t, '不关联关系人');
    await t.pumpAndSettle();
    await t.tap(find.text('同事 B').last);
    await t.pumpAndSettle();
    expect(f.calls, isEmpty);
    await tapKey(t, 'reply-analyze');
    expect(f.calls.single['contact_id'], replacement.id);
    expect(f.calls.single['chat_text'], '合成改写正文');
    expect(f.calls.single['request_id'], matches(_requestUuid));
    f.response.complete(Processing());
    await t.pumpAndSettle();
  });
  testWidgets('首次预检关系人临时查询失败后无需改正文即可重试', (t) async {
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(
      MaterialApp(home: ReplyPage(f, sharedText: '合成关系人查询失败')),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();

    f.contactsFailure = TimeoutException('合成首次预检超时');
    await tapKey(t, 'reply-analyze');

    expect(f.calls, isEmpty);
    expect(find.textContaining('暂时无法确认关系人权限'), findsOneWidget);
    expect(find.text('同事 A'), findsOneWidget);
    expect(find.text('请先修改输入'), findsNothing);
    expect(find.text('合成关系人查询失败'), findsOneWidget);
    expect(t.widget<TextField>(find.byType(TextField).first).enabled, isTrue);

    f.contactsFailure = null;
    await t.pumpAndSettle();
    expect(f.calls, isEmpty);
    await tapKey(t, 'reply-analyze');
    expect(f.calls.single['contact_id'], f.available.single.id);
    expect(f.calls.single['chat_text'], '合成关系人查询失败');
    expect(f.calls.single['request_id'], matches(_requestUuid));
    f.response.complete(Processing());
    await t.pumpAndSettle();
  });
  testWidgets('名册查询超时保留已有 202 原请求，恢复后原体重试', (t) async {
    final f = Fixture()
      ..consent = true
      ..available = [person('85b72033-9f07-4bbc-8567-fc31f26508ab', '同事 A')];
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成关系人待重试')));
    await t.pumpAndSettle();
    await t.tap(find.text('不关联关系人'));
    await t.pumpAndSettle();
    await t.tap(find.text('同事 A').last);
    await t.pumpAndSettle();

    await tapKey(t, 'reply-analyze');
    final first = Map<String, Object?>.from(f.calls.single);
    f.response.complete(Processing());
    await t.pumpAndSettle();
    expect(find.text('查看原请求结果'), findsOneWidget);

    f.contactsFailure = StateError('synthetic contacts timeout');
    await tapKey(t, 'reply-analyze');

    expect(f.calls, hasLength(1));
    expect(find.textContaining('原请求已保留'), findsOneWidget);
    expect(find.text('请先修改输入'), findsNothing);
    expect(find.text('重试原请求'), findsOneWidget);

    f.contactsFailure = null;
    await tapKey(t, 'reply-analyze');
    expect(f.calls, hasLength(2));
    expect(f.calls.last, first);
    f.response.complete(Processing());
    await t.pumpAndSettle();
  });
  testWidgets('反馈 409 提示已有记录并关闭重试入口', (t) async {
    final f = Fixture()
      ..consent = true
      ..feedbackFailure = const ApiFailure(
        409,
        'conflict',
        '同一条回复不能再次修改反馈',
        false,
      );
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成反馈冲突')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    final use = find.text('我用了这条').first;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();

    await tap(t, '提交效果反馈');

    expect(find.textContaining('该回复已有反馈记录'), findsOneWidget);
    expect(find.textContaining('可重试'), findsNothing);
    expect(find.text('提交效果反馈'), findsNothing);
  });
  testWidgets('本人确认默认不选；只有显式选择才发送 self_report', (t) async {
    final f = Fixture()..consent = true;
    await t.pumpWidget(MaterialApp(home: ReplyPage(f, sharedText: '合成本人确认')));
    await t.pumpAndSettle();
    await tapKey(t, 'reply-analyze');
    f.response.complete(
      Approved('reply', '可能着急', '想了解进度', [
        (style: '直接', text: '周三交稿。', reason: '具体时间'),
        (style: '确认', text: '想先看提纲吗？', reason: '留出选择'),
      ]),
    );
    await t.pumpAndSettle();
    final use = find.text('我用了这条').first;
    await t.ensureVisible(use);
    await t.pumpAndSettle();
    await t.tap(use);
    await t.pumpAndSettle();
    final outcome = find.byType(TextField).last;
    await t.ensureVisible(outcome);
    await t.enterText(outcome, '更清楚了');
    await t.pumpAndSettle();

    final skip = t.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '不填写'));
    expect(skip.selected, isTrue);
    await t.tap(find.widgetWithText(ChoiceChip, '本人当时上头'));
    await t.pumpAndSettle();
    await tap(t, '提交效果反馈');

    expect(f.ratings.single.selfReport, 'overwhelmed');
  });
}
