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
import 'package:high_eq/features/contacts/purpose.dart';
import 'package:high_eq/features/contacts/routes.dart';
import 'package:http/http.dart' as http;

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret;
import '../support/real_async.dart';

const _a = '同事 α';
const _second = '同事 β';
const _b = '另一会话 α';
const _material = '合成材料：约时间讨论进度';
const _updated = '画像已更新，仅供参考。';
const _retry = '重试获取结果';
const _fixedSafety =
    '听起来你现在可能正经历很难受的事。这里不适合继续练习，建议你马上联系专业的人：全国心理援助热线 12356；如果有人身危险，请立即拨打 110 或 120。';

Map<String, dynamic> _profile(String summary) => {
  'summary': summary,
  'big_five': [],
  'conflict_style': {'label': '合作型', 'confidence': 0.7},
  'attachment': null,
};

Map<String, dynamic> _contact(String id, String name, String summary) => {
  'id': id,
  'nickname': name,
  'scene': 'work',
  'editable': true,
  'profile': _profile(summary),
};

typedef _Post = ({String? auth, String path, Map<String, dynamic> body});

class _Fixture {
  _Fixture(this.sessions) {
    api = AppApi(Uri.https('independent-review.invalid'), wire, sessions);
    wire.handle = (op, req) async {
      final auth = req.headers['Authorization'];
      switch (op) {
        case AppOp.listContacts:
          return response({
            'items': [
              if (auth == 'Bearer b')
                _contact('alpha', _b, '另一会话的原画像')
              else ...[
                _contact('alpha', _a, '甲的原画像'),
                _contact('beta', _second, '乙的原画像'),
              ],
            ],
            'next_cursor': null,
          });
        case AppOp.getEntitlements:
          return response({
            'tier': 'member',
            'max_active_contacts': 10,
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(days: 1))
                .toIso8601String(),
          });
        case AppOp.listConsents:
          return response({
            'items': [
              for (final purpose in ContactPurpose.values)
                {
                  'purpose': purpose.wire,
                  'version': contactNoticeVersion,
                  'granted': purpose != ContactPurpose.chatImport || granted,
                  'updated_at': purpose == ContactPurpose.contacts
                      ? '2026-11-24T10:00:00Z'
                      : '2026-11-24T10:00:0${grantRevision}Z',
                },
            ],
            'next_cursor': null,
          });
        case AppOp.refreshTokens:
          if (withdrawOnRefresh) {
            granted = false;
            grantRevision++;
          }
          return response(_tokens('A', 'a2').toJson());
        case AppOp.inferProfile:
          final post = (
            auth: auth,
            path: req.url.path,
            body: jsonDecode(req.body) as Map<String, dynamic>,
          );
          posts.add(post);
          return onPost(post, posts.length);
        default:
          fail('Unexpected request ${op.name}');
      }
    };
  }

  final Sessions sessions;
  final wire = Handler();
  late final AppApi api;
  final posts = <_Post>[];
  bool granted = true;
  int grantRevision = 0;
  bool withdrawOnRefresh = false;
  late FutureOr<http.StreamedResponse> Function(_Post, int) onPost;
}

Tokens _tokens(String account, String access) => Tokens(
  account,
  access,
  'synthetic-refresh',
  DateTime.now().toUtc().add(const Duration(hours: 1)),
);

Future<_Fixture> _mount(WidgetTester tester) async {
  final fixture = await runRealAsync(tester, () async {
    final fixtureRoot = await Directory(
      'build/review-fixtures',
    ).create(recursive: true);
    final dir = await fixtureRoot.createTemp('sessions-');
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    await sessions.activate(_tokens('A', 'a'));
    return _Fixture(sessions);
  });
  final container = ProviderContainer(
    overrides: [apiProvider.overrideWith((_) async => fixture.api)],
  );
  addTearDown(container.dispose);
  await container.read(apiProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ContactRoute(sceneOnly: false)),
    ),
  );
  await _until(tester, _a);
  await _tap(tester, _a);
  return fixture;
}

Future<void> _until(WidgetTester tester, String text) => pumpRealAsyncUntil(
  tester,
  () => find.text(text).evaluate().isNotEmpty,
  reason: 'Missing text: $text',
);

Future<void> _tap(WidgetTester tester, String text, {int count = 1}) async {
  final target = find.text(text).last;
  await tester.ensureVisible(target);
  await tester.pump();
  for (var i = 0; i < count; i++) {
    await tester.tap(target);
  }
  await tester.pump();
}

