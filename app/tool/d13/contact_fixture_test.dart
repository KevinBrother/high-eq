import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/endpoints.g.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/contacts/purpose.dart';

import '../../test/client_test.dart' show Handler, response;
import '../../test/isolation_test.dart' show MemorySecret, tokens;
import 'contact_fixture.dart';

void main() {
  test('contact fixture leaves chat import for the first UI grant', () async {
    final dir = await Directory.systemTemp.createTemp('d13-fixture-test');
    addTearDown(() => dir.delete(recursive: true));
    final sessions = Sessions(MemorySecret(), dir);
    final scope = await sessions.activate(tokens('synthetic'));
    final grants = <String>{};
    final transport = Handler()
      ..handle = (op, request) async {
        switch (op) {
          case AppOp.setConsent:
            final purpose = request.url.pathSegments.last;
            final body = jsonDecode(request.body) as Json;
            final granted = body['granted'] as bool;
            if (granted) {
              grants.add(purpose);
            } else if (!grants.remove(purpose)) {
              // The service rejects withdrawal without a prior decision.
              return response({'code': 'invalid_argument'}, 400);
            }
            return response({
              'purpose': purpose,
              ...body,
              'updated_at': '2026-11-24T10:00:00Z',
            });
          case AppOp.createContact:
            expect(grants, {ContactPurpose.contacts.wire});
            return response({'id': 'synthetic-contact'});
          default:
            throw StateError('Unexpected contact fixture operation');
        }
      };
    final api = AppApi(Uri.https('offline.invalid'), transport, sessions);
    expect(
      await createFixtureContact(MobileEndpoints(api), scope),
      'synthetic-contact',
    );
    expect(grants, {ContactPurpose.contacts.wire});
  });
}
