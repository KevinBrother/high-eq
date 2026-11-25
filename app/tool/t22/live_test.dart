import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';
import 'package:http/http.dart' as http;
import '../../test/isolation_test.dart' show MemorySecret;

class _CountingTransport implements Transport {
  _CountingTransport(this.inner);

  final Transport inner;
  int createReplyDispatches = 0;

  @override
  Future<http.StreamedResponse> send(AppOp op, http.Request request) {
    if (op == AppOp.createReply) createReplyDispatches++;
    return inner.send(op, request);
  }

  @override
  void close() => inner.close();
}

void main() {
  test(
    'real T22 client ↔ T21 HTTP: consent, replay, feedback and terminal outcomes',
    () async {
      final origin = Uri.parse(Platform.environment['T22_ORIGIN']!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      final tmp = await Directory.systemTemp.createTemp('t22');
      addTearDown(() => tmp.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), tmp);
      final transport = _CountingTransport(HttpTransport(http.Client()));
      addTearDown(transport.close);
      final api = AppApi(origin, transport, sessions),
          wire = MobileEndpoints(api);
      final scope = await sessions.activate(
        Tokens.fromJson(
          await wire.login(
            body: {
              'credential': {
                'provider': 'apple',
                'proof': Platform.environment['T22_DEV_TICKET']!,
              },
              'age_confirmed': true,
              'terms_version': '2026-11',
              'privacy_version': '2026-11',
            },
          ),
        ),
      );
      final repo = ReplyService(api, scope);
      Json operation(String mode) => {
        'request_id': newRequestId(),
        'chat_text': 'T22-SYNTHETIC-$mode',
      };
      Future<int> remaining() async =>
          ((await wire.getEntitlements(scope: scope))['allowances'] as List)
                  .singleWhere((v) => v['feature'] == 'reply')['remaining']
              as int;
      Matcher localAuthorizationChanged() => throwsA(
        isA<ReplyAuthorizationChanged>().having(
          (e) => e.contact,
          'contact',
          false,
        ),
      );
      Matcher serverForbidden() => throwsA(
        isA<ApiFailure>()
            .having((e) => e.status, 'status', 403)
            .having((e) => e.code, 'code', 'forbidden')
            .having((e) => e.retryable, 'retryable', false)
            .having((e) => e.operation, 'operation', AppOp.createReply),
      );

      final normal = operation('NORMAL');
      final before = await remaining();
      expect(await repo.allowed(), false);
      final localRejectDispatches = transport.createReplyDispatches;
      await expectLater(repo.analyze(normal), localAuthorizationChanged());
      expect(
        transport.createReplyDispatches,
        localRejectDispatches,
        reason: '本地授权拒绝不得派发正文',
      );

      // Bypass the client guard to prove the server still rejects a request
      // that reaches it without a reply-consent decision.
      final directRejectDispatches = transport.createReplyDispatches;
      await expectLater(
        wire.createReply(scope: scope, body: operation('DIRECT')),
        serverForbidden(),
      );
      expect(
        transport.createReplyDispatches,
        directRejectDispatches + 1,
        reason: '服务端未授权检查必须实际收到一次正文请求',
      );

      await repo.grant();
      expect(await repo.allowed(), true);
      final r = await repo.analyze(normal) as Approved;
      expect((await repo.analyze(normal) as Approved).id, r.id);
      await repo.feedback(r.id, 1, '合成反馈：时间更明确。', 'not_overwhelmed');
      expect(await repo.analyze(operation('CRISIS')), isA<Crisis>());
      await expectLater(
        repo.analyze(operation('OUTAGE')),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.code,
            'code',
            'moderation_unavailable',
          ),
        ),
      );
      expect(await remaining(), before - 1);

      expect(
        await wire.setConsent(
          scope: scope,
          purpose: 'reply_chat_import',
          body: {'granted': false, 'version': '2026-11-reply'},
        ),
        containsPair('granted', false),
      );
      expect(await repo.allowed(), false);
      final withdrawnDispatches = transport.createReplyDispatches;
      await expectLater(
        repo.analyze(operation('AFTER_WITHDRAWAL')),
        localAuthorizationChanged(),
      );
      expect(
        transport.createReplyDispatches,
        withdrawnDispatches,
        reason: '撤回后本地授权拒绝不得派发正文',
      );
      expect(await remaining(), before - 1);
    },
  );
}
