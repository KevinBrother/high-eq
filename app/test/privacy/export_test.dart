import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/privacy/export.dart';
import 'package:high_eq/features/privacy/export_delivery.dart';
import 'package:high_eq/features/privacy/export_namespace.dart';

import 'export_test_support.dart';

Future<({Directory root, Directory directory})> _createTripleInListingOrder({
  required bool finalFirst,
}) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    final root = await Directory.systemTemp.createTemp(
      't35-cleanup-triple-order-',
    );
    final directory = await Directory('${root.path}/staging').create();
    final finalFile = File(
      '${directory.path}/high-eq-export-${attempt + 1}-1.zip',
    );
    final part = File('${finalFile.path}.part');
    final source = finalFirst ? finalFile : part;
    final otherAlias = finalFirst ? part : finalFile;
    await source.writeAsBytes([1, 2, 3]);
    await createPrivacyExportOwnerRecord(source);
    await createPrivacyExportHardLink(source, otherAlias.path);

    final firstAlias = directory.listSync().whereType<File>().firstWhere(
      (entity) => entity.path.endsWith('.zip') || entity.path.endsWith('.part'),
    );
    if (firstAlias.path.endsWith('.zip') == finalFirst) {
      return (root: root, directory: directory);
    }
    await root.delete(recursive: true);
  }
  fail('could not create a synthetic export listing in the requested order');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cn.higheq/mobile-commerce');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const delivery = PlatformPrivacyExportDelivery();
  const path = '/tmp/t35-synthetic-export.zip';
  const mimeType = 'application/zip';

  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('native delivery checks startup cleanup before shareExport', () async {
    final received = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      received.add(call);
      if (call.method == 'cleanupStatus') {
        return {'state': 'ok', 'removed': 0, 'failed': 0};
      }
      return null;
    });

    await delivery.deliver(path: path, mimeType: mimeType);

    expect(received.map((call) => call.method), [
      'cleanupStatus',
      'shareExport',
    ]);
    final args = received.last.arguments as Map;
    expect(args['requestId'], allOf(isA<int>(), isPositive));
    expect(args, {
      'path': path,
      'mimeType': mimeType,
      'requestId': args['requestId'],
    });
  });

  test('discard keeps the ZIP while the native save is using it', () async {
    final root = await Directory.systemTemp.createTemp('t35-native-use-');
    addTearDown(() => root.delete(recursive: true));
    final bytes = await _exportFixture();
    final sink = FilePrivacyExportSink.forAccount(root, 'A');
    final artifact = await sink.save(Stream.value(bytes));
    final started = Completer<void>();
    final release = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cleanupStatus') {
        return {'state': 'ok', 'removed': 0, 'failed': 0};
      }
      expect(call.method, 'shareExport');
      final args = call.arguments as Map;
      expect(args['requestId'], allOf(isA<int>(), isPositive));
      expect(args, {
        'path': artifact.path,
        'mimeType': mimeType,
        'requestId': args['requestId'],
      });
      started.complete();
      await release.future;
      return null;
    });

    final sharing = delivery.deliverArtifact(
      artifact,
      requireAllowed: () {},
      onDispatched: () {},
      onPresented: () {},
    );
    await started.future;
    final cleanup = artifact.cleanup!.discard();
    try {
      await sink.reclaimInterruptedArtifacts();
      expect(await File(artifact.path).readAsBytes(), bytes);
      expect(await File('${artifact.path}.owner').exists(), isTrue);
    } finally {
      release.complete();
      await sharing;
      await cleanup;
    }

    expect(root.listSync(recursive: true), isEmpty);
  });

  test(
    'artifact delivery rechecks permission after cleanup before sharing',
    () async {
      final received = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        received.add(call);
        if (call.method == 'cleanupStatus') {
          return {'state': 'ok', 'removed': 0, 'failed': 0};
        }
        return null;
      });
      var permissionChecks = 0;

      await expectLater(
        delivery.deliverArtifact(
          const PrivacyExportArtifact(path: path, bytes: 1),
          requireAllowed: () {
            permissionChecks++;
            throw const PrivacyExportDeliveryFailure(
              privacyExportCancelledMessage,
              deliveryCode: 'cancelled',
            );
          },
          onDispatched: () => fail('a rejected request was dispatched'),
          onPresented: () => fail('a rejected request presented the sheet'),
        ),
        throwsA(
          isA<PrivacyExportDeliveryFailure>().having(
            (error) => error.deliveryCode,
            'deliveryCode',
            'cancelled',
          ),
        ),
      );

      expect(permissionChecks, 1);
      expect(received.map((call) => call.method), ['cleanupStatus']);
    },
  );

  for (final (:code, :message) in [
    (code: 'cancelled', message: privacyExportCancelledMessage),
    (code: 'unavailable', message: privacyExportUnavailableMessage),
    (code: 'io_error', message: privacyExportIoErrorMessage),
  ]) {
    test('platform error $code maps to the fixed user message', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cleanupStatus') {
          return {'state': 'ok', 'removed': 0, 'failed': 0};
        }
        throw PlatformException(code: code);
      });

      await expectLater(
        delivery.deliver(path: path, mimeType: mimeType),
        throwsA(
          isA<PrivacyExportDeliveryFailure>()
              .having((error) => error.deliveryCode, 'deliveryCode', code)
              .having((error) => error.message, 'message', message),
        ),
      );
    });
  }

  test('missing native handler maps to unavailable', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });

    await expectLater(
      delivery.deliver(path: path, mimeType: mimeType),
      throwsA(
        isA<PrivacyExportDeliveryFailure>()
            .having(
              (error) => error.deliveryCode,
              'deliveryCode',
              'unavailable',
            )
            .having(
              (error) => error.message,
              'message',
              privacyExportUnavailableMessage,
            ),
      ),
    );
  });

  test('malformed startup cleanup status blocks native delivery', () async {
    var shared = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cleanupStatus') {
        return {'state': 'ok', 'removed': 0};
      }
      shared = true;
      return null;
    });

    await expectLater(
      delivery.deliver(path: path, mimeType: mimeType),
      throwsA(
        isA<PrivacyExportDeliveryFailure>()
            .having(
              (error) => error.deliveryCode,
              'deliveryCode',
              'cleanup_failed',
            )
            .having(
              (error) => error.message,
              'message',
              privacyExportCleanupFailedMessage,
            ),
      ),
    );
    expect(shared, isFalse);
  });

  test('failed startup cleanup blocks native delivery', () async {
    var shared = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cleanupStatus') {
        return {'state': 'failed', 'removed': 0, 'failed': 1};
      }
      shared = true;
      return null;
    });

    await expectLater(
      delivery.deliver(path: path, mimeType: mimeType),
      throwsA(
        isA<PrivacyExportDeliveryFailure>()
            .having(
              (error) => error.deliveryCode,
              'deliveryCode',
              'cleanup_failed',
            )
            .having(
              (error) => error.message,
              'message',
              privacyExportCleanupFailedMessage,
            ),
      ),
    );
    expect(shared, isFalse);
  });

  test('startup cleanup removes only module staging artifacts', () async {
    final directory = await Directory.systemTemp.createTemp(
      't35-cleanup-test-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final moduleZip = File('${directory.path}/high-eq-export-1.zip');
    final modulePart = File('${directory.path}/high-eq-export-1-2.zip.part');
    final userZip = File('${directory.path}/user-selected.zip');
    final unowned = File('${directory.path}/high-eq-export-2.zip');
    final unrelated = File('${directory.path}/high-eq-export-notes.txt');
    final nested = Directory('${directory.path}/nested')..createSync();
    final nestedPart = File('${nested.path}/high-eq-export-3.zip.part');
    await Future.wait([
      moduleZip.writeAsBytes([1]),
      modulePart.writeAsBytes([2]),
      unowned.writeAsBytes([6]),
      userZip.writeAsBytes([3]),
      unrelated.writeAsBytes([4]),
      nestedPart.writeAsBytes([5]),
    ]);
    await createPrivacyExportOwnerRecord(moduleZip);
    await createPrivacyExportOwnerRecord(modulePart);

    final status = await cleanupPrivacyExportStorage(directory);

    expect(status.ok, isTrue);
    expect(status.removed, 2);
    expect(status.failed, 0);
    expect(await moduleZip.exists(), isFalse);
    expect(await modulePart.exists(), isFalse);
    expect(await File('${moduleZip.path}.owner').exists(), isFalse);
    expect(await File(privacyExportOwnerPath(modulePart)).exists(), isFalse);
    expect(await unowned.readAsBytes(), [6]);
    expect(await userZip.exists(), isTrue);
    expect(await unrelated.exists(), isTrue);
    expect(await nestedPart.exists(), isTrue);
  });

  test(
    'startup cleanup leaves unrelated same-named part links untouched',
    () async {
      final root = await Directory.systemTemp.createTemp(
        't35-cleanup-link-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final staging = await Directory('${root.path}/staging').create();
      final protected = await File(
        '${root.path}/synthetic-protected-export.bin',
      ).writeAsBytes([9, 8, 7]);
      final link = await Link(
        '${staging.path}/high-eq-export-18.zip.part',
      ).create(protected.path);
      final ownedPart = File('${staging.path}/high-eq-export-19.zip.part');
      await ownedPart.writeAsBytes([1, 2, 3]);
      await createPrivacyExportOwnerRecord(ownedPart);

      final status = await cleanupPrivacyExportStorage(staging);

      expect(status.ok, isTrue);
      expect(status.removed, 1);
      expect(status.failed, 0);
      expect(await ownedPart.exists(), isFalse);
      expect(await File(privacyExportOwnerPath(ownedPart)).exists(), isFalse);
      expect(
        await FileSystemEntity.type(link.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(await protected.readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'published ownership record does not expose a second ZIP copy',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        't35-owner-record-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final bytes = await _exportFixture();
      final artifact = await FilePrivacyExportSink(
        directory,
      ).save(Stream<List<int>>.value(bytes));
      final owner = File('${artifact.path}.owner');

      expect(await owner.readAsBytes(), isNot(equals(bytes)));
      expect(await owner.length(), lessThan(512));

      await artifact.cleanup!.discard();
      expect(directory.listSync(), isEmpty);
    },
  );

  test('cold recovery removes an owner-only published residue', () async {
    final directory = await Directory.systemTemp.createTemp(
      't35-owner-recovery-',
    );
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final bytes = await _exportFixture();
    final artifact = await FilePrivacyExportSink(
      directory,
    ).save(Stream<List<int>>.value(bytes));
    final owner = File('${artifact.path}.owner');
    await File(artifact.path).delete();

    await FilePrivacyExportSink(directory).reclaimInterruptedArtifacts();

    expect(await owner.exists(), isFalse);
    expect(directory.listSync(), isEmpty);
  });

  test(
    'cleanup preserves an owner-shaped link without module metadata',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        't35-owner-negative-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final protected = await File(
        '${directory.parent.path}/synthetic-owner-target.zip',
      ).writeAsBytes([9, 8, 7]);
      addTearDown(() async {
        if (await protected.exists()) await protected.delete();
      });
      final owner = await Link(
        '${directory.path}/high-eq-export-31-1.zip.owner',
      ).create(protected.path);

      final status = await cleanupPrivacyExportStorage(directory);

      expect(status.ok, isTrue);
      expect(await owner.exists(), isTrue);
      expect(await protected.readAsBytes(), [9, 8, 7]);
    },
  );

  for (final finalFirst in [true, false]) {
    test('startup cleanup removes final, part, and owner aliases when '
        '${finalFirst ? 'final' : 'part'} is enumerated first', () async {
      final fixture = await _createTripleInListingOrder(finalFirst: finalFirst);
      addTearDown(() async {
        if (await fixture.root.exists()) {
          await fixture.root.delete(recursive: true);
        }
      });
      final firstAlias = fixture.directory
          .listSync()
          .whereType<File>()
          .firstWhere(
            (entity) =>
                entity.path.endsWith('.zip') || entity.path.endsWith('.part'),
          );
      expect(firstAlias.path.endsWith('.zip'), finalFirst);

      final status = await cleanupPrivacyExportStorage(fixture.directory);

      expect(status.ok, isTrue);
      expect(status.failed, 0);
      expect(fixture.directory.listSync(), isEmpty);
    });
  }

  test('startup cleanup retries every owned alias after restarting', () async {
    final directory = await Directory.systemTemp.createTemp(
      't35-cleanup-triple-retry-',
    );
    var permissionChanged = false;
    addTearDown(() async {
      if (permissionChanged) {
        await Process.run('chmod', ['700', directory.path]);
      }
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final part = File('${directory.path}/high-eq-export-22-1.zip.part');
    final finalFile = File('${directory.path}/high-eq-export-22-1.zip');
    final owner = File('${finalFile.path}.owner');
    await part.writeAsBytes([4, 5, 6]);
    await createPrivacyExportOwnerRecord(part);
    await createPrivacyExportHardLink(part, finalFile.path);

    final blocked = await Process.run('chmod', ['500', directory.path]);
    expect(blocked.exitCode, 0, reason: blocked.stderr.toString());
    permissionChanged = true;
    final first = await cleanupPrivacyExportStorage(directory);
    expect(first.ok, isFalse);
    expect(await owner.exists(), isTrue);

    final restored = await Process.run('chmod', ['700', directory.path]);
    expect(restored.exitCode, 0, reason: restored.stderr.toString());
    permissionChanged = false;
    final retried = await cleanupPrivacyExportStorage(directory);

    expect(retried.ok, isTrue);
    expect(retried.failed, 0);
    expect(directory.listSync(), isEmpty);
  });

  test('startup cleanup refuses a linked staging directory', () async {
    final directory = await Directory.systemTemp.createTemp(
      't35-cleanup-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final sibling = await Directory('${directory.path}/sibling').create();
    final protected = await File(
      '${sibling.path}/high-eq-export-1.zip',
    ).writeAsString('synthetic user file');
    final link = await Link('${directory.path}/staging').create(sibling.path);

    final status = await cleanupPrivacyExportStorage(Directory(link.path));

    expect(status.ok, isFalse);
    expect(status.removed, 0);
    expect(await protected.readAsString(), 'synthetic user file');
  });

  group('file export validation', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('t35-export-test-');
    });

    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    Future<void> expectRejected(List<int> bytes) async {
      final sink = FilePrivacyExportSink(directory);
      await expectLater(
        sink.save(Stream<List<int>>.value(bytes)),
        throwsA(isA<FormatException>()),
      );
      expect(directory.listSync(), isEmpty);
    }

    test('recovery preserves an artifact owned by an active export', () async {
      final bytes = await _exportFixture();
      final artifact = await FilePrivacyExportSink(
        directory,
      ).save(Stream<List<int>>.value(bytes));

      await FilePrivacyExportSink(directory).reclaimInterruptedArtifacts();

      expect(await File(artifact.path).exists(), isTrue);
      await artifact.cleanup!.discard();
      expect(await File(artifact.path).exists(), isFalse);
    });

    test('recovery preserves an active part and its owner record', () async {
      final bytes = await _exportFixture();
      final started = Completer<void>();
      final release = Completer<void>();
      Stream<List<int>> staged() async* {
        yield bytes.sublist(0, 7);
        started.complete();
        await release.future;
        yield bytes.sublist(7);
      }

      final saving = FilePrivacyExportSink(directory).save(staged());
      await started.future;
      final part = privacyExportPart(directory);
      final owner = File(privacyExportOwnerPath(part));

      await FilePrivacyExportSink(directory).reclaimInterruptedArtifacts();

      expect(await part.exists(), isTrue);
      expect(await owner.exists(), isTrue);
      release.complete();
      final artifact = await saving;
      expect(await File(artifact.path).readAsBytes(), bytes);
      await artifact.cleanup!.discard();
      expect(directory.listSync(), isEmpty);
    });

    test(
      'account A retries a failed cleanup without scanning account B',
      () async {
        final bytes = await _exportFixture();
        final root = await Directory.systemTemp.createTemp('t35-account-a-');
        addTearDown(() async {
          await Process.run('chmod', ['700', root.path]);
          if (await root.exists()) await root.delete(recursive: true);
        });
        final directoryA = await privacyExportAccountDirectory(root, 'A');
        await directoryA.create(recursive: true);
        final staleA = File('${directoryA.path}/high-eq-export-18.zip');
        await staleA.writeAsBytes(bytes);
        await createPrivacyExportOwnerRecord(staleA);
        final changed = await Process.run('chmod', ['500', directoryA.path]);
        expect(changed.exitCode, 0, reason: changed.stderr.toString());

        await expectLater(
          FilePrivacyExportSink.forAccount(
            root,
            'A',
          ).reclaimInterruptedArtifacts(),
          throwsA(isA<FileSystemException>()),
        );
        expect(await staleA.exists(), isTrue);

        await FilePrivacyExportSink.forAccount(
          root,
          'B',
        ).reclaimInterruptedArtifacts();
        expect(await staleA.exists(), isTrue);
        expect(await File('${staleA.path}.owner').exists(), isTrue);

        final restored = await Process.run('chmod', ['700', directoryA.path]);
        expect(restored.exitCode, 0, reason: restored.stderr.toString());
        await FilePrivacyExportSink.forAccount(
          root,
          'A',
        ).reclaimInterruptedArtifacts();

        expect(await staleA.exists(), isFalse);
        expect(await File('${staleA.path}.owner').exists(), isFalse);
        expect(directoryA.listSync(), isEmpty);
      },
    );

    test(
      'owned lazy staging directory is pruned after its ZIP is discarded',
      () async {
        final bytes = await _exportFixture();
        final root = await Directory.systemTemp.createTemp('t35-lazy-export-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final staging = Directory('${root.path}/high-eq-privacy-exports');
        final sink = FilePrivacyExportSink.lazy(
          () async => staging,
          pruneEmptyDirectory: true,
        );

        final artifact = await sink.save(Stream<List<int>>.value(bytes));

        expect(await staging.exists(), isTrue);
        expect(await File(artifact.path).readAsBytes(), bytes);
        expect(root.listSync().map((entry) => entry.path).toList(), [
          staging.path,
        ]);
        expect(
          staging
              .listSync()
              .whereType<File>()
              .map((entry) => entry.path)
              .toList()
            ..sort(),
          [artifact.path, '${artifact.path}.owner'],
        );
        await artifact.cleanup!.discard();

        expect(await File(artifact.path).exists(), isFalse);
        expect(await staging.exists(), isFalse);
        expect(root.listSync(recursive: true), isEmpty);
      },
    );

    test(
      'owned lazy staging directory is kept while a user file remains',
      () async {
        final bytes = await _exportFixture();
        final root = await Directory.systemTemp.createTemp('t35-lazy-export-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final staging = Directory('${root.path}/high-eq-privacy-exports');
        final foreignBytes = utf8.encode('synthetic-user-file');
        final sink = FilePrivacyExportSink.lazy(
          () async => staging,
          pruneEmptyDirectory: true,
        );

        final artifact = await sink.save(Stream<List<int>>.value(bytes));
        final foreign = await File(
          '${staging.path}/high-eq-export-999-1.zip',
        ).writeAsBytes(foreignBytes);
        await artifact.cleanup!.discard();

        expect(await File(artifact.path).exists(), isFalse);
        expect(await staging.exists(), isTrue);
        expect(await foreign.readAsBytes(), foreignBytes);
        expect(staging.listSync().map((entry) => entry.path).toList(), [
          foreign.path,
        ]);

        await foreign.delete();
        await artifact.cleanup!.discard();
        expect(await staging.exists(), isFalse);
      },
    );

    test(
      'owned lazy staging directory is pruned after a rejected ZIP',
      () async {
        final bytes = await _exportFixture();
        final root = await Directory.systemTemp.createTemp('t35-lazy-export-');
        addTearDown(() async {
          if (await root.exists()) await root.delete(recursive: true);
        });
        final staging = Directory('${root.path}/high-eq-privacy-exports');
        final sink = FilePrivacyExportSink.lazy(
          () async => staging,
          pruneEmptyDirectory: true,
        );

        await expectLater(
          sink.save(
            Stream<List<int>>.value(bytes.sublist(0, bytes.length - 8)),
          ),
          throwsA(isA<PrivacyExportIntegrityFailure>()),
        );

        expect(await staging.exists(), isFalse);
        expect(root.listSync(recursive: true), isEmpty);
      },
    );

    test('scoped cleanup prunes only its own unused namespace', () async {
      final bytes = await _exportFixture();
      final sinkA = FilePrivacyExportSink.forAccount(directory, 'A');
      final sinkB = FilePrivacyExportSink.forAccount(directory, 'B');
      final accountA = await privacyExportAccountDirectory(directory, 'A');
      final accountB = await privacyExportAccountDirectory(directory, 'B');
      final a = await sinkA.save(Stream.value(bytes));
      final secondA = await sinkA.save(Stream.value(bytes));
      final b = await sinkB.save(Stream.value(bytes));

      await a.cleanup!.discard();

      expect(await accountA.exists(), isTrue);
      secondA.requireCurrent();
      expect(await File(secondA.path).readAsBytes(), bytes);

      await secondA.cleanup!.discard();
      await a.cleanup!.discard();

      expect(await accountA.exists(), isFalse);
      b.requireCurrent();
      expect(await File(b.path).readAsBytes(), bytes);
      final ownerBytes = await File('${b.path}.owner').readAsBytes();
      expect(ownerBytes, isNot(equals(bytes)));
      expect(ownerBytes.length, lessThan(512));
      expect(
        accountB.listSync().map((entry) => entry.path),
        unorderedEquals([b.path, '${b.path}.owner']),
      );

      await b.cleanup!.discard();
      await a.cleanup!.discard();
      expect(directory.listSync(recursive: true), isEmpty);
    });

    test('cleanup cannot prune an empty replacement directory', () async {
      final bytes = await _exportFixture();
      final sink = FilePrivacyExportSink.forAccount(directory, 'A');
      final account = await privacyExportAccountDirectory(directory, 'A');
      final artifact = await sink.save(Stream.value(bytes));
      final ordinary = await File('${account.path}/user.zip').create();
      await artifact.cleanup!.discard();
      await ordinary.delete();

      await account.rename('${account.path}.retired');
      await account.create();
      await artifact.cleanup!.discard();

      expect(await account.exists(), isTrue);
      expect(account.listSync(), isEmpty);
      expect(await Directory('${account.path}.retired').exists(), isTrue);
    });

    test('scoped staging refuses a linked shared parent', () async {
      final bytes = await _exportFixture();
      final sink = FilePrivacyExportSink.forAccount(directory, 'A');
      final account = await privacyExportAccountDirectory(directory, 'A');
      final outside = await Directory('${directory.path}/outside').create();
      final parent = await Link(account.parent.path).create(outside.path);

      await expectLater(
        sink.save(Stream.value(bytes)),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        sink.reclaimInterruptedArtifacts(),
        throwsA(isA<FileSystemException>()),
      );

      expect(outside.listSync(recursive: true), isEmpty);
      expect(await parent.target(), outside.path);
    });

    test('valid ZIP with every entry CRC is accepted', () async {
      final bytes = await _exportFixture();

      final artifact = await FilePrivacyExportSink(
        directory,
      ).save(Stream<List<int>>.value(bytes));

      expect(await File(artifact.path).readAsBytes(), bytes);
      expect(privacyExportArtifacts(directory), hasLength(1));
      expect(privacyExportArtifacts(directory).single.path, artifact.path);
    });

    test('truncated ZIP is rejected without a deliverable file', () async {
      final bytes = await _exportFixture();
      await expectRejected(bytes.sublist(0, bytes.length - 8));
    });

    test('content byte corruption is rejected by entry CRC', () async {
      final bytes = List<int>.of(await _exportFixture());
      final name = ascii.encode('manual_marks.json');
      final nameAt = _indexOf(bytes, name);
      expect(nameAt, isNonNegative);
      bytes[nameAt + name.length] ^= 0x01;

      await expectRejected(bytes);
    });

    test('valid DEFLATE ZIP with every entry CRC is accepted', () async {
      final bytes = _deflateExportFixture();
      final central = _indexOf(bytes, const [0x50, 0x4b, 0x01, 0x02]);
      expect(central, isNonNegative);
      expect(_uint16(bytes, central + 10), 8);

      final artifact = await FilePrivacyExportSink(
        directory,
      ).save(Stream<List<int>>.value(bytes));

      expect(await File(artifact.path).readAsBytes(), bytes);
      expect(privacyExportArtifacts(directory), hasLength(1));
    });

    for (final signed in [true, false]) {
      test(
        'valid ZIP with ${signed ? 'signed' : 'unsigned'} data descriptor is accepted',
        () async {
          final bytes = _descriptorFixture(signed: signed);
          final central = _uint32(bytes, bytes.length - 6);
          // The first descriptor word is identical in both cases. The unsigned
          // fixture's real CRC happens to equal the optional signature word.
          expect(_uint32(bytes, central - (signed ? 16 : 12)), 0x08074b50);
          final artifact = await FilePrivacyExportSink(
            directory,
          ).save(Stream.fromIterable(bytes.map((byte) => [byte])));

          expect(await File(artifact.path).readAsBytes(), bytes);
          expect(privacyExportArtifacts(directory), hasLength(1));
        },
      );
    }

    test('descriptor length disagrees with the central directory', () async {
      final bytes = _descriptorFixture(signed: true);
      final central = _uint32(bytes, bytes.length - 6);
      bytes[central - 8]++;

      await expectRejected(bytes);
    });

    test('failed staging preserves a final path it did not create', () async {
      final bytes = await _exportFixture();
      late File existing;
      Stream<List<int>> interrupted() async* {
        yield bytes;
        final part = privacyExportPart(directory);
        existing = File(part.path.substring(0, part.path.length - 5));
        await existing.writeAsString('synthetic user file');
        throw StateError('synthetic stream failure');
      }

      await expectLater(
        FilePrivacyExportSink(directory).save(interrupted()),
        throwsStateError,
      );
      expect(await existing.readAsString(), 'synthetic user file');
      expect(privacyExportArtifacts(directory), hasLength(1));
    });

    for (final interrupted in [true, false]) {
      test(
        'staging stops after its directory is replaced (interrupted: $interrupted)',
        () async {
          final bytes = await _exportFixture();
          final staging = await Directory('${directory.path}/staging').create();
          final retired = '${directory.path}/retired';
          addTearDown(() async {
            if (!await Directory(retired).exists()) return;
            if (await staging.exists()) await staging.delete(recursive: true);
            await Directory(retired).rename(staging.path);
            await FilePrivacyExportSink(staging).reclaimInterruptedArtifacts();
          });
          late String partName;
          Stream<List<int>> response() async* {
            yield bytes.sublist(0, 20);
            partName = privacyExportPart(staging).uri.pathSegments.last;
            await staging.rename(retired);
            await staging.create();
            await File('${staging.path}/$partName').writeAsBytes(bytes);
            if (interrupted) throw StateError('synthetic stream interruption');
            yield bytes.sublist(20);
          }

          await expectLater(
            FilePrivacyExportSink(staging).save(response()),
            throwsA(
              isA<PrivacyExportStagingFailure>().having(
                (failure) => failure.cause,
                'cause',
                isA<PrivacyExportStagingFileFailure>(),
              ),
            ),
          );
          expect(
            await File('$retired/$partName').readAsBytes(),
            bytes.sublist(0, 20),
          );
          expect(await File('${staging.path}/$partName').readAsBytes(), bytes);
          expect(privacyExportArtifacts(staging), hasLength(1));
        },
      );
    }

    test(
      'completed staging refuses to replace an existing final path',
      () async {
        final bytes = await _exportFixture();
        late File existing;
        Stream<List<int>> staged() async* {
          yield bytes;
          final part = privacyExportPart(directory);
          existing = File(part.path.substring(0, part.path.length - 5));
          await existing.writeAsString('synthetic user file');
        }

        await expectLater(
          FilePrivacyExportSink(directory).save(staged()),
          throwsA(isA<FileSystemException>()),
        );
        expect(await existing.readAsString(), 'synthetic user file');
        expect(privacyExportArtifacts(directory), hasLength(1));
      },
    );

    test('DEFLATE content corruption is rejected', () async {
      final bytes = List<int>.of(_deflateExportFixture());
      final name = ascii.encode('manual_marks.json');
      final nameAt = _indexOf(bytes, name);
      expect(nameAt, isNonNegative);
      bytes[nameAt + name.length] ^= 0x20;

      await expectRejected(bytes);
    });

    test('DEFLATE entry without a final block is rejected', () async {
      final bytes = List<int>.of(_deflateExportFixture());
      final name = ascii.encode('manual_marks.json');
      final nameAt = _indexOf(bytes, name);
      expect(nameAt, isNonNegative);
      final dataAt = nameAt + name.length;
      expect(bytes[dataAt], 0x8b);

      // The raw DEFLATE payload is 8b 8e 05 00 for "[]". Clearing BFINAL
      // leaves the decoded bytes and CRC unchanged but omits stream completion.
      bytes[dataAt] &= 0xfe;

      await expectRejected(bytes);
    });

    test('central directory entry count mismatch is rejected', () async {
      final bytes = List<int>.of(await _exportFixture());
      final eocd = bytes.length - 22;
      expect(_uint32(bytes, eocd), 0x06054b50);
      _setUint16(bytes, eocd + 8, 1);
      _setUint16(bytes, eocd + 10, 1);

      await expectRejected(bytes);
    });
  });
}

Future<List<int>> _exportFixture() async {
  final fixtures = jsonDecode(
    await File('assets/contract_examples.json').readAsString(),
  );
  return base64Decode((fixtures as Map)['exportData'] as String);
}

List<int> _deflateExportFixture() => base64Decode(
  'UEsDBBQAAAAIANlJd137noTzHwAAAB0AAAANAAAAbWFuaWZlc3QuanNvbqtWys1PKc1JLVayUohWyk3MK03Mic9NLMouVoqtBQBQSwMEFAAAAAgA2Ul3XSm7TA0EAAAAAgAAABEAAABtYW51YWxfbWFya3MuanNvbouOBQBQSwECFAMUAAAACADZSXdd+56E8x8AAAAdAAAADQAAAAAAAAAAAAAAgAEAAAAAbWFuaWZlc3QuanNvblBLAQIUAxQAAAAIANlJd10pu0wNBAAAAAIAAAARAAAAAAAAAAAAAACAAUoAAABtYW51YWxfbWFya3MuanNvblBLBQYAAAAAAgACAHoAAAB9AAAAAAA=',
);

// Synthetic single-entry archives cross-checked with Python's zipfile.
List<int> _descriptorFixture({required bool signed}) => base64Decode(
  signed
      ? 'UEsDBBQACAAIAAAAAAAAAAAAAAAAAAAAAAANAAAAbWFuaWZlc3QuanNvbqtWKkktLlGyUiquzCvJSC3JTFaqBQBQSwcIEhrawhYAAAAUAAAAUEsBAhQAFAAIAAgAAAAAABIa2sIWAAAAFAAAAA0AAAAAAAAAAAAAAAAAAAAAAG1hbmlmZXN0Lmpzb25QSwUGAAAAAAEAAQA7AAAAUQAAAAAA'
      : 'UEsDBBQACAAIAAAAAAAAAAAAAAAAAAAAAAANAAAAbWFuaWZlc3QuanNvbqtWKkktLlGyUiquzCvJSC3JTFaq3SewQBwAUEsHCBoAAAAYAAAAUEsBAhQAFAAIAAgAAAAAAFBLBwgaAAAAGAAAAA0AAAAAAAAAAAAAAAAAAAAAAG1hbmlmZXN0Lmpzb25QSwUGAAAAAAEAAQA7AAAAUQAAAAAA',
);

int _indexOf(List<int> bytes, List<int> pattern) {
  for (var at = 0; at <= bytes.length - pattern.length; at++) {
    var match = true;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (bytes[at + offset] != pattern[offset]) {
        match = false;
        break;
      }
    }
    if (match) return at;
  }
  return -1;
}

int _uint32(List<int> bytes, int offset) =>
    bytes[offset] |
    bytes[offset + 1] << 8 |
    bytes[offset + 2] << 16 |
    bytes[offset + 3] << 24;

int _uint16(List<int> bytes, int offset) =>
    bytes[offset] | bytes[offset + 1] << 8;

void _setUint16(List<int> bytes, int offset, int value) {
  bytes[offset] = value & 0xff;
  bytes[offset + 1] = (value >> 8) & 0xff;
}
