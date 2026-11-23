import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/health/huawei.dart';
import 'package:high_eq/features/health/platform.dart';
import 'package:high_eq/features/health/sync.dart';
import 'package:high_eq/features/health/windows.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

class Synthetic implements HealthPort {
  bool granted = true;
  int prompts = 0, promptStarts = 0, reads = 0;
  Completer<void>? hold;
  Completer<void>? requestStarted;
  Completer<void>? holdRequest;
  Completer<void>? promptStarted;
  Completer<void>? holdPrompt;
  List<List> Function(int from, int to)? rows;
  @override
  Future<String?> source() async => 'health_connect';
  @override
  Future<bool> queryable() async => granted;
  @override
  Future<bool> request({void Function()? onSystemPrompt}) async {
    prompts++;
    if (requestStarted?.isCompleted == false) requestStarted!.complete();
    await holdRequest?.future;
    onSystemPrompt?.call();
    promptStarts++;
    if (promptStarted?.isCompleted == false) promptStarted!.complete();
    await holdPrompt?.future;
    return granted;
  }

  @override
  Future<void> stop() async {}
  @override
  Future<List<List>> read(int from, int to) async {
    reads++;
    await hold?.future;
    return rows?.call(from, to) ??
        [
          ['heart_rate', from, from, 68],
        ];
  }
}

class FlakySessions extends Sessions {
  FlakySessions(super.secret, super.directory);
  bool failNextPut = false;
  int putCalls = 0;
  int? holdPutAt;
  Completer<void>? putStarted;
  Completer<void>? holdPut;

  @override
  Future<void> put(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) async {
    putCalls++;
    if (putCalls == holdPutAt) {
      putStarted?.complete();
      await holdPut!.future;
    }
    if (failNextPut) {
      failNextPut = false;
      throw const FileSystemException('injected queue write failure');
    }
    await super.put(scope, kind, id, bytes);
  }
}

class FlakySecret extends MemorySecret {
  bool failNextReplace = false;
  int failReplaceCount = 0;
  int replaceCalls = 0;

  @override
  Future<void> replace(String? next) async {
    replaceCalls++;
    if (failNextReplace) {
      failNextReplace = false;
      throw const FileSystemException('injected secret write failure');
    }
    if (failReplaceCount > 0) {
      failReplaceCount--;
      throw const FileSystemException('injected secret write failure');
    }
    value = next;
  }
}

Future<(Sessions, AccountScope)> _unknownQueueForHealthSync(
  Sessions seed,
  AccountScope original,
  Directory dir,
  FlakySecret secret,
) async {
  await seed.put(
    original,
    CacheKind.queue,
    HealthSync.key,
    utf8.encode(jsonEncode({'mode': 'on', 'cursor': 1})),
  );
  final restored = Sessions(secret, dir);
  await restored.restore();
  final scope = restored.active!;
  await restored.clear();
  expect(restored.hasUnknownWithdrawal(scope), true);
  return (restored, await restored.activate(tokens('A', 'A-new')));
}

class HuaweiSdkForSync implements HuaweiHealthSdk {
  bool authorized = true;
  Set<String> grantable = {...huaweiReadScopes};
  int verifyCalls = 0, signIns = 0, reads = 0;
  int? holdVerifyAt;
  Completer<void>? verifyStarted;
  Completer<void>? holdVerify;
  Completer<void>? signInStarted;
  Completer<void>? holdSignIn;

  @override
  Future<void> verifyAppId() async {
    verifyCalls++;
    if (verifyCalls == holdVerifyAt) {
      if (verifyStarted?.isCompleted == false) verifyStarted!.complete();
      await holdVerify?.future;
    }
  }

  @override
  Future<HuaweiAuthResult?> signIn(Set<String> scopes) async {
    signIns++;
    if (signInStarted?.isCompleted == false) signInStarted!.complete();
    await holdSignIn?.future;
    return HuaweiAuthResult(scopes.intersection(grantable));
  }

  @override
  Future<bool> getHealthAppAuthorization() async => authorized;

  @override
  Future<Set<String>> getGrantedScopes() async => Set.of(grantable);

  @override
  Future<void> init() async {}

  @override
  Future<List<HuaweiSample>> read(int from, int to) async {
    reads++;
    return [];
  }

  @override
  Future<List<HuaweiActivityRecord>> readActivityRecords(
    int from,
    int to,
  ) async => [];
}

