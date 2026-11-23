import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/app_op.g.dart';
import 'package:high_eq/core/session.dart';

import 'client_test.dart' show Handler, response;
import 'isolation_test.dart' show tokens;

final _queue = utf8.encode('{"mode":"on","samples":["synthetic-window"]}');

class _DiskSecret implements SecretStore {
  _DiskSecret(this.file, {required this.rejectWrites});

  final File file;
  final bool rejectWrites;

  @override
  Future<String?> read() async {
    try {
      return await file.readAsString();
    } on PathNotFoundException {
      return null;
    }
  }

  @override
  Future<void> replace(String? value) async {
    if (rejectWrites) {
      throw const FileSystemException('injected vault write failure');
    }
    if (value == null) {
      if (await file.exists()) await file.delete();
    } else {
      await file.writeAsString(value, flush: true);
    }
  }
}

Sessions _sessions(
  String root, {
  bool vaultUnavailable = false,
  bool queueUnavailable = false,
}) => Sessions(
  _DiskSecret(File('$root/vault'), rejectWrites: vaultUnavailable),
  Directory('$root/cache'),
  readCache: queueUnavailable ? _unavailableQueue : null,
  retirementBarrier: File('$root/support/session-retirement/test.v1'),
);

Future<List<int>> _unavailableQueue(File _) async {
  throw const FileSystemException('injected queue read failure');
}

Future<({String? account, List<int>? queue, String? failure})> _coldRestore(
  String root, {
  bool vaultUnavailable = false,
  bool queueUnavailable = false,
}) => Isolate.run(() async {
  // No Sessions, vault object, test callback, or scope crosses the boundary.
  final sessions = _sessions(
    root,
    vaultUnavailable: vaultUnavailable,
    queueUnavailable: queueUnavailable,
  );
  String? failure;
  try {
    await sessions.restore();
  } on CleanupEvidenceUnavailable {
    failure = 'queue evidence unavailable';
  } on FileSystemException {
    failure = 'local cleanup incomplete';
  }
  final scope = sessions.active;
  return (
    account: scope?.account,
    queue: scope == null
        ? null
        : await sessions.get(scope, CacheKind.queue, Sessions.healthQueueKey),
    failure: failure,
  );
});

void main() {
  for (final queueUnavailable in [false, true]) {
    test(
      'business 401 then refresh 503 fences cold restore despite journal and '
      'vault failure (queue unreadable: $queueUnavailable)',
      () async {
        final directory = await Directory.systemTemp.createTemp();
        addTearDown(() => directory.delete(recursive: true));
        final root = directory.path;
        final seed = _sessions(root);
        final a = await seed.activate(tokens('A', 'old-access'));
        await seed.put(a, CacheKind.queue, Sessions.healthQueueKey, _queue);
        final ciphertext = await Directory(
          '$root/cache',
        ).list().where((entry) => entry is File).cast<File>().single;
        final savedQueue = await ciphertext.readAsBytes();
        final vault = File('$root/vault');
        final savedVault = await vault.readAsString();

        // The production journal writes to this temporary path before rename.
        // A directory here forces every journal write to fail without removing
        // the encrypted queue or changing permissions on the rest of the store.
        await Directory('$root/cache/.t28-cleanup.v1.tmp').create();
        final live = _sessions(
          root,
          vaultUnavailable: true,
          queueUnavailable: queueUnavailable,
        );
        await live.restore();
        final oldScope = live.active!;
        final sent = <(AppOp, String?)>[];
        final transport = Handler()
          ..handle = (op, request) async {
            sent.add((op, request.headers['Authorization']));
            return response({}, op == AppOp.refreshTokens ? 503 : 401);
          };
        final api = AppApi(Uri.https('test.invalid'), transport, live);
        await expectLater(
          api.json(AppOp.getGrowth, scope: oldScope),
          queueUnavailable
              ? throwsA(
                  isA<CleanupEvidenceUnavailable>().having(
                    (error) => error.checkpointError,
                    'checkpointError',
                    isA<FileSystemException>(),
                  ),
                )
              : throwsA(isA<FileSystemException>()),
        );
        expect(live.active, isNull);
        expect(() => live.require(oldScope), throwsA(isA<SessionChanged>()));
        expect(sent, [
          (AppOp.getGrowth, 'Bearer old-access'),
          (AppOp.refreshTokens, null),
        ]);
        expect(await vault.readAsString(), savedVault);
        expect(await ciphertext.readAsBytes(), savedQueue);
        expect(await File('$root/cache/.t28-cleanup.v1').exists(), isFalse);

        expect(
          await _coldRestore(
            root,
            vaultUnavailable: true,
            queueUnavailable: queueUnavailable,
          ),
          (
            account: null,
            queue: null,
            failure: queueUnavailable
                ? 'queue evidence unavailable'
                : 'local cleanup incomplete',
          ),
        );
        expect(await vault.readAsString(), savedVault);
        expect(await ciphertext.readAsBytes(), savedQueue);
        final barrier = File('$root/support/session-retirement/test.v1');
        expect(await barrier.readAsString(), '1');

        expect(await _coldRestore(root), (
          account: null,
          queue: null,
          failure: null,
        ));
        expect(await ciphertext.exists(), isFalse);
        expect(await barrier.exists(), isFalse);
        final next = _sessions(root);
        final b = await next.activate(tokens('B', 'new-access'));
        expect(next.hasUnknownWithdrawal(oldScope), isTrue);
        expect(next.hasUnknownWithdrawal(b), isFalse);
        expect(await _coldRestore(root), (
          account: 'B',
          queue: null,
          failure: null,
        ));
      },
    );
  }

  test(
    'ordinary 503 preserves a valid session and encrypted queue offline',
    () async {
      final directory = await Directory.systemTemp.createTemp();
      addTearDown(() => directory.delete(recursive: true));
      final root = directory.path;
      final live = _sessions(root);
      final a = await live.activate(tokens('A'));
      await live.put(a, CacheKind.queue, Sessions.healthQueueKey, _queue);
      final ciphertext = await Directory(
        '$root/cache',
      ).list().cast<File>().single;
      final savedQueue = await ciphertext.readAsBytes();
      final transport = Handler()
        ..handle = (op, _) async {
          expect(op, AppOp.getGrowth);
          return response({}, 503);
        };
      final api = AppApi(Uri.https('test.invalid'), transport, live);
      await expectLater(
        api.json(AppOp.getGrowth, scope: a),
        throwsA(
          isA<ApiFailure>().having((error) => error.status, 'status', 503),
        ),
      );
      final reopened = await _coldRestore(root);
      expect(reopened.account, 'A');
      expect(reopened.queue, _queue);
      expect(reopened.failure, isNull);
      expect(await ciphertext.readAsBytes(), savedQueue);
    },
  );
}
