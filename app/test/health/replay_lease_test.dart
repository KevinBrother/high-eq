import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/sync.dart';
import 'package:high_eq/features/health/windows.dart';

import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

class _ReplayPort implements HealthPort {
  bool osQueryable = true;
  bool requestResult = true;
  int prompts = 0;
  int reads = 0;
  int stops = 0;

  @override
  Future<String?> source() async => 'health_connect';

  @override
  Future<bool> queryable() async => osQueryable;

  @override
  Future<bool> request({void Function()? onSystemPrompt}) async {
    prompts++;
    onSystemPrompt?.call();
    return requestResult;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<List<List>> read(int from, int to) async {
    reads++;
    return const [];
  }
}

void main() {
  late Directory dir;
  late Sessions sessions;
  late AccountScope a;
  late AppApi api;
  late _ReplayPort port;
  late HealthSync sync;
  late Handler handler;
  late bool member;
  late bool serverGranted;
  late String grant;
  late int now;
  late int consentWrites;
  late int uploads;

  Map<String, dynamic> consentRecord() => {
    'purpose': 'health',
    'version': '2026-11',
    'granted': serverGranted,
    'updated_at': grant,
  };

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('t28-replay-lease');
    addTearDown(() => dir.delete(recursive: true));
    sessions = Sessions(MemorySecret(), dir);
    a = await sessions.activate(tokens('A'));
    now = 1800000000000;
    grant = DateTime.fromMillisecondsSinceEpoch(
      now,
      isUtc: true,
    ).toIso8601String();
    member = true;
    serverGranted = true;
    consentWrites = 0;
    uploads = 0;
    port = _ReplayPort();
    handler = Handler();
    handler.handle = (op, req) async {
      switch (op) {
        case AppOp.setConsent:
          serverGranted = jsonDecode(req.body)['granted'] as bool;
          if (serverGranted) {
            consentWrites++;
            grant = DateTime.fromMillisecondsSinceEpoch(
              now + consentWrites,
              isUtc: true,
            ).toIso8601String();
          }
          return response(consentRecord());
        case AppOp.listConsents:
          return response({
            'items': [consentRecord()],
          });
        case AppOp.getEntitlements:
          return response({
            'tier': member ? 'member' : 'free',
            'expires_at': DateTime.fromMillisecondsSinceEpoch(
              now + Duration.millisecondsPerDay,
              isUtc: true,
            ).toIso8601String(),
          });
        case AppOp.uploadWindow:
          uploads++;
          return response({});
        case AppOp.logout:
          return response({});
        default:
          throw StateError('unexpected $op');
      }
    };
    api = AppApi(Uri.https('example.invalid'), handler, sessions);
    sync = HealthSync(api, a, ConsentGate(api), port, clock: () => now);
    addTearDown(sync.close);
  });

  Future<HealthReplayLease> enableAndLease() async {
    await sync.enable();
    final lease = await sync.replayLease();
    expect(lease, isNotNull);
    return lease!;
  }

  test(
    'returns the persisted collection boundary without collecting',
    () async {
      final lease = await enableAndLease();
      final state = await sync.state();
      final reads = port.reads;
      final prompts = port.prompts;
      final writes = consentWrites;

      expect(lease.collectionFrom, ceilSlot(state['collection_from'] as int));
      expect(lease.isCurrent(), isTrue);
      expect((await sync.replayLease())?.collectionFrom, lease.collectionFrom);
      expect(
        [port.reads, port.prompts, consentWrites, uploads],
        [reads, prompts, writes, 0],
      );
      expect(await sync.state(), state);
    },
  );

  test('fails closed for a missing remote grant without reading', () async {
    final loaded = await enableAndLease();
    serverGranted = false;

    expect(await sync.replayLease(), isNull);
    expect(loaded.isCurrent(), isFalse);
    expect(port.reads, 0);
    expect(uploads, 0);
  });

  for (final denied in [
    'OS access',
    'membership',
    'remote grant stamp',
    'serialized paid-through',
  ]) {
    test(
      '$denied denial invalidates the loaded lease without playback',
      () async {
        final lease = await enableAndLease();
        switch (denied) {
          case 'OS access':
            port.osQueryable = false;
          case 'membership':
            member = false;
          case 'remote grant stamp':
            grant = DateTime.fromMillisecondsSinceEpoch(
              now + Duration.millisecondsPerHour,
              isUtc: true,
            ).toIso8601String();
          case 'serialized paid-through':
            now += 2 * Duration.millisecondsPerDay;
        }

        final deniedLease = await sync.replayLease();
        expect(deniedLease, isNull);
        expect(lease.isCurrent(), isFalse);
        expect(port.reads, 0);
        expect(uploads, 0);
      },
    );
  }

  test('denial prevents a queued replay start from reaching native', () async {
    final lease = await enableAndLease();
    port.osQueryable = false;
    expect(await sync.replayLease(), isNull);

    final release = Completer<void>();
    var nativeStarts = 0;
    Future<void> queuedStart() async {
      await release.future;
      if (lease.isCurrent()) nativeStarts++;
    }

    final queued = queuedStart();
    release.complete();
    await queued;
    expect(nativeStarts, 0);
  });

  test('account switch rejects a replay check already in flight', () async {
    await sync.enable();
    final started = Completer<void>();
    final release = Completer<void>();
    final normal = handler.handle;
    handler.handle = (op, req) async {
      if (op != AppOp.listConsents) return normal(op, req);
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
      return response({
        'items': [consentRecord()],
      });
    };

    final checking = sync.replayLease();
    await started.future.timeout(const Duration(seconds: 1));
    await sessions.activate(tokens('B'));
    release.complete();

    expect(await checking, isNull);
  });

  test('withdrawal rejects a replay check already in flight', () async {
    await sync.enable();
    final started = Completer<void>();
    final release = Completer<void>();
    final normal = handler.handle;
    handler.handle = (op, req) async {
      if (op != AppOp.listConsents) return normal(op, req);
      if (!started.isCompleted) {
        started.complete();
        await release.future;
      }
      return response({
        'items': [consentRecord()],
      });
    };

    final checking = sync.replayLease();
    await started.future.timeout(const Duration(seconds: 1));
    final withdrawing = sync.withdraw();
    release.complete();

    expect(await checking, isNull);
    await withdrawing;
    expect(await sync.replayLease(), isNull);
  });

  test('suspend and resume invalidate a queued old start', () async {
    final lease = await enableAndLease();
    final release = Completer<void>();
    var nativeStarts = 0;

    Future<void> queuedStart() async {
      await release.future;
      if (lease.isCurrent()) nativeStarts++;
    }

    final queued = queuedStart();
    sync.suspend();
    sync.resume();
    release.complete();
    await queued;

    expect(nativeStarts, 0);
    expect(lease.isCurrent(), isFalse);
    expect(await sync.replayLease(), isNull);
  });

  test('account switch invalidates the lease and its queued start', () async {
    final lease = await enableAndLease();
    final release = Completer<void>();
    var nativeStarts = 0;

    Future<void> queuedStart() async {
      await release.future;
      if (lease.isCurrent()) nativeStarts++;
    }

    final queued = queuedStart();
    await sessions.activate(tokens('B'));
    release.complete();
    await queued;

    expect(nativeStarts, 0);
    expect(lease.isCurrent(), isFalse);
    expect(await sync.replayLease(), isNull);
    expect(port.reads, 0);
    expect(uploads, 0);
  });

  test(
    'withdrawal invalidates the lease and a late start stays rejected',
    () async {
      final lease = await enableAndLease();
      final release = Completer<void>();
      var nativeStarts = 0;

      Future<void> queuedStart() async {
        await release.future;
        if (lease.isCurrent()) nativeStarts++;
      }

      final queued = queuedStart();
      await sync.withdraw();
      release.complete();
      await queued;

      expect(nativeStarts, 0);
      expect(lease.isCurrent(), isFalse);
      expect(await sync.replayLease(), isNull);
      expect(await sync.state(), {'mode': 'off'});
      expect(port.reads, 0);
      expect(uploads, 0);
    },
  );

  test('re-enable with a new grant invalidates an old queued start', () async {
    final oldLease = await enableAndLease();
    final release = Completer<void>();
    var oldNativeStarts = 0;

    Future<void> queuedOldStart() async {
      await release.future;
      if (oldLease.isCurrent()) oldNativeStarts++;
    }

    final queued = queuedOldStart();
    await sync.enable();
    final renewedLease = await sync.replayLease();

    expect(oldLease.isCurrent(), isFalse);
    expect(renewedLease, isNotNull);
    expect(renewedLease!.isCurrent(), isTrue);
    release.complete();
    await queued;
    expect(oldNativeStarts, 0);
  });

  test(
    'replayChanges invalidates listeners immediately on local stop',
    () async {
      final lease = await enableAndLease();
      final changes = <int>[];
      void changed() => changes.add(sync.replayChanges.value);
      sync.replayChanges.addListener(changed);
      addTearDown(() => sync.replayChanges.removeListener(changed));

      final before = sync.replayChanges.value;
      sync.suspend();
      expect(sync.replayChanges.value, greaterThan(before));
      expect(lease.isCurrent(), isFalse);
      expect(changes, isNotEmpty);
    },
  );

  test('a delayed denial cannot invalidate a newer approved lease', () async {
    await sync.enable();
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    var consentReads = 0;
    final normal = handler.handle;
    handler.handle = (op, req) async {
      if (op != AppOp.listConsents) return normal(op, req);
      consentReads++;
      if (consentReads == 1) {
        firstStarted.complete();
        await releaseFirst.future;
        return response({
          'items': [
            {
              'purpose': 'health',
              'version': '2026-11',
              'granted': false,
              'updated_at': grant,
            },
          ],
        });
      }
      return response({
        'items': [consentRecord()],
      });
    };

    final older = sync.replayLease();
    await firstStarted.future.timeout(const Duration(seconds: 1));
    final approved = await sync.replayLease();
    expect(approved, isNotNull);
    expect(approved!.isCurrent(), isTrue);

    releaseFirst.complete();
    expect(await older, isNull);
    expect(approved.isCurrent(), isTrue);
  });
}
