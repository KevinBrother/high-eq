import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';
import '../client_test.dart' show Handler, response;
import '../isolation_test.dart' show MemorySecret, tokens;

class _FaultVault extends MemorySecret {
  bool? Function(String?)? fault;
  int failReadCount = 0;
  int failReplaceCount = 0;

  @override
  Future<String?> read() async {
    if (failReadCount > 0) {
      failReadCount--;
      throw const FileSystemException('injected secure storage read failure');
    }
    return value;
  }

  @override
  Future<void> replace(String? next) async {
    final commitBeforeThrow = fault?.call(next);
    if (commitBeforeThrow != null) {
      if (commitBeforeThrow) value = next;
      throw const FileSystemException('injected lost write acknowledgement');
    }
    if (failReplaceCount > 0) {
      failReplaceCount--;
      throw const FileSystemException('injected secure storage write failure');
    }
    value = next;
  }
}

void main() {
  late Directory dir;
  late _FaultVault secret;
  late Sessions seed;
  late AccountScope a;

  void boundaryTest(String name, Future<void> Function() body) {
    test('cleanup journal: $name', () async {
      dir = await Directory.systemTemp.createTemp();
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      secret = _FaultVault();
      seed = Sessions(secret, dir);
      a = await seed.activate(tokens('A', 'A-old'));
      await body();
    });
  }

  Future<void> queue([String mode = 'explicit']) => seed.put(
    a,
    CacheKind.queue,
    Sessions.healthQueueKey,
    utf8.encode(
      jsonEncode(switch (mode) {
        'explicit' => {'mode': 'withdraw', 'withdrawal': 'explicit'},
        'setup' => {'mode': 'withdraw'},
        _ => {
          'mode': 'on',
          'cursor': 123,
          'samples': ['private-sentinel'],
        },
      }),
    ),
  );

  // A process image stopped after the journal rename but before copying the
  // intent to the vault. The real Sessions instance created the bound cache.
  Future<void> marker(String intent) async {
    await File('${dir.path}/.t28-cleanup.v1').writeAsString(
      jsonEncode({
        'account_tag': base64UrlEncode(
          (await Sha256().hash(utf8.encode('A'))).bytes,
        ),
        'kind': 'queue',
        'id': Sessions.healthQueueKey,
        'intent': intent,
      }),
    );
  }

  for (final entry in ['restore', 'activate', 'clear', '401', '401 replay']) {
    for (final mode in ['explicit', 'setup', 'unknown', 'absent']) {
      boundaryTest(
        '$entry replays $mode before discarding the only queue',
        () async {
          if (mode != 'absent') await queue(mode);
          if (!entry.startsWith('401')) await marker('pending');
          final next = Sessions(secret, dir);
          switch (entry) {
            case 'restore':
              await next.restore();
              expect(next.active, isNull);
            case 'activate':
              final b = await next.activate(tokens('B', 'B-new'));
              expect(next.hasWithdrawalIntent(b), false);
              expect(next.hasUnknownWithdrawal(b), false);
              expect(
                await next.get(b, CacheKind.queue, Sessions.healthQueueKey),
                isNull,
              );
            case 'clear':
              await next.clear();
              expect(next.active, isNull);
            case '401':
            case '401 replay':
              await next.restore();
              final handler = Handler();
              final ops = <AppOp>[];
              handler.handle = (op, _) async {
                ops.add(op);
                if (entry == '401 replay' && op == AppOp.refreshTokens) {
                  return response(tokens('A', 'A-rotated').toJson());
                }
                return response({}, 401);
              };
              await expectLater(
                AppApi(
                  Uri.https('example.invalid'),
                  handler,
                  next,
                ).json(AppOp.getGrowth, scope: next.active!),
                throwsA(
                  isA<ApiFailure>().having((e) => e.status, 'status', 401),
                ),
              );
              expect(ops, [
                AppOp.getGrowth,
                AppOp.refreshTokens,
                if (entry == '401 replay') AppOp.getGrowth,
              ]);
              expect(next.active, isNull);
          }
          expect(dir.listSync(), isEmpty);
          final restarted = Sessions(secret, dir);
          await restarted.restore();
          expect(restarted.hasWithdrawalIntent(a), mode == 'explicit');
          expect(restarted.hasUnknownWithdrawal(a), mode == 'unknown');
          final b = await restarted.activate(tokens('B', 'B-again'));
          expect(restarted.hasWithdrawalIntent(b), false);
          expect(restarted.hasUnknownWithdrawal(b), false);
          final aAgain = await restarted.activate(tokens('A', 'A-again'));
          expect(restarted.hasWithdrawalIntent(aAgain), mode == 'explicit');
          expect(restarted.hasUnknownWithdrawal(aAgain), mode == 'unknown');
          expect(
            await restarted.get(
              aAgain,
              CacheKind.queue,
              Sessions.healthQueueKey,
            ),
            isNull,
          );
        },
      );
    }
  }

  for (final (entry, mode) in [
    ('restore', 'explicit'),
    ('restore', 'unknown'),
    ('restore', 'setup'),
    ('activate', 'explicit'),
    ('clear', 'explicit'),
    ('logout', 'explicit'),
    ('logout with outbox', 'explicit'),
    ('401', 'explicit'),
    ('401 replay', 'explicit'),
  ]) {
    boundaryTest(
      '$entry defers unread $mode until the next recovery',
      () async {
        await queue(mode);
        final file = dir.listSync().whereType<File>().single;
        final ciphertext = await file.readAsBytes();
        if (entry == 'restore') await marker('pending');
        if (entry == 'logout with outbox') await seed.addWithdrawalIntent(a);
        var reads = 0;
        Future<List<int>> read(File file) async {
          if (++reads <= 3) {
            throw const FileSystemException('queue temporarily unavailable');
          }
          return file.readAsBytes();
        }

        final first = Sessions(secret, dir, readCache: read);
        final ops = <(AppOp, String?)>[];
        final handler = Handler()
          ..handle = (op, req) async {
            ops.add((op, req.headers['Authorization']));
            if (entry == '401 replay' && op == AppOp.refreshTokens) {
              return response(tokens('A', 'A-rotated').toJson());
            }
            return response({}, 401);
          };
        final api = AppApi(Uri.https('example.invalid'), handler, first);
        final ioFailure = throwsA(isA<FileSystemException>());
        switch (entry) {
          case 'restore':
            await expectLater(first.restore(), ioFailure);
          case 'activate':
            await expectLater(
              first.activate(tokens('B', 'B-first')),
              ioFailure,
            );
          case 'clear':
            await expectLater(first.clear(), ioFailure);
          case 'logout':
          case 'logout with outbox':
            await first.restore();
            final scope = first.active!;
            final exiting = api.logoutWithResult(scope);
            expect(first.active, isNull);
            final result = await exiting;
            expect(first.isCurrentLogout(result.round), true);
            expect(result.localCleanup, LogoutStatus.unconfirmed);
            expect(result.healthWithdrawal, LogoutHealthStatus.unconfirmed);
            expect(result.serverLogout, LogoutStatus.unconfirmed);
          case '401':
          case '401 replay':
            await first.restore();
            await expectLater(
              api.json(AppOp.getGrowth, scope: first.active!),
              entry == '401' ? throwsA(isA<ApiFailure>()) : ioFailure,
            );
        }
        expect(first.active, isNull);
        expect(first.hasUnknownWithdrawal(a), false);
        expect(first.hasWithdrawalIntent(a), entry == 'logout with outbox');
        expect(reads, 3);
        expect(await file.readAsBytes(), ciphertext);
        final raw = secret.value!;
        expect((jsonDecode(raw) as Map).keys, isNot(contains('tokens')));
        expect(raw, isNot(contains('access_token')));
        expect(raw, isNot(contains('refresh_token')));
        expect(ops, [
          if (entry.startsWith('401')) ...[
            (AppOp.getGrowth, 'Bearer A-old'),
            (AppOp.refreshTokens, null),
          ],
          if (entry == '401 replay') (AppOp.getGrowth, 'Bearer A-rotated'),
        ]);

        if (entry == 'clear') {
          // Once the credential-free checkpoint commits it is self-contained;
          // a lost directory marker cannot bring back A or drop the evidence.
          await File('${dir.path}/.t28-cleanup.v1').delete();
        }
        final next = Sessions(secret, dir, readCache: read);
        late final AccountScope b;
        if (entry == 'activate') {
          b = await next.activate(tokens('B', 'B-new'));
        } else {
          await next.restore();
          expect(next.active, isNull);
          b = await next.activate(tokens('B', 'B-new'));
        }
        expect(reads, 4);
        expect(dir.listSync(), isEmpty);
        expect(next.hasWithdrawalIntent(a), mode == 'explicit');
        expect(next.hasUnknownWithdrawal(a), mode == 'unknown');
        expect(next.hasWithdrawalIntent(b), false);
        expect(next.hasUnknownWithdrawal(b), false);

        ops.clear();
        handler.handle = (op, req) async {
          ops.add((op, req.headers['Authorization']));
          return switch (op) {
            AppOp.listConsents => response({
              'items': [
                {'purpose': 'health', 'granted': true, 'version': 'v1'},
              ],
            }),
            AppOp.setConsent => response({
              'purpose': 'health',
              'granted': false,
            }),
            AppOp.logout => response({}),
            _ => throw StateError('unexpected $op'),
          };
        };
        final after = AppApi(Uri.https('example.invalid'), handler, next);
        expect(
          (await after.logoutWithResult(b)).healthWithdrawal,
          LogoutHealthStatus.notRequired,
        );
        final aAgain = await next.activate(tokens('A', 'A-new'));
        final result = await after.logoutWithResult(aAgain);
        expect(result.healthWithdrawal, switch (mode) {
          'explicit' => LogoutHealthStatus.confirmed,
          'unknown' => LogoutHealthStatus.needsDecision,
          _ => LogoutHealthStatus.notRequired,
        });
        expect(ops, [
          (AppOp.logout, 'Bearer B-new'),
          if (mode == 'explicit') ...[
            (AppOp.listConsents, 'Bearer A-new'),
            (AppOp.setConsent, 'Bearer A-new'),
          ],
          (AppOp.logout, 'Bearer A-new'),
        ]);
      },
    );
  }

  boundaryTest(
    'unavailable queue stays fenced through a failed vault checkpoint',
    () async {
      await queue();
      final file = dir.listSync().whereType<File>().single;
      final ciphertext = await file.readAsBytes();
      await marker('pending');
      var readable = false;
      Future<List<int>> read(File file) async {
        if (!readable) throw const FileSystemException('queue unavailable');
        return file.readAsBytes();
      }

      final first = Sessions(secret, dir, readCache: read);
      secret.failReplaceCount = 3;
      await expectLater(
        first.restore(),
        throwsA(
          isA<CleanupEvidenceUnavailable>().having(
            (e) => e.checkpointError,
            'checkpointError',
            isA<FileSystemException>(),
          ),
        ),
      );
      expect(first.active, isNull);
      expect(await file.readAsBytes(), ciphertext);

      final after = Sessions(secret, dir, readCache: read);
      final unavailable = throwsA(isA<CleanupEvidenceUnavailable>());
      await expectLater(after.restore(), unavailable);
      expect(after.active, isNull);
      final checkpoint = secret.value!;
      expect((jsonDecode(checkpoint) as Map).keys, ['cleanup_queue']);
      await expectLater(after.activate(tokens('B')), unavailable);
      expect(after.active, isNull);
      expect(secret.value, checkpoint);
      expect(await file.readAsBytes(), ciphertext);
      expect(after.hasUnknownWithdrawal(a), false);

      readable = true;
      final b = await after.activate(tokens('B'));
      expect(after.hasWithdrawalIntent(a), true);
      expect(after.hasWithdrawalIntent(b), false);
      expect(dir.listSync(), isEmpty);
    },
  );

  for (final markerRemoved in [false, true]) {
    boundaryTest(
      'B is not committed if old wipe fails (marker removed: $markerRemoved)',
      () async {
        await queue();
        await marker('pending');
        var fail = true;
        final next = Sessions(
          secret,
          dir,
          wipeDirectory: (directory) async {
            if (fail) {
              final journal = File('${directory.path}/.t28-cleanup.v1');
              if (markerRemoved && await journal.exists()) {
                await journal.delete();
              }
              throw const FileSystemException('injected partial wipe');
            }
            await directory.delete(recursive: true);
            await directory.create();
          },
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            next.activate(tokens('B')),
            throwsA(isA<FileSystemException>()),
          );
          expect(next.active, isNull);
          final raw = jsonDecode(secret.value!) as Map;
          expect(raw.keys, unorderedEquals(['withdrawals', 'withdrawals_key']));
        }
        fail = false;
        final restarted = markerRemoved ? next : Sessions(secret, dir);
        if (!markerRemoved) await restarted.restore();
        expect(restarted.active, isNull);
        final handler = Handler()
          ..handle = (op, req) async {
            expect(op, AppOp.login);
            expect(req.headers['Authorization'], isNull);
            return response(tokens('B', 'B-clean').toJson());
          };
        final result =
            await AppApi(Uri.https('example.invalid'), handler, restarted).json(
              AppOp.login,
              body: {
                'credential': {'provider': 'phone', 'proof': '000000'},
              },
            );
        final b = await restarted.activate(Tokens.fromJson(result));
        expect(restarted.hasWithdrawalIntent(a), true);
        expect(restarted.hasWithdrawalIntent(b), false);
        expect(
          await restarted.get(b, CacheKind.queue, Sessions.healthQueueKey),
          isNull,
        );
      },
    );
  }

  boundaryTest(
    'repairs frozen B credentials plus stale A marker without assigning A intent to B',
    () async {
      await queue();
      final oldCache = dir.listSync().whereType<File>().single;
      final ciphertext = await oldCache.readAsBytes();
      await seed.addWithdrawalIntent(a);
      await seed.clear();
      await seed.activate(tokens('B', 'B-issued'));
      await oldCache.writeAsBytes(ciphertext);
      await marker('explicit');
      final restarted = Sessions(secret, dir);
      await restarted.restore();
      final b = restarted.active!;
      expect(restarted.require(b).access, 'B-issued');
      expect(restarted.hasWithdrawalIntent(a), true);
      expect(restarted.hasWithdrawalIntent(b), false);
      expect(dir.listSync(), isEmpty);
    },
  );

  for (final failures in [
    (local: false, withdrawal: true, server: false),
    (local: false, withdrawal: false, server: true),
    (local: true, withdrawal: false, server: false),
    (local: true, withdrawal: true, server: true),
  ]) {
    boundaryTest('logout reports each result separately $failures', () async {
      await queue();
      if (failures.local) secret.failReplaceCount = 99;
      final ops = <AppOp>[];
      final handler = Handler()
        ..handle = (op, req) async {
          ops.add(op);
          expect(req.headers['Authorization'], 'Bearer A-old');
          return switch (op) {
            AppOp.listConsents => response({
              'items': [
                {'purpose': 'health', 'granted': true, 'version': 'v1'},
              ],
            }),
            AppOp.setConsent =>
              failures.withdrawal
                  ? throw const SocketException('withdrawal unavailable')
                  : response({'purpose': 'health', 'granted': false}),
            AppOp.logout => response({}, failures.server ? 503 : 200),
            _ => throw StateError('unexpected $op'),
          };
        };
      final api = AppApi(Uri.https('example.invalid'), handler, seed);
      final loggingOut = api.logoutWithResult(a);
      expect(seed.active, isNull);
      final result = await loggingOut;
      expect(result.round.scope, same(a));
      expect(seed.isCurrentLogout(result.round), true);
      expect(
        result.localCleanup,
        failures.local ? LogoutStatus.unconfirmed : LogoutStatus.confirmed,
      );
      expect(
        result.healthWithdrawal,
        failures.withdrawal
            ? LogoutHealthStatus.unconfirmed
            : LogoutHealthStatus.confirmed,
      );
      expect(
        result.serverLogout,
        failures.server ? LogoutStatus.unconfirmed : LogoutStatus.confirmed,
      );
      expect(ops, [AppOp.listConsents, AppOp.setConsent, AppOp.logout]);
      expect(
        seed.hasWithdrawalIntent(a),
        failures.local || failures.withdrawal,
      );
    });
  }

  for (final mode in ['setup', 'unknown']) {
    boundaryTest('logout does not report $mode as remote withdrawal', () async {
      await queue(mode);
      final handler = Handler()
        ..handle = (op, _) async {
          expect(op, AppOp.logout);
          return response({});
        };
      final result = await AppApi(
        Uri.https('example.invalid'),
        handler,
        seed,
      ).logoutWithResult(a);
      expect(
        result.healthWithdrawal,
        mode == 'unknown'
            ? LogoutHealthStatus.needsDecision
            : LogoutHealthStatus.notRequired,
      );
      expect(result.serverLogout, LogoutStatus.confirmed);
      expect(result.localCleanup, LogoutStatus.confirmed);
    });
  }

  for (final nextAccount in ['A', 'B']) {
    boundaryTest(
      'late A acknowledgement is stale after $nextAccount exits',
      () async {
        await queue();
        final started = Completer<void>();
        final release = Completer<void>();
        final handler = Handler()
          ..handle = (op, req) async {
            switch (op) {
              case AppOp.listConsents:
                if (req.headers['Authorization'] != 'Bearer A-old') {
                  throw const SocketException('new round is offline');
                }
                return response({
                  'items': [
                    {'purpose': 'health', 'granted': true, 'version': 'v1'},
                  ],
                });
              case AppOp.setConsent:
                expect(req.headers['Authorization'], 'Bearer A-old');
                started.complete();
                await release.future;
                return response({'purpose': 'health', 'granted': false});
              case AppOp.logout:
                return response({});
              default:
                throw StateError('unexpected $op');
            }
          };
        final api = AppApi(Uri.https('example.invalid'), handler, seed);
        final first = api.logoutWithResult(a);
        await started.future;
        final newer = await seed.activate(tokens(nextAccount, 'new-session'));
        if (nextAccount == 'A') await seed.addWithdrawalIntent(newer);
        final second = await api.logoutWithResult(newer);
        release.complete();
        final old = await first;
        expect(old.healthWithdrawal, LogoutHealthStatus.confirmed);
        expect(seed.isCurrentLogout(old.round), false);
        expect(seed.isCurrentLogout(second.round), true);
        expect(identical(old.round.scope, second.round.scope), false);
        expect(seed.hasWithdrawalIntent(a), true);
        expect(seed.hasWithdrawalIntent(newer), nextAccount == 'A');
      },
    );
  }

  boundaryTest(
    'active logout journals evidence even while the vault is locked',
    () async {
      await queue();
      secret.failReadCount = 99;
      secret.failReplaceCount = 99;
      final handler = Handler()
        ..handle = (_, _) async => throw const SocketException('offline');
      final api = AppApi(Uri.https('example.invalid'), handler, seed);
      final exit = await api.logoutWithResult(a);
      expect(exit.localCleanup, LogoutStatus.unconfirmed);
      expect(await File('${dir.path}/.t28-cleanup.v1').exists(), true);
      secret.failReadCount = 0;
      secret.failReplaceCount = 0;
      final restarted = Sessions(secret, dir);
      await restarted.restore();
      expect(restarted.active, isNull);
      expect(restarted.hasWithdrawalIntent(a), true);
    },
  );

  boundaryTest(
    'lost retirement acknowledgement is recovered from the durable commit',
    () async {
      await queue();
      await marker('pending');
      secret.fault = (value) {
        final data = jsonDecode(value!) as Map;
        if (data.containsKey('tokens')) return null;
        secret.failReadCount = 1; // even readback cannot confirm this attempt
        return true;
      };
      final next = Sessions(secret, dir);
      await expectLater(
        next.activate(tokens('B')),
        throwsA(isA<FileSystemException>()),
      );
      expect(next.active, isNull);
      expect(File('${dir.path}/.t28-cleanup.v1').existsSync(), true);
      secret.fault = null;
      final restarted = Sessions(secret, dir);
      await restarted.restore();
      expect(restarted.active, isNull);
      expect(restarted.hasWithdrawalIntent(a), true);
      expect((await restarted.activate(tokens('B'))).account, 'B');
    },
  );

  for (final commits in [false, true]) {
    boundaryTest(
      'lost B write acknowledgement (committed: $commits)',
      () async {
        await queue();
        await marker('pending');
        secret.fault = (next) {
          final data = next == null ? null : jsonDecode(next) as Map;
          return data?['tokens']?['user_id'] == 'B' ? commits : null;
        };
        final next = Sessions(secret, dir);
        if (commits) {
          expect((await next.activate(tokens('B'))).account, 'B');
        } else {
          await expectLater(
            next.activate(tokens('B')),
            throwsA(isA<FileSystemException>()),
          );
        }
        secret.fault = null;
        final restarted = Sessions(secret, dir);
        await restarted.restore();
        expect(restarted.active?.account, commits ? 'B' : null);
        expect(restarted.hasWithdrawalIntent(a), true);
        expect(dir.listSync(), isEmpty);
      },
    );
  }
}
