import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/core/transport.dart';
import 'package:high_eq/features/onboarding/repository.dart';
import '../isolation_test.dart' show MemorySecret, tokens;

void main() {
  test(
    'continuation survives cold restart but not logout/relogin or account switch',
    () async {
      final root = await Directory.systemTemp.createTemp();
      addTearDown(() => root.delete(recursive: true));
      final vault = MemorySecret();
      AssessmentBook book(Sessions s) => AssessmentBook(
        AppApi(Uri.https('example.invalid'), ExampleTransport(), s),
        s.active!,
      );
      var sessions = Sessions(vault, root);
      await sessions.activate(tokens('A'));
      final a = book(sessions);
      final draft = {
        'version': 'test-version',
        'answers': [3, 7],
        'index': 2,
        'scene': 'family',
      };
      await a.save('draft', draft);
      expect(
        latin1.decode(await (root.listSync().single as File).readAsBytes()),
        isNot(contains('family')),
      );
      sessions = Sessions(vault, root);
      await sessions.restore();
      final restored = book(sessions);
      expect(await restored.read('draft'), draft);
      await sessions.clear();
      await sessions.activate(tokens('B'));
      expect(await book(sessions).read('draft'), isNull);
      await expectLater(restored.read('draft'), throwsA(isA<SessionChanged>()));
    },
  );
}
