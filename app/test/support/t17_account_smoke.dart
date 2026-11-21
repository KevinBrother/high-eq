import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/onboarding/repository.dart';
import 'package:http/http.dart' as http;

import '../isolation_test.dart' show MemorySecret;

void main() {
  test(
    'T05 development: three identities, assessment consent and sign-out',
    () async {
      final port = int.parse(Platform.environment['T17_LOCAL_PORT']!);
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), dir);
      final transport = HttpTransport(http.Client());
      addTearDown(transport.close);
      final api = AppApi(Uri.http('127.0.0.1:$port'), transport, sessions);
      final wire = MobileEndpoints(api);
      final users = <String>{};
      for (final provider in ['phone', 'apple', 'wechat']) {
        const phone = '+12025550121'; // Fictional NANP number; dev SMS only.
        if (provider == 'phone') {
          expect((await wire.requestCode(body: {'phone': phone}))['ok'], true);
        }
        final proof = provider == 'phone'
            ? '000000'
            : Platform.environment['T17_${provider.toUpperCase()}_TICKET']!;
        final tokens = Tokens.fromJson(
          await wire.login(
            body: {
              'age_confirmed': true,
              'privacy_version': policyVersion,
              'terms_version': policyVersion,
              'credential': {
                'provider': provider,
                'proof': proof,
                if (provider == 'phone') 'phone': phone,
              },
            },
          ),
        );
        expect(users.add(tokens.account), true);
        final scope = await sessions.activate(tokens);
        final book = AssessmentBook(api, scope);
        expect(await book.allowed(), false);
        await book.grant();
        expect(await book.allowed(), true);
        if (Platform.environment['T17_TEST_RIGHTS'] == '1') {
          final rights = await wire.getEntitlements(scope: scope);
          expect(rights['tier'], 'free');
          expect(rights['max_active_contacts'], 1);
        }
        if (Platform.environment['T17_TEST_ASSESSMENT'] == '1') {
          expect(await book.latest(), isNull);
          final instrument = await book.instrument();
          final answers = [
            for (final n in [1, 3, 5, 7]) ...List.filled(4, n),
          ];
          final result = await book.submit(instrument['version'], answers);
          expect(result['total']['display'], 50);
          expect(result['dimensions']['ROE']['level'], 'L5');
          expect((await book.latest())?['id'], result['id']);
          await expectLater(
            book.submit(instrument['version'], answers),
            throwsA(
              isA<ApiFailure>()
                  .having((e) => e.status, 'status', 409)
                  .having(
                    (e) => e.retryAt?.toUtc(),
                    'retry_at',
                    DateTime.parse(result['next_eligible_at']).toUtc(),
                  ),
            ),
          );
        }
        await wire.setConsent(
          scope: scope,
          purpose: 'assessment',
          body: {'granted': false, 'version': policyVersion},
        );
        expect(await book.allowed(), false);
        await api.logout(scope);
        expect(sessions.active, isNull);
      }
    },
  );
}