void main() {
  late AppApi api;
  late AccountScope a;
  late HealthSync sync;
  late Synthetic port;
  late bool member, granted, offline, failUpload;
  late int now, grants, consentAt;
  late List<Map> sent;
  late Directory dir;
  late FlakySecret secret;
  late FlakySessions sessions;
  late Handler handler;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp();
    addTearDown(() => dir.delete(recursive: true));
    secret = FlakySecret();
    sessions = FlakySessions(secret, dir);
    a = await sessions.activate(tokens('A'));
    handler = Handler();
    api = AppApi(Uri.https('example.invalid'), handler, sessions);
    port = Synthetic();
    now = 1800000000000;
    consentAt = now;
    member = true;
    granted = false;
    offline = false;
    failUpload = false;
    grants = 0;
    sent = [];
    handler.handle = (op, req) async {
      if (offline) throw const SocketException('offline');
      switch (op) {
        case AppOp.setConsent:
          granted = jsonDecode(req.body)['granted'];
          grants++;
          return response({
            'purpose': 'health',
            'version': '2026-11',
            'granted': granted,
            'updated_at': DateTime.fromMillisecondsSinceEpoch(
              consentAt,
              isUtc: true,
            ).toIso8601String(),
          });
        case AppOp.listConsents:
          return response({
            'items': [
              {
                'purpose': 'health',
                'version': '2026-11',
                'granted': granted,
                'updated_at': DateTime.fromMillisecondsSinceEpoch(
                  consentAt,
                  isUtc: true,
                ).toIso8601String(),
              },
            ],
          });
        case AppOp.getEntitlements:
          return response({
            'tier': member ? 'member' : 'free',
            'expires_at': DateTime.fromMillisecondsSinceEpoch(
              now + 86400000,
              isUtc: true,
            ).toIso8601String(),
          });
        case AppOp.uploadWindow:
          if (failUpload) throw const SocketException('lost');
          sent.add(jsonDecode(req.body));
          return response({});
        case AppOp.logout:
          return response({});
        default:
          throw StateError('unexpected $op');
      }
    };
    sync = HealthSync(api, a, ConsentGate(api), port, clock: () => now);
  });
  test(
    'membership precedes separate consent and OS prompt; denial never reads',
    () async {
      member = false;
      await expectLater(sync.enable(), throwsA(anything));
      expect([grants, port.prompts], [0, 0]);
      member = true;
      port.granted = false;
      await expectLater(sync.enable(), throwsA(anything));
      await sync.tick();
      expect(port.reads, 0);
      expect(sent, isEmpty);
    },
  );
  test(
    'leaving foreground during authorization preflight prevents prompt',
    () async {
      port
        ..requestStarted = Completer<void>()
        ..holdRequest = Completer<void>();
      final oldEnable = sync.enable();
      await port.requestStarted!.future.timeout(const Duration(seconds: 1));

      sync.suspend();
      sync.resume();
      port.holdRequest!.complete();

      await expectLater(oldEnable, throwsA(isA<StateError>()));
      expect(port.promptStarts, 0);
      expect(await sync.state(), isNot(contains('collection_from')));
      // The next foreground tick must still run the withdrawal/recovery gate,
      // not treat the stale preflight as a completed enable.
      await sync.tick();
      expect(await sync.state(), {'mode': 'off'});
      expect(port.reads, 0);
      expect(sent, isEmpty);
    },
  );
  test(
    'HMS release preflight cancelled by Home cannot sign in after resume',
    () async {
      final sdk = HuaweiSdkForSync()
        ..holdVerifyAt = 2
        ..verifyStarted = Completer<void>()
        ..holdVerify = Completer<void>();
      final huaweiPort = HuaweiHealthPort(sdk, approved: true);
      final huaweiSync = HealthSync(
        api,
        a,
        ConsentGate(api),
        huaweiPort,
        clock: () => now,
      );
      addTearDown(huaweiSync.close);

      final opening = huaweiSync.enable();
      await sdk.verifyStarted!.future.timeout(const Duration(seconds: 1));
      expect(sdk.signIns, 0);

      huaweiSync.inactive();
      huaweiSync.resume();
      sdk.holdVerify!.complete();

      await expectLater(opening, throwsA(isA<StateError>()));
      expect(sdk.signIns, 0);
      final cancelled = await huaweiSync.state();
      expect(cancelled['mode'], 'withdraw');
      expect(cancelled, isNot(contains('collection_from')));
      expect(cancelled, isNot(contains('cursor')));
      expect([sdk.reads, sent.length], [0, 0]);

      await huaweiSync.tick();
      expect(await huaweiSync.state(), {'mode': 'off'});
      expect([sdk.signIns, sdk.reads, sent.length], [0, 0, 0]);
    },
  );
  test(
    'HMS prompt interruption cannot establish collection before resume gate',
    () async {
      final sdk = HuaweiSdkForSync()
        ..signInStarted = Completer<void>()
        ..holdSignIn = Completer<void>();
      final huaweiPort = HuaweiHealthPort(sdk, approved: true);
      final huaweiSync = HealthSync(
        api,
        a,
        ConsentGate(api),
        huaweiPort,
        clock: () => now,
      );
      addTearDown(huaweiSync.close);

      final opening = huaweiSync.enable();
      await sdk.signInStarted!.future.timeout(const Duration(seconds: 1));
      huaweiSync.inactive();
      huaweiSync.resume();
      sdk.holdSignIn!.complete();
      await opening;

      final pending = await huaweiSync.state();
      expect(pending['mode'], 'pending');
      expect(pending, isNot(contains('collection_from')));
      expect(pending, isNot(contains('cursor')));
      expect([sdk.signIns, sdk.reads, sent.length], [1, 0, 0]);
      expect(granted, true);

      now += 600000;
      await huaweiSync.tick();
      final resumed = await huaweiSync.state();
      expect(resumed['mode'], 'on');
      expect(resumed['collection_from'], ceilSlot(now));
      expect(resumed['cursor'], resumed['collection_from']);
      expect([sdk.signIns, sdk.reads, sent.length], [1, 0, 0]);
    },
  );
  test(
    'authorization resume before result still waits for the resumed gate',
    () async {
      port
        ..promptStarted = Completer<void>()
        ..holdPrompt = Completer<void>();
      final opening = sync.enable();
      await port.promptStarted!.future.timeout(const Duration(seconds: 1));

      // The real OS authorization sheet can move the app to inactive. This is
      // not a cancellable release-preflight pause.
      sync.inactive();
      sync.resume();
      port.holdPrompt!.complete();

      await opening;
      final pending = await sync.state();
      expect(pending['mode'], 'pending');
      expect(pending, isNot(contains('collection_from')));
      expect(pending, isNot(contains('cursor')));
      expect([port.promptStarts, port.reads, sent.length], [1, 0, 0]);

      now += 30000;
      await sync.tick();
      final resumed = await sync.state();
      expect(resumed['mode'], 'on');
      expect(resumed['collection_from'], ceilSlot(now));
      expect(resumed['cursor'], resumed['collection_from']);
    },
  );
  test(
    'inactive authorization result is pending until resume revalidates gate',
    () async {
      port
        ..promptStarted = Completer<void>()
        ..holdPrompt = Completer<void>();
      final opening = sync.enable();
      await port.promptStarted!.future.timeout(const Duration(seconds: 1));

      sync.inactive();
      port.holdPrompt!.complete();
      await opening;

      final pending = await sync.state();
      expect(pending['mode'], 'pending');
      expect(pending, isNot(contains('collection_from')));
      expect(pending, isNot(contains('cursor')));
      expect([grants, port.reads, sent.length], [1, 0, 0]);
      expect(granted, true);
      expect(api.sessions.hasWithdrawalIntent(a), false);

      now += 30000;
      sync.resume();
      await sync.tick();

      final resumed = await sync.state();
      expect(resumed['mode'], 'on');
      expect(resumed['collection_from'], ceilSlot(now));
      expect(resumed['cursor'], resumed['collection_from']);
      expect([grants, port.reads, sent.length], [1, 0, 0]);
      expect(granted, true);
    },
  );
  test(
    'authorization result arriving just before inactive stays pending',
    () async {
      port
        ..promptStarted = Completer<void>()
        ..holdPrompt = Completer<void>();
      final opening = sync.enable();
      await port.promptStarted!.future.timeout(const Duration(seconds: 1));

      // Complete first, then move to inactive before the enable continuation can
      // observe the granted result. This is the reverse arrival order.
      port.holdPrompt!.complete();
      sync.inactive();
      await opening;

      final pending = await sync.state();
      expect(pending['mode'], 'pending');
      expect(pending, isNot(contains('collection_from')));
      expect([grants, port.reads, sent.length], [1, 0, 0]);
      expect(granted, true);
    },
  );
  test(
    'pending grant failing the resumed gate pauses without server revocation',
    () async {
      port
        ..promptStarted = Completer<void>()
        ..holdPrompt = Completer<void>();
      final opening = sync.enable();
      await port.promptStarted!.future.timeout(const Duration(seconds: 1));
      sync.inactive();
      port.holdPrompt!.complete();
      await opening;
      expect((await sync.state())['mode'], 'pending');

      member = false;
      sync.resume();
      await sync.tick();

      expect(await sync.state(), {'mode': 'paused'});
      expect([grants, port.reads, sent.length], [1, 0, 0]);
      expect(granted, true);
      expect(api.sessions.hasWithdrawalIntent(a), false);
    },
  );
  test(
    'true background invalidates prompt without revoking server consent',
    () async {
      port
        ..promptStarted = Completer<void>()
        ..holdPrompt = Completer<void>();
      final opening = sync.enable();
      await port.promptStarted!.future.timeout(const Duration(seconds: 1));

      sync.suspend();
      port.holdPrompt!.complete();

      await expectLater(opening, throwsA(isA<StateError>()));
      expect(await sync.state(), {'mode': 'withdraw'});
      expect([grants, port.reads, sent.length], [1, 0, 0]);
      expect(granted, true);
      expect(api.sessions.hasWithdrawalIntent(a), false);

      sync.resume();
      await sync.tick();
      expect(await sync.state(), {'mode': 'off'});
      expect([grants, port.reads, sent.length], [1, 0, 0]);
      expect(granted, true);
    },
  );
  test(
    'internal setup withdraw becomes off without server revocation',
    () async {
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode({'mode': 'withdraw'})),
      );

      await sync.tick();

      expect(await sync.state(), {'mode': 'off'});
      expect([grants, port.reads, sent.length], [0, 0, 0]);
      expect(api.sessions.hasWithdrawalIntent(a), false);
    },
  );
  test(
    're-enable after a setup tombstone does not revoke consent first',
    () async {
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode({'mode': 'withdraw'})),
      );

      await sync.enable();

      expect((await sync.state())['mode'], 'on');
      expect([grants, port.reads, sent.length], [1, 0, 0]);
      expect(granted, true);
      expect(api.sessions.hasWithdrawalIntent(a), false);
    },
  );
  test(
    'offline withdrawal survives restart, cannot resend after new grant',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(anything));
      expect(port.reads, 1);
      offline = true;
      await expectLater(sync.withdraw(), throwsA(anything));
      offline = false;
      failUpload = false;
      sync = HealthSync(api, a, ConsentGate(api), port, clock: () => now);
      await sync.tick();
      expect(granted, false);
      expect(sent, isEmpty);
      await sync.enable();
      await sync.tick();
      expect(sent, isEmpty);
    },
  );
  test(
    'expired membership and lost OS permission do not drain queue',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(anything));
      failUpload = false;
      member = false;
      await sync.tick();
      expect(port.reads, 1);
      member = true;
      port.granted = false;
      await sync.tick();
      port.granted = true;
      await sync.tick();
      expect(sent, isEmpty);
    },
  );
  test(
    'A native result returning after account switch never dispatches as B',
    () async {
      await sync.enable();
      now += 600000;
      port.hold = Completer();
      final f = sync.tick();
      while (port.reads == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await api.sessions.activate(tokens('B'));
      port.hold!.complete();
      await f.catchError((_) {});
      expect(sent, isEmpty);
    },
  );
  test(
    'OS revocation while offline drops pending slots before any network call',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      expect((await sync.state()).containsKey('pending_end'), true);
      offline = true;
      port.granted = false;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      expect(await sync.state(), {'mode': 'withdraw'});
      port.granted = true;
      offline = false;
      failUpload = false;
      await sync.tick();
      expect(sent, isEmpty);
      expect(granted, false);
      expect(port.reads, 1);
    },
  );
  test(
    'in-flight native result cannot re-create the queue after withdrawal',
    () async {
      await sync.enable();
      now += 600000;
      port.hold = Completer();
      final task = sync.tick();
      while (port.reads == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await sync.withdraw();
      port.hold!.complete();
      await expectLater(task, throwsStateError);
      expect(await sync.state(), {'mode': 'off'});
      expect(sent, isEmpty);
    },
  );
  test(
    'interrupted queued range is discarded on fresh foreground session',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      sync.suspend();
      sync.resume();
      failUpload = false;
      await sync.tick();
      expect(sent, isEmpty);
      expect(port.reads, 1);
    },
  );
  test(
    'stored paid-through boundary blocks pre-renewal collection after restart',
    () async {
      await sync.enable();
      final state = await sync.state();
      state['paid_until'] = 0;
      await api.sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode(state)),
      );
      now += 600000;
      await sync.tick();
      expect(port.reads, 0);
      expect(await sync.state(), {'mode': 'paused'});
    },
  );
  test(
    '401 token rotation cannot replay an upload after local withdrawal',
    () async {
      await sync.enable();
      now += 600000;
      final handler = api.transport as Handler, normal = handler.handle;
      final refreshing = Completer<void>(), release = Completer<void>();
      var attempts = 0;
      handler.handle = (op, req) async {
        if (op == AppOp.uploadWindow) {
          attempts++;
          return response({}, 401);
        }
        if (op == AppOp.refreshTokens) {
          refreshing.complete();
          await release.future;
          return response(tokens('A', 'rotated').toJson());
        }
        return normal(op, req);
      };
      final work = sync.tick();
      await refreshing.future;
      await sync.withdraw();
      release.complete();
      await expectLater(work, throwsStateError);
      expect(attempts, 1);
      expect(await sync.state(), {'mode': 'off'});
    },
  );
  for (final boundary in [
    'OS permission',
    'remote withdrawal',
    'remote regrant epoch',
    'original paid-through',
  ]) {
    test('401 refresh rechecks $boundary before replaying health', () async {
      await sync.enable();
      final paidUntil = (await sync.state())['paid_until'] as int;
      now += 600000;
      final normal = handler.handle;
      var uploads = 0, refreshes = 0;
      handler.handle = (op, req) async {
        if (op == AppOp.uploadWindow && uploads++ == 0) {
          return response({}, 401);
        }
        if (op == AppOp.refreshTokens) {
          refreshes++;
          switch (boundary) {
            case 'OS permission':
              port.granted = false;
            case 'remote withdrawal':
              granted = false;
            case 'remote regrant epoch':
              consentAt += 1000;
            case 'original paid-through':
              // Entitlements can show a renewal, but it cannot authorize a
              // summary from the batch that crossed its old boundary.
              now = paidUntil;
          }
          return response(tokens('A', 'rotated').toJson());
        }
        return normal(op, req);
      };
      await sync.tick();
      expect(refreshes, 1);
      expect(uploads, 1, reason: 'the rejected first request is not replayed');
      expect(sent, isEmpty);
      expect(await sync.state(), {'mode': 'paused'});
      expect(sessions.active, same(a));
    });
  }

  test(
    'pre-send refresh rechecks health grant before the first upload',
    () async {
      await sync.enable();
      now += 600000;
      port.hold = Completer<void>();
      final normal = handler.handle;
      var queries = 0, uploads = 0, refreshes = 0;
      handler.handle = (op, req) async {
        if (op == AppOp.listConsents) queries++;
        if (op == AppOp.uploadWindow) uploads++;
        if (op == AppOp.refreshTokens) {
          refreshes++;
          consentAt += 1000;
          return response(tokens('A', 'rotated').toJson());
        }
        return normal(op, req);
      };
      final task = sync.tick();
      while (port.reads == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final current = sessions.require(a);
      await sessions.rotate(
        a,
        Tokens(
          current.account,
          current.access,
          current.refresh,
          DateTime.utc(2000),
        ),
      );
      port.hold!.complete();
      await task;
      expect(refreshes, 1);
      expect(
        queries,
        2,
        reason: 'native read gate, then a gate on the new token',
      );
      expect(uploads, 0);
      expect(await sync.state(), {'mode': 'paused'});
    },
  );

  test(
    'OS loss while checking membership blocks the first health upload',
    () async {
      await sync.enable();
      now += 600000;
      final normal = handler.handle;
      var entitlementChecks = 0, uploads = 0;
      handler.handle = (op, req) async {
        if (op == AppOp.getEntitlements && ++entitlementChecks == 2) {
          port.granted = false; // The upload gate's first OS check has passed.
        }
        if (op == AppOp.uploadWindow) uploads++;
        return normal(op, req);
      };
      await sync.tick();
      expect(port.reads, 1);
      expect(entitlementChecks, 2);
      expect(uploads, 0);
      expect(await sync.state(), {'mode': 'paused'});
    },
  );

  for (final failure in ['disconnect', '503', '401']) {
    test(
      'health upload 401 followed by refresh $failure does not replay',
      () async {
        await sync.enable();
        final cursor = (await sync.state())['cursor'];
        await sessions.put(a, CacheKind.queue, 'voice-queue-marker', [7, 8]);
        now += 600000;
        final normal = handler.handle;
        var uploads = 0, refreshes = 0;
        handler.handle = (op, req) async {
          if (op == AppOp.uploadWindow) {
            uploads++;
            return response({}, 401);
          }
          if (op == AppOp.refreshTokens) {
            refreshes++;
            if (failure == 'disconnect') throw const SocketException('offline');
            return response({}, int.parse(failure));
          }
          return normal(op, req);
        };
        final expectedError = failure == 'disconnect'
            ? isA<SocketException>()
            : isA<ApiFailure>().having(
                (e) => e.status,
                'status',
                int.parse(failure),
              );
        await expectLater(sync.tick(), throwsA(expectedError));
        expect([uploads, refreshes], [1, 1]);
        if (failure == '401') {
          expect(sessions.active, isNull);
          return;
        }
        expect(sessions.active, same(a));
        final queue = (await sessions.get(a, CacheKind.queue, HealthSync.key))!;
        expect(jsonDecode(utf8.decode(queue)), containsPair('cursor', cursor));
        expect(
          jsonDecode(utf8.decode(queue)),
          containsPair('pending_end', isA<int>()),
        );
        expect(await sessions.get(a, CacheKind.queue, 'voice-queue-marker'), [
          7,
          8,
        ]);

        handler.handle = normal;
        await sync.tick();
        expect(
          port.reads,
          2,
          reason: 'recovery samples again instead of replaying a body',
        );
        expect(
          sent.single['starts_at'],
          DateTime.fromMillisecondsSinceEpoch(
            cursor as int,
            isUtc: true,
          ).toIso8601String(),
        );
      },
    );
  }

  for (final replay in [false, true]) {
    final stage = replay ? 'upload replay' : 'first upload';
    test(
      'health $stage cannot use consent from before a gate token rotation',
      () async {
        await sync.enable();
        now += 600000;
        final normal = handler.handle;
        final uploadTokens = <String?>[];
        var memberChecks = 0, refreshes = 0;
        handler.handle = (op, req) async {
          if (op == AppOp.uploadWindow) {
            uploadTokens.add(req.headers['Authorization']);
            if (replay && uploadTokens.length == 1) return response({}, 401);
          }
          if (op == AppOp.getEntitlements &&
              ++memberChecks == (replay ? 3 : 2)) {
            return response({}, 401);
          }
          if (op == AppOp.refreshTokens) {
            if (++refreshes == (replay ? 2 : 1)) granted = false;
            return response(tokens('A', 'gate-token-$refreshes').toJson());
          }
          return normal(op, req);
        };
        await sync.tick();
        expect(refreshes, replay ? 2 : 1);
        expect(
          uploadTokens,
          hasLength(replay ? 1 : 0),
          reason:
              'a rotated credential cannot send a window with earlier consent',
        );
        expect(sent, isEmpty);
        expect(sessions.active, same(a));
        expect(await sync.state(), containsPair('pending_end', isA<int>()));
        await sync.tick();
        expect(uploadTokens, hasLength(replay ? 1 : 0));
        expect(await sync.state(), {'mode': 'paused'});
      },
    );
  }

  for (final (query, failure, replay) in [
    (AppOp.getEntitlements, '503', false),
    (AppOp.getEntitlements, 'offline', true),
    (AppOp.listConsents, '503', false),
    (AppOp.getEntitlements, '401', false),
    (AppOp.getEntitlements, 'query still unauthorized', false),
  ]) {
    test(
      'health upload gate ${query.name}: $failure (replay=$replay)',
      () async {
        await sync.enable();
        final cursor = (await sync.state())['cursor'];
        await sessions.put(a, CacheKind.queue, 'voice-queue-marker', [7, 8]);
        now += 600000;
        final normal = handler.handle;
        var checks = 0, uploads = 0, refreshes = 0;
        final gateCheck = replay ? 3 : 2;
        handler.handle = (op, req) async {
          if (op == AppOp.uploadWindow) {
            uploads++;
            return response({}, 401);
          }
          if (op == query && ++checks >= gateCheck) return response({}, 401);
          if (op == AppOp.refreshTokens) {
            refreshes++;
            if ((replay && refreshes == 1) ||
                failure == 'query still unauthorized') {
              return response(tokens('A', 'refreshed').toJson());
            }
            if (failure == 'offline') throw const SocketException('offline');
            return response({}, int.parse(failure));
          }
          return normal(op, req);
        };
        if (failure == '401') {
          await expectLater(sync.tick(), throwsA(isA<SessionChanged>()));
          expect(sessions.active, isNull);
        } else {
          await sync.tick();
          expect(sessions.active, same(a));
          final queue = (await sessions.get(
            a,
            CacheKind.queue,
            HealthSync.key,
          ))!;
          final saved = jsonDecode(utf8.decode(queue));
          expect(saved, containsPair('cursor', cursor));
          expect(saved, containsPair('pending_end', isA<int>()));
          expect(await sessions.get(a, CacheKind.queue, 'voice-queue-marker'), [
            7,
            8,
          ]);
        }
        expect(
          checks,
          gateCheck + (failure == 'query still unauthorized' ? 1 : 0),
        );
        expect(refreshes, replay ? 2 : 1);
        expect(uploads, replay ? 1 : 0);
        expect(sent, isEmpty);
      },
    );
  }

  test('remote withdraw/regrant epoch cannot drain queued history', () async {
    await sync.enable();
    now += 600000;
    failUpload = true;
    await expectLater(sync.tick(), throwsA(isA<SocketException>()));
    final h = api.transport as Handler, normal = h.handle;
    h.handle = (op, req) async => op == AppOp.listConsents
        ? response({
            'items': [
              {
                'purpose': 'health',
                'version': '2026-11',
                'granted': true,
                'updated_at': '2030-01-01T00:00:00Z',
              },
            ],
          })
        : normal(op, req);
    failUpload = false;
    await sync.tick();
    expect(port.reads, 1);
    expect(sent, isEmpty);
    expect(await sync.state(), {'mode': 'paused'});
  });
  test(
    'several offline ticks retain retry bounds without reading or uploading',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      final before = await sync.state();
      offline = true;
      for (var i = 0; i < 3; i++) {
        now += 30000;
        await sync.tick();
      }
      expect(port.reads, 1);
      expect(sent, isEmpty);
      expect((await sync.state())['pending_end'], before['pending_end']);
      offline = false;
      failUpload = false;
      await sync.tick();
      expect(
        sent.single['starts_at'],
        DateTime.fromMillisecondsSinceEpoch(
          before['cursor'],
          isUtc: true,
        ).toIso8601String(),
      );
    },
  );
  test(
    'retry is a fresh read; upload contains only the contract fields',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(anything));
      failUpload = false;
      await sync.tick();
      expect(port.reads, 2);
      expect(sent.single.keys.toSet(), {
        'channel',
        'starts_at',
        'duration_seconds',
        'exercise',
        'source',
        'heart_rate',
      });
    },
  );

  test(
    'resume after unobserved OS revoke/regrant never backfills old slots',
    () async {
      await sync.enable();
      final previous = (await sync.state())['collection_from'] as int;
      sync.suspend();
      now += 600000;
      port.granted = false;
      port.granted = true;
      offline = true;
      sync.resume();
      await sync.tick();
      // A failed gate must not advance the durable boundary.
      expect((await sync.state())['collection_from'], previous);
      offline = false;
      await sync.tick();
      final resumed = await sync.state();
      final boundary = resumed['collection_from'] as int;
      expect(boundary, greaterThan(previous));
      expect(resumed['cursor'], boundary);

      now += 600000;
      port.rows = (_, _) => [
        ['steps', boundary - 300000, boundary + 30000, 120],
      ];
      await sync.tick();
      expect(port.reads, 1);
      expect(sent, isEmpty);
    },
  );
  test(
    'pre-boundary state without collection_from pauses without reading',
    () async {
      await sync.enable();
      final legacy = await sync.state();
      legacy.remove('collection_from');
      await api.sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode(legacy)),
      );
      now += 600000;

      await sync.tick();

      expect(port.reads, 0);
      expect(sent, isEmpty);
      expect(await sync.state(), {'mode': 'paused'});
    },
  );
  test('restore save cannot cross a suspend/resume boundary', () async {
    await sync.enable();
    sync.suspend();
    sync.resume();
    now += 600000;
    port.rows = (from, _) => [
      ['heart_rate', from, from, 68],
      ['heart_rate', from + slotMs, from + slotMs, 72],
    ];
    sessions
      ..putCalls = 0
      ..holdPutAt = 1
      ..putStarted = Completer<void>()
      ..holdPut = Completer<void>();
    final oldTick = sync.tick();
    await sessions.putStarted!.future.timeout(const Duration(seconds: 1));

    sync.suspend();
    now += 600000;
    port.granted = false;
    port.granted = true;
    sync.resume();
    sessions.holdPut!.complete();
    await expectLater(oldTick, throwsA(isA<StateError>()));

    // The interrupted save must not commit _restored. The next foreground
    // session starts at its own boundary, so the old 10-minute range is not
    // queried. Once the clock advances past the five-minute buffer it may
    // collect only the new window.
    await sync.tick();
    expect(port.reads, 0);
    expect(sent, isEmpty);
    now += 600000;
    await sync.tick();
    expect(port.reads, 1);
    expect(sent, hasLength(2));
    expect(
      sent.map((row) => row['starts_at']),
      everyElement(startsWith('2027-01-15T08:20:')),
    );
  });
  test('first enable save cannot cross a suspend/resume boundary', () async {
    sessions
      ..putCalls = 0
      ..holdPutAt = 2
      ..putStarted = Completer<void>()
      ..holdPut = Completer<void>();
    final oldEnable = sync.enable();
    await sessions.putStarted!.future.timeout(const Duration(seconds: 1));

    sync.suspend();
    now += 600000;
    port.granted = false;
    port.granted = true;
    sync.resume();
    sessions.holdPut!.complete();
    await expectLater(oldEnable, throwsA(isA<StateError>()));

    await sync.tick();
    expect(port.reads, 0);
    expect(sent, isEmpty);
    final boundary = (await sync.state())['cursor'] as int;
    expect((await sync.state())['collection_from'], boundary);
    now += 600000;
    port.rows = (from, _) => [
      ['heart_rate', from, from, 68],
      ['heart_rate', from + slotMs, from + slotMs, 72],
    ];
    await sync.tick();
    expect(port.reads, 1);
    expect(sent, hasLength(2));
    expect(
      sent.map((row) => row['starts_at']),
      everyElement(
        startsWith(
          DateTime.fromMillisecondsSinceEpoch(
            boundary,
            isUtc: true,
          ).toIso8601String().substring(0, 17),
        ),
      ),
    );
  });
  test(
    'step interval beginning in an earlier batch is not lost after consent',
    () async {
      await sync.enable();
      final saved = await sync.state();
      final from = (saved['cursor'] as int) + 600000;
      saved['cursor'] = from;
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode(saved)),
      );
      now = from + 600000;
      port.rows = (_, _) => [
        ['steps', from - 5000, from + 35000, 40],
      ];

      await sync.tick();

      expect(sent, hasLength(2));
      expect(
        sent.map((row) => row['starts_at']),
        everyElement(
          startsWith(
            DateTime.fromMillisecondsSinceEpoch(
              from,
              isUtc: true,
            ).toIso8601String().substring(0, 17),
          ),
        ),
      );
      expect(
        sent.map((row) => row['cadence']['sample_count']),
        everyElement(1),
      );
      expect(sent.map((row) => row['cadence']['valid_seconds']), [30, 5]);
    },
  );
  test(
    'old server consent cannot admit steps from before this opening',
    () async {
      consentAt = now - 300000;
      now += 200000;
      await sync.enable();
      final boundary = (await sync.state())['collection_from'] as int;
      now += 600000;
      port.rows = (_, _) => [
        ['steps', boundary - 450000, boundary + 30000, 120],
      ];

      await sync.tick();

      expect(port.reads, 1);
      expect(sent, isEmpty);
    },
  );
  test(
    're-enable after an entitlement gap starts a new collection boundary',
    () async {
      await sync.enable();
      final first = (await sync.state())['collection_from'] as int;
      final expired = await sync.state();
      expired['paid_until'] = now;
      await api.sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode(expired)),
      );
      await sync.tick();
      expect((await sync.state())['mode'], 'paused');

      now += 600000;
      await sync.enable();
      final renewed = await sync.state();
      final boundary = renewed['collection_from'] as int;
      expect(boundary, greaterThan(first));
      expect(renewed['cursor'], boundary);

      now += 600000;
      port.rows = (_, _) => [
        ['steps', first + 300000, boundary + 30000, 90],
      ];
      await sync.tick();
      expect(port.reads, 1);
      expect(sent, isEmpty);
    },
  );
  test('failed withdrawal tombstone write cannot resume collection', () async {
    await sync.enable();
    now += 600000;
    sessions.failNextPut = true;
    await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
    await sync.tick();
    expect(port.reads, 0);
    expect(sent, isEmpty);
    expect((await sync.state())['mode'], isNot('on'));
  });
  test(
    'real temp files and secret store contain no plaintext A linkage',
    () async {
      final localDir = await Directory.systemTemp.createTemp();
      addTearDown(() => localDir.delete(recursive: true));
      final localSecret = MemorySecret();
      final local = Sessions(localSecret, localDir);
      final localA = await local.activate(tokens('acct-A-9c2e'));
      await local.put(
        localA,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(
          jsonEncode({
            'mode': 'on',
            'cursor': 0,
            'private_marker': 'health-private-A',
          }),
        ),
      );
      for (final file in localDir.listSync().whereType<File>()) {
        final raw = latin1.decode(await file.readAsBytes());
        expect(raw, isNot(contains(localA.account)));
        expect(raw, isNot(contains(HealthSync.key)));
        expect(raw, isNot(contains('health-private-A')));
      }
      await local.addWithdrawalIntent(localA);
      await local.clear();
      expect(local.active, isNull);
      expect(localDir.listSync(), isEmpty);
      expect(localSecret.value, isNot(contains(localA.account)));
      expect(localSecret.value, isNot(contains(HealthSync.key)));

      final restored = Sessions(localSecret, localDir);
      await restored.restore();
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(localA), true);
      final localB = await restored.activate(tokens('acct-B-6a31'));
      expect(restored.hasWithdrawalIntent(localB), false);
      expect(
        await restored.get(localB, CacheKind.queue, HealthSync.key),
        isNull,
      );
    },
  );
  test(
    'withdrawal write failure stays fail-closed after process restart',
    () async {
      await sync.enable();
      now += 600000;
      sessions.failNextPut = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      final restoredApi = AppApi(
        Uri.https('example.invalid'),
        handler,
        restored,
      );
      final restoredPort = Synthetic();
      final restoredSync = HealthSync(
        restoredApi,
        restoredScope,
        ConsentGate(restoredApi),
        restoredPort,
        clock: () => now,
      );
      await restoredSync.tick();
      expect(restoredPort.reads, 0);
      expect(sent, isEmpty);
      expect((await restoredSync.state())['mode'], isNot('on'));
    },
  );
  test(
    'explicit withdrawal survives restart when only the outbox write fails',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      // The intent remains fail-closed in memory even though its encrypted
      // outbox write failed; the queue is the restart-safe copy.
      expect(api.sessions.hasWithdrawalIntent(a), true);
      expect(granted, true);

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      final restoredApi = AppApi(
        Uri.https('example.invalid'),
        handler,
        restored,
      );
      final restoredPort = Synthetic();
      final restoredSync = HealthSync(
        restoredApi,
        restoredScope,
        ConsentGate(restoredApi),
        restoredPort,
        clock: () => now,
      );
      addTearDown(restoredSync.close);

      await restoredSync.tick();

      expect(granted, false);
      expect(restoredApi.sessions.hasWithdrawalIntent(restoredScope), false);
      expect(await restoredSync.state(), {'mode': 'off'});
      expect([restoredPort.reads, sent.length], [0, 0]);
    },
  );
  test(
    'queue-only explicit withdrawal survives offline logout and retries for A only',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect((await sync.state())['mode'], 'withdraw');

      offline = true;
      await expectLater(api.logout(a), throwsA(isA<SocketException>()));
      offline = false;

      final restored = Sessions(secret, dir);
      await restored.restore();
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(a), true);

      final aAgain = await restored.activate(tokens('A', 'A-new'));
      final aApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        Synthetic(),
        clock: () => now,
      );
      expect(await aSync.state(), {'mode': 'withdraw'});

      final calls = <(AppOp, String?)>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add((op, req.headers['Authorization']));
        return normal(op, req);
      };

      final b = await restored.activate(tokens('B', 'B-access'));
      expect(restored.hasWithdrawalIntent(a), true);
      expect(restored.hasWithdrawalIntent(b), false);
      expect(await restored.get(b, CacheKind.queue, HealthSync.key), isNull);
      final bApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final bPort = Synthetic();
      final bSync = HealthSync(
        bApi,
        b,
        ConsentGate(bApi),
        bPort,
        clock: () => now,
      );
      await bSync.tick();
      expect([bPort.reads, sent.length, grants], [0, 0, 1]);
      expect(calls, isEmpty);

      final aRetry = await restored.activate(tokens('A', 'A-new'));
      final retryApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final aPort = Synthetic();
      final retrySync = HealthSync(
        retryApi,
        aRetry,
        ConsentGate(retryApi),
        aPort,
        clock: () => now,
      );
      await retrySync.tick();
      expect(granted, false);
      expect(await retrySync.state(), {'mode': 'off'});
      expect([aPort.reads, sent.length], [0, 0]);
      expect(calls.map((call) => call.$1), [
        AppOp.listConsents,
        AppOp.setConsent,
      ]);
      expect(calls.map((call) => call.$2), everyElement('Bearer A-new'));
    },
  );
  test('queue-only explicit withdrawal is flushed by online logout', () async {
    await sync.enable();
    now += 600000;
    secret.failNextReplace = true;
    await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
    expect(granted, true);

    await api.logout(a);

    expect(api.sessions.active, isNull);
    expect(granted, false);
    expect(grants, 2);
    expect(dir.listSync(), isEmpty);
    expect(secret.value, isNull);
    final restored = Sessions(secret, dir);
    await restored.restore();
    expect(restored.active, isNull);
    expect(restored.hasWithdrawalIntent(a), false);
  });
  test(
    're-enable flushes a persisted explicit withdrawal before regrant',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect([grants, granted], [1, true]);

      await sync.enable();

      expect([grants, granted], [3, true]);
      expect((await sync.state())['mode'], 'on');
      expect(api.sessions.hasWithdrawalIntent(a), false);
    },
  );
  test(
    'logout immediately clears A while preserving encrypted withdrawal intent',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      offline = true;
      await expectLater(sync.withdraw(), throwsA(isA<SocketException>()));
      final loggingOut = api.logout(a);
      expect(api.sessions.active, isNull);
      await expectLater(loggingOut, throwsA(isA<SocketException>()));
      await Future<void>.delayed(Duration.zero);
      expect(dir.listSync(), isEmpty);
      final raw = jsonDecode(secret.value!) as Map;
      expect(raw.containsKey('tokens'), false);
      expect(raw.containsKey('key'), false);
      expect(secret.value, isNot(contains(HealthSync.key)));
      expect(await sync.state(), {'mode': 'withdraw'});

      final restored = Sessions(secret, dir);
      await restored.restore();
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(a), true);
      final b = await restored.activate(tokens('B'));
      expect(restored.hasWithdrawalIntent(a), true);
      expect(restored.hasWithdrawalIntent(b), false);
      final bPort = Synthetic();
      final bSync = HealthSync(
        AppApi(Uri.https('example.invalid'), handler, restored),
        b,
        ConsentGate(AppApi(Uri.https('example.invalid'), handler, restored)),
        bPort,
        clock: () => now,
      );
      await bSync.tick();
      expect(bPort.reads, 0);
      expect(sent, isEmpty);
    },
  );
  test(
    'in-flight A probe cannot dispatch a withdrawal after B becomes active',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      offline = true;
      await expectLater(sync.withdraw(), throwsA(isA<SocketException>()));
      offline = false;
      failUpload = false;

      final normal = handler.handle;
      final started = Completer<void>(), release = Completer<void>();
      final auth = <String?>[];
      handler.handle = (op, req) async {
        if (op == AppOp.listConsents) {
          auth.add(req.headers['Authorization']);
          started.complete();
          await release.future;
          return response({
            'items': [
              {
                'purpose': 'health',
                'version': '2026-11',
                'granted': true,
                'updated_at': '2026-11-22T00:00:00Z',
              },
            ],
          });
        }
        if (op == AppOp.setConsent) {
          auth.add(req.headers['Authorization']);
          return response({
            'purpose': 'health',
            'version': '2026-11',
            'granted': false,
            'updated_at': '2026-11-22T00:00:01Z',
          });
        }
        if (op == AppOp.logout) {
          auth.add(req.headers['Authorization']);
          return response({});
        }
        return normal(op, req);
      };

      final loggingOut = api.logout(a);
      await started.future.timeout(const Duration(seconds: 1));
      final b = await api.sessions.activate(tokens('B', 'B-access'));
      release.complete();
      await loggingOut;

      expect(auth, ['Bearer access', 'Bearer access']);
      expect(api.sessions.require(b).access, 'B-access');
      final restored = Sessions(secret, dir);
      await restored.restore();
      expect(restored.active!.account, 'B');
      expect(restored.hasWithdrawalIntent(a), true);
    },
  );
  test(
    'online logout confirms a pending withdrawal without retaining A',
    () async {
      await sync.enable();
      now += 600000;
      failUpload = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      offline = true;
      await expectLater(sync.withdraw(), throwsA(isA<SocketException>()));
      offline = false;
      failUpload = false;
      await api.logout(a);
      expect(api.sessions.active, isNull);
      expect(dir.listSync(), isEmpty);
      expect(grants, greaterThan(1));
      expect(granted, false);
      final restored = Sessions(secret, dir);
      await restored.restore();
      expect(restored.hasWithdrawalIntent(a), false);
    },
  );
  test(
    'restored explicit withdrawal is preserved by direct online logout before tick',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(granted, true);

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      final calls = <AppOp>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add(op);
        return normal(op, req);
      };

      await AppApi(
        Uri.https('example.invalid'),
        handler,
        restored,
      ).logout(restoredScope);

      expect(granted, false);
      expect(grants, 2);
      expect(calls, [AppOp.listConsents, AppOp.setConsent, AppOp.logout]);
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      expect(dir.listSync(), isEmpty);
      expect(secret.value, isNull);

      final b = await restored.activate(tokens('B', 'B-access'));
      expect(restored.hasWithdrawalIntent(b), false);
      final bApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final bSync = HealthSync(
        bApi,
        b,
        ConsentGate(bApi),
        Synthetic(),
        clock: () => now,
      );
      await bSync.tick();
      expect(await bSync.state(), {'mode': 'off'});

      final aAgain = await restored.activate(tokens('A', 'A-new'));
      final aApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        Synthetic(),
        clock: () => now,
      );
      await aSync.tick();
      expect(await aSync.state(), {'mode': 'off'});
      expect(calls, [AppOp.listConsents, AppOp.setConsent, AppOp.logout]);
    },
  );
  test(
    'restored explicit withdrawal survives direct offline logout before tick and stays A-only',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(granted, true);

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      offline = true;
      await expectLater(
        AppApi(
          Uri.https('example.invalid'),
          handler,
          restored,
        ).logout(restoredScope),
        throwsA(isA<SocketException>()),
      );
      offline = false;
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(restoredScope), true);

      final b = await restored.activate(tokens('B', 'B-access'));
      expect(restored.hasWithdrawalIntent(b), false);
      expect(await restored.get(b, CacheKind.queue, HealthSync.key), isNull);
      final calls = <(AppOp, String?)>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add((op, req.headers['Authorization']));
        return normal(op, req);
      };
      final bApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final bPort = Synthetic();
      final bSync = HealthSync(
        bApi,
        b,
        ConsentGate(bApi),
        bPort,
        clock: () => now,
      );
      await bSync.tick();
      expect(calls, isEmpty);
      expect(bPort.reads, 0);

      final aAgain = await restored.activate(tokens('A', 'A-new'));
      final aApi = AppApi(Uri.https('example.invalid'), handler, restored);
      final aPort = Synthetic();
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        aPort,
        clock: () => now,
      );
      await aSync.tick();

      expect(granted, false);
      expect(calls.map((call) => call.$1), [
        AppOp.listConsents,
        AppOp.setConsent,
      ]);
      expect(calls.map((call) => call.$2), everyElement('Bearer A-new'));
      expect([aPort.reads, sent.length], [0, 0]);
    },
  );
  test(
    'failed outbox write retries on next withdrawal tick and survives restart',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(secret.value, isNot(contains('"withdrawals"')));

      offline = true;
      await expectLater(sync.tick(), throwsA(isA<SocketException>()));
      expect(secret.value, contains('"withdrawals"'));

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      expect(restored.hasWithdrawalIntent(restoredScope), true);
    },
  );
  test(
    'restored setup tombstone is not sent as a withdrawal on direct logout',
    () async {
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode({'mode': 'withdraw'})),
      );
      granted = true;

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      final calls = <AppOp>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add(op);
        return normal(op, req);
      };

      await AppApi(
        Uri.https('example.invalid'),
        handler,
        restored,
      ).logout(restoredScope);

      expect(grants, 0);
      expect(granted, true);
      expect(calls, [AppOp.logout]);
      expect(restored.hasWithdrawalIntent(restoredScope), false);
    },
  );
  test(
    'decodable non-setup queue state is unknown, not a withdrawal',
    () async {
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode({'mode': 'on', 'cursor': 1})),
      );
      granted = true;

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      final calls = <AppOp>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add(op);
        return normal(op, req);
      };

      await AppApi(
        Uri.https('example.invalid'),
        handler,
        restored,
      ).logout(restoredScope);

      expect(grants, 0);
      expect(granted, true);
      expect(calls, [AppOp.logout]);
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      expect(restored.hasUnknownWithdrawal(restoredScope), true);

      final next = Sessions(secret, dir);
      await next.restore();
      final aAgain = await next.activate(tokens('A', 'A-new'));
      final aApi = AppApi(Uri.https('example.invalid'), handler, next);
      final aPort = Synthetic();
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        aPort,
        clock: () => now,
      );
      addTearDown(aSync.close);

      expect(await aSync.state(), {'mode': 'unknown'});
      await aSync.tick();
      expect(calls, [AppOp.logout]);
      expect(aPort.reads, 0);
      expect(granted, true);
    },
  );
  test('direct logout with no queue sends no health withdrawal', () async {
    granted = true;
    final restored = Sessions(secret, dir);
    await restored.restore();
    final restoredScope = restored.active!;
    final calls = <AppOp>[];
    final normal = handler.handle;
    handler.handle = (op, req) async {
      calls.add(op);
      return normal(op, req);
    };

    await AppApi(
      Uri.https('example.invalid'),
      handler,
      restored,
    ).logout(restoredScope);

    expect(grants, 0);
    expect(granted, true);
    expect(calls, [AppOp.logout]);
    expect(restored.active, isNull);
    expect(restored.hasWithdrawalIntent(restoredScope), false);
    expect(secret.value, isNull);
    expect(dir.listSync(), isEmpty);
  });
  test(
    'transient queue read failure is retried before direct online logout',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(granted, true);

      var reads = 0;
      final restored = Sessions(
        secret,
        dir,
        readCache: (file) async {
          reads++;
          if (reads == 1) {
            throw const FileSystemException('injected transient queue read');
          }
          return file.readAsBytes();
        },
      );
      await restored.restore();
      final restoredScope = restored.active!;
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      final calls = <AppOp>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add(op);
        return normal(op, req);
      };

      await AppApi(
        Uri.https('example.invalid'),
        handler,
        restored,
      ).logout(restoredScope);

      expect(reads, 2);
      expect(granted, false);
      expect(grants, 2);
      expect(calls, [AppOp.listConsents, AppOp.setConsent, AppOp.logout]);
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      expect(secret.value, isNull);
      expect(dir.listSync(), isEmpty);
    },
  );
  test(
    'corrupt queue remains unknown and requires A explicit withdrawal',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(granted, true);

      // The read succeeds, but this truncated ciphertext cannot prove a
      // withdrawal. That is different from failing to obtain the bytes.
      await dir.listSync().whereType<File>().single.writeAsBytes([0, 1, 2]);
      var reads = 0;
      final restored = Sessions(
        secret,
        dir,
        readCache: (file) async {
          reads++;
          return file.readAsBytes();
        },
      );
      await restored.restore();
      final restoredScope = restored.active!;
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      expect(restored.hasUnknownWithdrawal(restoredScope), false);

      offline = true;
      await expectLater(
        AppApi(
          Uri.https('example.invalid'),
          handler,
          restored,
        ).logout(restoredScope),
        throwsA(isA<SocketException>()),
      );
      offline = false;

      expect(reads, 1);
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      expect(restored.hasUnknownWithdrawal(restoredScope), true);
      final raw = jsonDecode(secret.value!) as Map;
      expect(raw.containsKey('tokens'), false);
      expect(raw.containsKey('key'), false);
      expect(dir.listSync(), isEmpty);

      final next = Sessions(secret, dir);
      await next.restore();
      expect(next.active, isNull);
      expect(next.hasWithdrawalIntent(restoredScope), false);
      expect(next.hasUnknownWithdrawal(restoredScope), true);

      final b = await next.activate(tokens('B', 'B-access'));
      expect(next.hasWithdrawalIntent(b), false);
      expect(next.hasUnknownWithdrawal(b), false);
      expect(next.hasUnknownWithdrawal(restoredScope), true);
      expect(await next.get(b, CacheKind.queue, HealthSync.key), isNull);
      final calls = <(AppOp, String?)>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add((op, req.headers['Authorization']));
        return normal(op, req);
      };
      final bApi = AppApi(Uri.https('example.invalid'), handler, next);
      final bPort = Synthetic();
      final bSync = HealthSync(
        bApi,
        b,
        ConsentGate(bApi),
        bPort,
        clock: () => now,
      );
      addTearDown(bSync.close);
      await bSync.tick();
      expect(calls, isEmpty);
      expect(bPort.reads, 0);

      final aAgain = await next.activate(tokens('A', 'A-new'));
      final aApi = AppApi(Uri.https('example.invalid'), handler, next);
      final aPort = Synthetic();
      final aSync = HealthSync(
        aApi,
        aAgain,
        ConsentGate(aApi),
        aPort,
        clock: () => now,
      );
      addTearDown(aSync.close);
      expect(await aSync.state(), {'mode': 'unknown'});
      await aSync.tick();
      expect(calls, isEmpty);
      expect(aPort.reads, 0);
      expect(granted, true);

      await aSync.resolveUnknown(withdraw: true);

      expect(granted, false);
      expect(calls.map((call) => call.$1), [
        AppOp.listConsents,
        AppOp.setConsent,
      ]);
      expect(calls.map((call) => call.$2), everyElement('Bearer A-new'));
      expect([aPort.reads, sent.length], [0, 0]);
      expect(next.hasWithdrawalIntent(aAgain), false);
      expect(next.hasUnknownWithdrawal(aAgain), false);
    },
  );
  test(
    'unknown queue stays stopped and keep decision never reads or withdraws',
    () async {
      granted = true;
      final (unknownSessions, aAgain) = await _unknownQueueForHealthSync(
        sessions,
        a,
        dir,
        secret,
      );
      final calls = <AppOp>[];
      final normal = handler.handle;
      handler.handle = (op, req) async {
        calls.add(op);
        return normal(op, req);
      };
      final unknownApi = AppApi(
        Uri.https('example.invalid'),
        handler,
        unknownSessions,
      );
      final unknownPort = Synthetic();
      final unknownSync = HealthSync(
        unknownApi,
        aAgain,
        ConsentGate(unknownApi),
        unknownPort,
        clock: () => now,
      );
      addTearDown(unknownSync.close);

      expect(await unknownSync.state(), {'mode': 'unknown'});
      await unknownSync.tick();
      expect(await unknownSync.state(), {'mode': 'unknown'});
      await expectLater(unknownSync.enable(), throwsA(isA<StateError>()));
      expect(unknownSessions.hasUnknownWithdrawal(aAgain), true);
      expect(calls, isEmpty);
      expect(unknownPort.reads, 0);

      await unknownSync.resolveUnknown(withdraw: false);

      expect(await unknownSync.state(), {'mode': 'off'});
      expect(unknownSessions.hasUnknownWithdrawal(aAgain), false);
      expect(unknownSessions.hasWithdrawalIntent(aAgain), false);
      expect(
        await unknownSessions.get(aAgain, CacheKind.queue, HealthSync.key),
        isNull,
      );
      expect(calls, isEmpty);
      expect(unknownPort.reads, 0);
      expect(granted, true);
    },
  );
  test(
    'single secret cleanup failure is retried before logout succeeds',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(granted, true);

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      secret
        ..replaceCalls = 0
        ..failNextReplace = true;

      await AppApi(
        Uri.https('example.invalid'),
        handler,
        restored,
      ).logout(restoredScope);

      expect(secret.replaceCalls, greaterThanOrEqualTo(3));
      expect(granted, false);
      expect(grants, 2);
      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(restoredScope), false);
      expect(secret.value, isNull);
      expect(dir.listSync(), isEmpty);

      final after = Sessions(secret, dir);
      await after.restore();
      expect(after.active, isNull);
      expect(after.hasWithdrawalIntent(restoredScope), false);
    },
  );
  test(
    'persistent cleanup failure is surfaced and keeps queue evidence',
    () async {
      await sync.enable();
      now += 600000;
      secret.failNextReplace = true;
      await expectLater(sync.withdraw(), throwsA(isA<FileSystemException>()));
      expect(granted, true);

      final restored = Sessions(secret, dir);
      await restored.restore();
      final restoredScope = restored.active!;
      secret.failReplaceCount = 99;
      offline = true;

      await expectLater(
        AppApi(
          Uri.https('example.invalid'),
          handler,
          restored,
        ).logout(restoredScope),
        throwsA(isA<FileSystemException>()),
      );
      offline = false;

      expect(restored.active, isNull);
      expect(restored.hasWithdrawalIntent(restoredScope), true);
      expect(dir.listSync(), isNotEmpty);
    },
  );
  test(
    'A native read completing after logout and B login never uploads',
    () async {
      await sync.enable();
      now += 600000;
      port.hold = Completer<void>();
      final oldTick = sync.tick();
      while (port.reads == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      offline = true;
      await expectLater(api.logout(a), throwsA(isA<SocketException>()));
      final b = await api.sessions.activate(tokens('B'));
      expect(identical(api.sessions.active, b), true);
      port.hold!.complete();
      await expectLater(oldTick, throwsA(isA<SessionChanged>()));
      expect(sent, isEmpty);
    },
  );
  test(
    'membership expiry during entitlement check stops before native read',
    () async {
      await sync.enable();
      now += 360000;
      final saved = await sync.state();
      saved['paid_until'] = now + 1000;
      await sessions.put(
        a,
        CacheKind.queue,
        HealthSync.key,
        utf8.encode(jsonEncode(saved)),
      );
      final normal = handler.handle;
      handler.handle = (op, req) async {
        if (op == AppOp.getEntitlements) now += 2000;
        return normal(op, req);
      };
      await sync.tick();
      expect(port.reads, 0);
      expect((await sync.state())['mode'], 'paused');
    },
  );
  test(
    '409 conflict is skipped and accounted before the next window',
    () async {
      await sync.enable();
      now += 600000;
      final first = (await sync.state())['cursor'] as int;
      port.rows = (from, _) => [
        ['heart_rate', from, from, 68],
        ['heart_rate', from + slotMs, from + slotMs, 72],
      ];
      final normal = handler.handle;
      var uploads = 0;
      handler.handle = (op, req) async {
        if (op == AppOp.uploadWindow && uploads++ == 0) {
          return response({'code': 'conflict', 'retryable': false}, 409);
        }
        return normal(op, req);
      };
      await sync.tick();
      final saved = await sync.state();
      expect(saved['skipped_conflicts'], 1);
      expect(sent, hasLength(1));
      expect(
        DateTime.parse(sent.single['starts_at']).millisecondsSinceEpoch,
        first + slotMs,
      );
    },
  );
  test(
    'non-retryable window rejection pauses instead of retrying forever',
    () async {
      await sync.enable();
      now += 600000;
      port.rows = (from, _) => [
        ['heart_rate', from, from, 68],
        ['heart_rate', from + slotMs, from + slotMs, 72],
      ];
      final normal = handler.handle;
      var uploads = 0;
      handler.handle = (op, req) async {
        if (op == AppOp.uploadWindow) {
          uploads++;
          return response({
            'code': 'invalid_argument',
            'retryable': false,
          }, 400);
        }
        return normal(op, req);
      };
      await sync.tick();
      expect(uploads, 1);
      expect((await sync.state())['mode'], 'paused');
      await sync.tick();
      expect(uploads, 1);
      expect(port.reads, 1);
    },
  );
}
