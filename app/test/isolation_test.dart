import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/session.dart';

class MemorySecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? next) async => value = next;
}

Tokens tokens(String who, [String access = 'access']) => Tokens(
  who,
  access,
  'refresh',
  DateTime.now().toUtc().add(const Duration(hours: 1)),
);

void main() {
  test(
    'remove recordings older than 3 days before exposing restored account',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final secret = MemorySecret();
      final s = Sessions(secret, dir);
      final a = await s.activate(tokens('A'));
      await s.put(a, CacheKind.recording, 'old', [1]);
      await (dir.listSync().single as File).setLastModified(
        DateTime.now().subtract(const Duration(days: 4)),
      );
      final next = Sessions(secret, dir);
      await next.restore();
      expect(dir.listSync(), isEmpty);
      expect(await next.get(next.active!, CacheKind.recording, 'old'), isNull);
    },
  );
  test(
    'logout destroys encrypted caches, invalidates queued A work even after restart',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final secret = MemorySecret();
      var sessions = Sessions(secret, dir);
      await sessions.restore();
      final a = await sessions.activate(tokens('A'));
      for (final kind in CacheKind.values) {
        await sessions.put(a, kind, 'last', utf8.encode('secret-from-A'));
      }
      for (final file in dir.listSync().whereType<File>()) {
        expect(
          latin1.decode(await file.readAsBytes()),
          isNot(contains('secret-from-A')),
        );
      }
      sessions = Sessions(secret, dir);
      await sessions.restore();
      final restored = sessions.active!;
      expect(
        utf8.decode((await sessions.get(restored, CacheKind.queue, 'last'))!),
        'secret-from-A',
      );
      final clearing = sessions.clear();
      expect(() => sessions.require(restored), throwsA(isA<SessionChanged>()));
      await clearing;
      expect(secret.value, isNull);
      expect(dir.listSync(), isEmpty);
      final b = await sessions.activate(tokens('B'));
      for (final kind in CacheKind.values) {
        expect(await sessions.get(b, kind, 'last'), isNull);
        await expectLater(
          sessions.put(restored, kind, 'late', [1]),
          throwsA(isA<SessionChanged>()),
        );
      }
    },
  );
}