Future<void> _submit(WidgetTester tester, {int clicks = 1}) async {
  await _tap(tester, '导入聊天片段');
  await _until(tester, '补充一次对话');
  await _tap(tester, '我已了解，并有权分享这段内容');
  await tester.enterText(find.byType(TextField), _material);
  await tester.pump();
  await _tap(tester, '提交片段', count: clicks);
}

Future<void> _waitPosts(WidgetTester tester, _Fixture fixture, int count) =>
    pumpRealAsyncUntil(
      tester,
      () => fixture.posts.length >= count,
      reason: 'Expected $count infer requests',
    );

http.StreamedResponse _pending(_Post post) => response({
  'request_id': post.body['request_id'],
  'status': 'in_progress',
}, 202);

void main() {
  testWidgets('real route 202, timeout, duplicate taps, retry and late reply', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final late = Completer<http.StreamedResponse>();
    fixture.onPost = (post, count) => switch (count) {
      1 => _pending(post),
      2 => late.future,
      3 => response(_profile('甲的新画像')),
      _ => _pending(post),
    };
    await _submit(tester, clicks: 2);
    await _waitPosts(tester, fixture, 1);
    await pumpRealAsyncUntil(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      reason: 'The 202 submission did not settle',
    );
    expect(fixture.posts, hasLength(1));
    expect(find.text(_updated), findsNothing);
    await _until(tester, _retry);
    expect(find.textContaining('甲的原画像'), findsOneWidget);

    await _tap(tester, _retry, count: 2);
    await _waitPosts(tester, fixture, 2);
    expect(fixture.posts, hasLength(2));
    await tester.pump(const Duration(seconds: 21));
    await _until(tester, '连接未完成，可用原请求重试。');
    await _tap(tester, _retry);
    await _until(tester, _updated);
    expect(fixture.posts, hasLength(3));
    final post = fixture.posts.first;
    for (final retry in fixture.posts.skip(1)) {
      expect(retry.auth, post.auth);
      expect(retry.path, post.path);
      expect(retry.body, post.body);
    }
    expect(post.auth, 'Bearer a');
    expect(post.path, '/v1/contacts/alpha/infer');
    expect(post.body['chat_text'], _material);

    late.complete(response(_profile('超时请求的旧画像')));
    await tester.pumpAndSettle();
    expect(find.textContaining('超时请求的旧画像'), findsNothing);
    expect(find.textContaining('甲的新画像'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await _tap(tester, _second);
    expect(find.textContaining('乙的原画像'), findsOneWidget);
    expect(find.textContaining('甲的新画像'), findsNothing);
    await _submit(tester);
    await _until(tester, _retry);
    expect(fixture.posts, hasLength(4));
    expect(fixture.posts.last.path, '/v1/contacts/beta/infer');
    expect(fixture.posts.last.body['chat_text'], _material);
    expect(
      fixture.posts.last.body['request_id'],
      isNot(post.body['request_id']),
    );
  });

  testWidgets(
    'real route Safety keeps Profile and allows a fresh same-text id',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.onPost = (post, count) => count == 1
          ? response({'safety': true, 'message': _fixedSafety})
          : _pending(post);
      await _submit(tester);
      await _until(tester, _fixedSafety);
      expect(find.text(_updated), findsNothing);
      expect(find.textContaining('甲的原画像'), findsOneWidget);
      expect(find.text(_retry), findsNothing);
      await _submit(tester);
      await _until(tester, _retry);
      expect(fixture.posts, hasLength(2));
      expect(fixture.posts.last.body['chat_text'], _material);
      expect(
        fixture.posts.last.body['request_id'],
        isNot(fixture.posts.first.body['request_id']),
      );
    },
  );

  testWidgets('withdraw then regrant fences the old unregistered request', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    fixture.onPost = (post, count) =>
        count == 1 ? response({'code': 'unavailable'}, 503) : _pending(post);
    await _submit(tester);
    await _until(tester, _retry);
    fixture.granted = false;
    fixture.grantRevision++;
    fixture.granted = true;
    fixture.grantRevision++;
    await _tap(tester, _retry);
    await pumpRealAsyncUntil(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      reason: 'Regrant retry did not settle',
    );
    expect(
      fixture.posts.skip(1).map((post) => post.body),
      isEmpty,
      reason: 'The old chat_text must stay client-side after regrant.',
    );
  });

  testWidgets('401 refresh must not replay after withdrawal', (tester) async {
    final fixture = await _mount(tester);
    fixture.withdrawOnRefresh = true;
    fixture.onPost = (_, count) => count == 1
        ? response({'code': 'unauthenticated'}, 401)
        : response({'code': 'forbidden'}, 403);
    await _submit(tester);
    await pumpRealAsyncUntil(
      tester,
      () =>
          fixture.sessions.require(fixture.sessions.active!).access == 'a2' &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
      reason: 'Refresh and guarded dispatch did not settle',
    );
    expect(fixture.granted, isFalse);
    expect(
      fixture.posts.skip(1).map((post) => (post.auth, post.body)),
      isEmpty,
      reason: 'A refreshed token must not replay the withdrawn chat_text.',
    );
  });

  testWidgets('late Profile after withdrawal does not change the UI', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    final late = Completer<http.StreamedResponse>();
    fixture.onPost = (_, _) => late.future;
    await _submit(tester);
    await _waitPosts(tester, fixture, 1);
    final completedOnServer = response(_profile('撤权前完成的迟到画像'));
    fixture.granted = false;
    fixture.grantRevision++;
    late.complete(completedOnServer);
    await pumpRealAsyncUntil(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      reason: 'Late consent response did not settle',
    );
    expect(find.textContaining('撤权前完成的迟到画像'), findsNothing);
    expect(find.text(_updated), findsNothing);
  });

  testWidgets(
    'draft from the old grant is fenced and a fresh form can submit',
    (tester) async {
      final fixture = await _mount(tester);
      fixture.onPost = (_, _) => response(_profile('合法的新画像'));
      await _tap(tester, '导入聊天片段');
      await _until(tester, '补充一次对话');
      await _tap(tester, '我已了解，并有权分享这段内容');
      await tester.enterText(find.byType(TextField), _material);
      await tester.pump();
      expect(fixture.posts, isEmpty);

      fixture.granted = false;
      fixture.grantRevision++;
      fixture.granted = true;
      fixture.grantRevision++;
      await _tap(tester, '提交片段');
      await pumpRealAsyncUntil(
        tester,
        () =>
            fixture.posts.isNotEmpty ||
            find.text('授权记录已变化，已清除旧片段，请重新导入。').evaluate().isNotEmpty,
        reason: 'Submit under the replacement grant did not settle',
      );

      expect(
        fixture.posts,
        isEmpty,
        reason: 'The open draft predates the replacement grant.',
      );
      expect(find.text('授权记录已变化，已清除旧片段，请重新导入。'), findsOneWidget);
      expect(find.textContaining(_material), findsNothing);

      await _submit(tester);
      await _until(tester, _updated);
      expect(fixture.posts, hasLength(1));
      expect(fixture.posts.single.body['chat_text'], _material);
    },
  );

  testWidgets('non-contract Safety message must not be displayed', (
    tester,
  ) async {
    final fixture = await _mount(tester);
    fixture.onPost = (_, _) => response({'safety': true, 'message': _material});
    await _submit(tester);
    await pumpRealAsyncUntil(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      reason: 'Malformed Safety response did not settle',
    );
    expect(
      find.text(_material),
      findsNothing,
      reason: 'Only the fixed contract Safety message may be displayed.',
    );
    expect(find.text(_updated), findsNothing);
  });

  for (final account in ['A', 'B']) {
    testWidgets('replacement lease $account rejects old pending Profile', (
      tester,
    ) async {
      final fixture = await _mount(tester);
      final late = Completer<http.StreamedResponse>();
      fixture.onPost = (_, _) => late.future;
      await _submit(tester);
      await _waitPosts(tester, fixture, 1);
      await runRealAsync(
        tester,
        () => fixture.sessions.activate(_tokens(account, 'b')),
      );
      await _until(tester, _b);
      await _tap(tester, _b);
      late.complete(response(_profile('旧会话迟到画像')));
      await tester.pumpAndSettle();
      expect(find.textContaining('旧会话迟到画像'), findsNothing);
      expect(find.textContaining('另一会话的原画像'), findsOneWidget);
      expect(find.text(_retry), findsNothing);
      expect(find.text(_updated), findsNothing);
      expect(fixture.posts, hasLength(1));
    });
  }
}
