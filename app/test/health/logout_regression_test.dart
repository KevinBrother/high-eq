import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/sync.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

class _SyntheticPort implements HealthPort {
  bool granted = true;
  int reads = 0;

  @override
  Future<String?> source() async => 'health_connect';

  @override
  Future<bool> queryable() async => granted;

  @override
  Future<bool> request({void Function()? onSystemPrompt}) async => granted;

  @override
  Future<void> stop() async {}

  @override
  Future<List<List>> read(int from, int to) async {
    reads++;
    return [
      ['heart_rate', from, from, 68],
    ];
  }
}

class _FlakySecret implements SecretStore {
  String? value;
  int failReplaceCount = 0;
  int replaceCalls = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> replace(String? next) async {
    replaceCalls++;
    if (failReplaceCount > 0) {
      failReplaceCount--;
      throw const FileSystemException('injected secure storage failure');
    }
    value = next;
  }
}

void main() {
  test(
    'directory cleanup failure cannot restore credentials or A collection state',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final secret = MemorySecret();
      var failWipe = false;
      Future<void> wipe(Directory directory) async {
        if (failWipe) {
          throw const FileSystemException('injected directory cleanup failure');
        }
        if (await directory.exists()) await directory.delete(recursive: true);
        await directory.create(recursive: true);
      }

      final sessions = Sessions(secret, dir, wipeDirectory: wipe);
      final a = await sessions.activate(tokens('A'));
      await sessions.put(a, CacheKind.queue, HealthSync.key, utf8.encode('A'));
      await sessions.addWithdrawalIntent(a);

      failWipe = true;
      await expectLater(sessions.clear(), throwsA(isA<FileSystemException>()));
      expect(sessions.active, isNull);
      final raw = jsonDecode(secret.value!) as Map;
      expect(raw.containsKey('tokens'), false);
      expect(raw.containsKey('key'), false);
      expect(secret.value, isNot(contains(HealthSync.key)));

      final restored = Sessions(secret, dir);
      await restored.restore();
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(a), true);
      await expectLater(
        restored.get(a, CacheKind.queue, HealthSync.key),
        throwsA(isA<SessionChanged>()),
      );

      final b = await restored.activate(tokens('B'));
      expect(await restored.get(b, CacheKind.queue, HealthSync.key), isNull);
    },
  );

  test(
    'offline logout clears A queue; A reauth only withdraws and B cannot receive A',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final secret = MemorySecret();
      final sessions = Sessions(secret, dir);
      final a = await sessions.activate(tokens('A'));
      final handler = Handler();
      final api = AppApi(Uri.https('example.invalid'), handler, sessions);
      final port = _SyntheticPort();
      var now = 1800000000000;
      var granted = false;
      var offline = false;
      var failUpload = false;
      final uploaded = <Map>[];
      final stamp = DateTime.fromMillisecondsSinceEpoch(
        1800000000000,
        isUtc: true,
      ).toIso8601String();

      handler.handle = (op, req) async {
        if (offline) throw const SocketException('offline');
        switch (op) {
          case AppOp.setConsent:
            granted = jsonDecode(req.body)['granted'] as bool;
            return response({
              'purpose': 'health',
              'version': '2026-11',
              'granted': granted,
              'updated_at': stamp,
            });
          case AppOp.listConsents:
            return response({
              'items': [
                {
                  'purpose': 'health',
                  'version': '2026-11',
                  'granted': granted,
                  'updated_at': stamp,
                },
              ],
            });
          case AppOp.getEntitlements:
            return response({
              'tier': 'member',
              'expires_at': DateTime.fromMillisecondsSinceEpoch(
                now + 86400000,
                isUtc: true,
              ).toIso8601String(),
            });
          case AppOp.uploadWindow:
            if (failUpload) throw const SocketException('upload failed');
            uploaded.add(jsonDecode(req.body) as Map);
            return response({});
          case AppOp.logout:
            return response({});
          default:
            throw StateError('unexpected $op');
        }
      };

      final sync = HealthSync(api, a, ConsentGate(api), port, clock: () => now);
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      offline = true;
      await expectLater(sync.withdraw(), throwsA(isA<SocketException>()));

      final loggingOut = api.logout(a);
      expect(sessions.active, isNull);
      await expectLater(loggingOut, throwsA(isA<SocketException>()));
      await Future<void>.delayed(Duration.zero);
      expect(dir.listSync(), isEmpty);

      final restored = Sessions(secret, dir);
      await restored.restore();
      expect(restored.active, isNull);
      final restoredA = await restored.activate(tokens('A', 'A-new'));
      expect(
        await restored.get(restoredA, CacheKind.queue, HealthSync.key),
        isNull,
      );

      offline = false;
      failUpload = false;
      final aPort = _SyntheticPort();
      final aApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final aSync = HealthSync(
        aApi,
        restoredA,
        ConsentGate(aApi),
        aPort,
        clock: () => now,
      );
      await aSync.tick();
      expect(aPort.reads, 0);
      expect(granted, false);
      expect(uploaded, isEmpty);

      final b = await restored.activate(tokens('B', 'B-new'));
      final bPort = _SyntheticPort();
      final bApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final bSync = HealthSync(
        bApi,
        b,
        ConsentGate(bApi),
        bPort,
        clock: () => now,
      );
      await bSync.tick();
      expect(bPort.reads, 0);
      expect(uploaded, isEmpty);
    },
  );
  test(
    'setup tombstone is recovered after exhausted reads and never withdraws',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final secret = _FlakySecret();
      final sessions = Sessions(secret, dir);
      final a = await sessions.activate(tokens('A'));
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode({'mode': 'withdraw'})),
      );

      var granted = true;
      var setConsentCalls = 0;
      final stamp = DateTime.fromMillisecondsSinceEpoch(
        1800000000000,
        isUtc: true,
      ).toIso8601String();
      final handler = Handler();
      handler.handle = (op, req) async {
        switch (op) {
          case AppOp.listConsents:
            return response({
              'items': [
                {
                  'purpose': 'health',
                  'version': '2026-11',
                  'granted': granted,
                  'updated_at': stamp,
                },
              ],
              'next_cursor': null,
            });
          case AppOp.setConsent:
            setConsentCalls++;
            granted = jsonDecode(req.body)['granted'] as bool;
            return response({
              'purpose': 'health',
              'version': '2026-11',
              'granted': granted,
              'updated_at': stamp,
            });
          case AppOp.logout:
            return response({});
          default:
            throw StateError('unexpected $op');
        }
      };

      final restored = Sessions(
        secret,
        dir,
        readCache: (_) async =>
            throw const FileSystemException('persistent queue read failure'),
      );
      await restored.restore();
      final restoredScope = restored.active!;
      final api = AppApi(Uri.https('example.invalid'), handler, restored);
      final result = await api.logoutWithResult(restoredScope);
      expect(result.localCleanup, LogoutStatus.unconfirmed);
      expect(result.healthWithdrawal, LogoutHealthStatus.unconfirmed);
      expect(result.serverLogout, LogoutStatus.unconfirmed);

      expect(setConsentCalls, 0);
      expect(granted, true);
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      expect(restored.hasUnknownWithdrawal(restoredScope), false);
      expect(dir.listSync(), isNotEmpty);

      final next = Sessions(secret, dir);
      await next.restore();
      expect(next.active, isNull);
      expect(dir.listSync(), isEmpty);
      final aAgain = await next.activate(tokens('A', 'A-new'));
      expect(next.hasWithdrawalIntent(aAgain), false);
      expect(next.hasUnknownWithdrawal(aAgain), false);
      final aApi = AppApi(Uri.https('example.invalid'), handler, next);
      final aPort = _SyntheticPort();
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        aPort,
        clock: () => 1800000000000,
      );
      addTearDown(aSync.close);
      await aSync.tick();

      expect(setConsentCalls, 0);
      expect(granted, true);
      expect(aPort.reads, 0);
    },
  );

  test(
    'persistent cleanup failure preserves unknown evidence and never withdraws automatically',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final secret = _FlakySecret();
      final sessions = Sessions(secret, dir);
      final a = await sessions.activate(tokens('A'));
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode({'mode': 'on', 'cursor': 1})),
      );

      var granted = true;
      var setConsentCalls = 0;
      final handler = Handler();
      handler.handle = (op, req) async {
        switch (op) {
          case AppOp.listConsents:
            return response({
              'items': [
                {
                  'purpose': 'health',
                  'version': '2026-11',
                  'granted': granted,
                  'updated_at': '2026-11-23T00:00:00.000Z',
                },
              ],
              'next_cursor': null,
            });
          case AppOp.setConsent:
            setConsentCalls++;
            granted = jsonDecode(req.body)['granted'] as bool;
            return response({
              'purpose': 'health',
              'version': '2026-11',
              'granted': granted,
              'updated_at': '2026-11-23T00:00:00.000Z',
            });
          case AppOp.logout:
            return response({});
          default:
            throw StateError('unexpected $op');
        }
      };

      final restored = Sessions(secret, dir);
      await restored.restore();
      final aScope = restored.active!;
      secret.failReplaceCount = 99;
      await expectLater(
        AppApi(Uri.https('example.invalid'), handler, restored).logout(aScope),
        throwsA(isA<FileSystemException>()),
      );
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(aScope), false);
      expect(restored.hasUnknownWithdrawal(aScope), true);
      expect(dir.listSync(), isNotEmpty);

      final after = Sessions(secret, dir);
      await expectLater(after.restore(), throwsA(isA<FileSystemException>()));
      expect(after.active, isNull);
      expect(dir.listSync(), isNotEmpty);
      await expectLater(
        after.activate(tokens('B', 'B-access')),
        throwsA(isA<FileSystemException>()),
      );
      expect(after.active, isNull);
      expect(dir.listSync(), isNotEmpty);

      secret.failReplaceCount = 0;
      await after.restore();
      expect(after.active, isNull);
      expect(after.hasWithdrawalIntent(aScope), false);
      expect(after.hasUnknownWithdrawal(aScope), true);
      expect(dir.listSync(), isEmpty);

      final b = await after.activate(tokens('B', 'B-access'));
      expect(after.hasWithdrawalIntent(b), false);
      expect(after.hasUnknownWithdrawal(b), false);
      expect(after.hasUnknownWithdrawal(aScope), true);
      expect(await after.get(b, CacheKind.queue, HealthSync.key), isNull);

      final aAgain = await after.activate(tokens('A', 'A-new'));
      final aApi = AppApi(Uri.https('example.invalid'), handler, after);
      final aPort = _SyntheticPort();
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        aPort,
        clock: () => 1800000000000,
      );
      addTearDown(aSync.close);
      expect(await aSync.state(), {'mode': 'unknown'});
      await aSync.tick();

      expect(setConsentCalls, 0);
      expect(granted, true);
      expect(aPort.reads, 0);
      expect(after.hasUnknownWithdrawal(aAgain), true);
    },
  );

  test(
    'persistent cleanup failure preserves explicit evidence across restore, B switch, and A relogin',
    () async {
      final dir = await Directory.systemTemp.createTemp();
      addTearDown(() => dir.delete(recursive: true));
      final secret = _FlakySecret();
      final sessions = Sessions(secret, dir);
      final a = await sessions.activate(tokens('A'));
      final handler = Handler();
      var now = 1800000000000;
      var granted = false;
      var offline = false;
      var setConsentCalls = 0;
      final consentAuth = <String?>[];
      final stamp = DateTime.fromMillisecondsSinceEpoch(
        now,
        isUtc: true,
      ).toIso8601String();
      handler.handle = (op, req) async {
        if (offline) throw const SocketException('offline');
        switch (op) {
          case AppOp.getEntitlements:
            return response({
              'tier': 'member',
              'expires_at': DateTime.fromMillisecondsSinceEpoch(
                now + 86400000,
                isUtc: true,
              ).toIso8601String(),
            });
          case AppOp.listConsents:
            consentAuth.add(req.headers['Authorization']);
            return response({
              'items': [
                {
                  'purpose': 'health',
                  'version': '2026-11',
                  'granted': granted,
                  'updated_at': stamp,
                },
              ],
              'next_cursor': null,
            });
          case AppOp.setConsent:
            consentAuth.add(req.headers['Authorization']);
            setConsentCalls++;
            granted = jsonDecode(req.body)['granted'] as bool;
            return response({
              'purpose': 'health',
              'version': '2026-11',
              'granted': granted,
              'updated_at': stamp,
            });
          case AppOp.uploadWindow:
            return response({});
          case AppOp.logout:
            return response({});
          default:
            throw StateError('unexpected $op');
        }
      };

      final api = AppApi(Uri.https('example.invalid'), handler, sessions);
      final port = _SyntheticPort();
      final sync = HealthSync(api, a, ConsentGate(api), port, clock: () => now);
      addTearDown(sync.close);
      await sync.enable();
      expect(setConsentCalls, 1);
      setConsentCalls = 0;
      consentAuth.clear();
      now += 600000;
      secret.failReplaceCount = 1;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(granted, true);
      expect(dir.listSync(), isNotEmpty);

      final restored = Sessions(secret, dir);
      await restored.restore();
      final aScope = restored.active!;
      secret.failReplaceCount = 99;
      offline = true;
      await expectLater(
        AppApi(Uri.https('example.invalid'), handler, restored).logout(aScope),
        throwsA(isA<FileSystemException>()),
      );
      offline = false;
      expect(restored.active, isNull);
      expect(dir.listSync(), isNotEmpty);

      final after = Sessions(secret, dir);
      await expectLater(after.restore(), throwsA(isA<FileSystemException>()));
      expect(after.active, isNull);
      expect(dir.listSync(), isNotEmpty);
      await expectLater(
        after.activate(tokens('B', 'B-access')),
        throwsA(isA<FileSystemException>()),
      );
      expect(after.active, isNull);
      expect(dir.listSync(), isNotEmpty);

      secret.failReplaceCount = 0;
      await after.restore();
      expect(after.active, isNull);
      expect(after.hasWithdrawalIntent(aScope), true);
      expect(dir.listSync(), isEmpty);

      final b = await after.activate(tokens('B', 'B-access'));
      expect(after.hasWithdrawalIntent(b), false);
      expect(after.hasWithdrawalIntent(aScope), true);
      expect(await after.get(b, CacheKind.queue, HealthSync.key), isNull);
      final bApi = AppApi(Uri.https('example.invalid'), handler, after);
      final bPort = _SyntheticPort();
      final bSync = HealthSync(
        bApi,
        b,
        ConsentGate(bApi),
        bPort,
        clock: () => now,
      );
      addTearDown(bSync.close);
      await bSync.tick();
      expect(setConsentCalls, 0);
      expect(bPort.reads, 0);

      final aAgain = await after.activate(tokens('A', 'A-new'));
      final aApi = AppApi(Uri.https('example.invalid'), handler, after);
      final aPort = _SyntheticPort();
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        aPort,
        clock: () => now,
      );
      addTearDown(aSync.close);
      await aSync.tick();

      expect(setConsentCalls, 1);
      expect(granted, false);
      expect(aPort.reads, 0);
      expect(consentAuth, everyElement('Bearer A-new'));
      expect(after.hasWithdrawalIntent(aAgain), false);
    },
  );
}
