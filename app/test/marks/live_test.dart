import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/models.dart' show newRequestId;
import 'package:high_eq/features/marks/book.dart';
import 'package:http/http.dart' as http;

class _Secret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? v) async {
    value = v;
  }
}

void main() {
  final ticket = Platform.environment['T32A_DEV_TICKET'];
  test(
    '移动端生成客户端 ↔ 真实标记 HTTP',
    () async {
      final origin = Uri.parse(Platform.environment['T32A_ORIGIN']!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      final dir = await Directory.systemTemp.createTemp('mark-fixture-');
      addTearDown(() => dir.delete(recursive: true));
      final wire = HttpTransport(http.Client());
      addTearDown(wire.close);
      final sessions = Sessions(_Secret(), dir);
      final app = AppApi(origin, wire, sessions);
      final api = MobileEndpoints(app);
      final scope = await sessions.activate(
        Tokens.fromJson(
          await api.login(
            body: {
              'credential': {'provider': 'apple', 'proof': ticket},
              'age_confirmed': true,
              'privacy_version': '2026-11',
              'terms_version': '2026-11',
            },
          ),
        ),
      );
      final b = MarkBook(app, scope);
      expect(await b.consented(), isFalse);
      await expectLater(
        b.create(newRequestId()),
        throwsA(isA<ApiFailure>().having((v) => v.status, 'status', 400)),
      );
      await b.grant();
      expect(await b.consented(), isTrue);
      final before = await api.getEntitlements(scope: scope);
      final k = newRequestId();
      final m = await b.create(k);
      expect((await b.create(k)).id, m.id);
      final edited = await b.edit(m.id, {'scene': 'social'});
      expect((await b.history()).items.single.review, edited.review);
      await b.bookmark(edited);
      expect(await b.bookmarked(edited), isTrue);
      expect(
        (await api.getEntitlements(scope: scope))['allowances'],
        before['allowances'],
      );
      await b.remove(m.id);
      expect((await b.history()).items, isEmpty);
      expect(await b.bookmarked(edited), isFalse);
    },
    skip: ticket == null ? 'Use server/tests/t32a-verify.sh' : false,
  );
}
