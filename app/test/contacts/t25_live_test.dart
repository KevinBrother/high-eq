import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/repository.dart';
import 'package:http/http.dart' as http;

class _VolatileSecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? v) async {
    value = v;
  }
}

// Opt-in only. The shell harness owns and removes the isolated development service.
void main() {
  final ticket = Platform.environment['T25_DEV_TICKET'];
  test(
    'T18 ApiContacts ↔ T25: disposable account over real HTTP',
    () async {
      final origin = Uri.parse(Platform.environment['T25_ORIGIN']!);
      expect(origin.scheme, 'http');
      expect(origin.host, '127.0.0.1');
      final dir = await Directory.systemTemp.createTemp('t25-scope-');
      addTearDown(() => dir.delete(recursive: true));
      final sessions = Sessions(_VolatileSecret(), dir);
      final wire = HttpTransport(http.Client());
      addTearDown(wire.close);
      final api = MobileEndpoints(AppApi(origin, wire, sessions));
      final scope = await sessions.activate(
        Tokens.fromJson(
          await api.login(
            body: {
              'credential': {'provider': 'apple', 'proof': ticket},
              'age_confirmed': true,
              'terms_version': '2026-11',
              'privacy_version': '2026-11',
            },
          ),
        ),
      );
      final repo = ApiContacts(api, scope);
      final qs = await repo.questions();
      expect(qs.length, inInclusiveRange(5, 8));
      final form = {
        'nickname': '合成手记',
        'scene': 'work',
        'answers': [
          for (final q in qs) {'question_id': q.id, 'answer': '还不确定'},
        ],
      };
      await expectLater(
        repo.save(form),
        throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 403)),
      );
      // Real T05 grant, not a UI checkbox or a mock permission.
      await api.setConsent(
        scope: scope,
        purpose: 'contacts',
        body: {'version': 'v1', 'granted': true},
      );
      await repo.save(form);
      final book = await repo.load();
      final c = book.people.single;
      expect(book.usable(c), isTrue);
      expect(book.canAdd, isFalse);
      await repo.choose(c.id);
      await repo.save({'nickname': '合成改名', 'scene': 'friends'}, id: c.id);
      expect((await repo.load()).people.single.name, '合成改名');
      await repo.remove(c.id);
      expect((await repo.load()).people, isEmpty);
    },
    skip: ticket == null
        ? 'Run server/tests/t25-t18.sh with Docker and Flutter'
        : false,
  );
}
