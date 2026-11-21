import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart';
import 'package:high_eq/features/replies/repository.dart';
import 'package:high_eq/features/replies/result.dart';
import 'package:http/http.dart' as http;
import '../../test/isolation_test.dart' show MemorySecret;

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
      final transport = HttpTransport(http.Client());
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
      final normal = operation('NORMAL');
      final before = await remaining();
      expect(await repo.allowed(), false);
      await expectLater(
        repo.analyze(normal),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
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
    },
  );
}
