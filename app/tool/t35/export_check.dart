import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:high_eq/features/privacy/export.dart';
import 'package:high_eq/features/privacy/export_namespace.dart';
import '../../test/privacy/export_fixture.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  final workspace = Directory(args.single);
  final root = workspace.createTempSync('t35-dart-export.');
  try {
    await check(root);
  } finally {
    root.deleteSync(recursive: true);
  }
  stdout.writeln('Account ZIP, delivery lifetime and cold recovery passed');
}

Future<void> check(Directory root) async {
  final a = FilePrivacyExportSink.accountScopedLazy(
    () async => root,
    'A',
    requireAccountManifest: true,
  );
  final b = FilePrivacyExportSink.accountScopedLazy(
    () async => root,
    'B',
    requireAccountManifest: true,
  );
  final bytes = accountExportFixture('A');
  final damaged = accountExportFixture('A')..[43] ^= 0x40;
  for (final bad in [
    bytes.sublist(0, bytes.length - 10),
    accountExportFixture('A', omit: 'training'),
    accountExportFixture('A', wrongManifest: true),
    damaged,
  ]) {
    try {
      await a.save(Stream.value(bad));
      throw StateError('invalid archive accepted');
    } on PrivacyExportIntegrityFailure {
      require(
        root.listSync(recursive: true).isEmpty,
        'invalid archive left a residue',
      );
    }
  }
  final pending = await a.save(
    Stream.fromIterable([bytes.sublist(0, 80), bytes.sublist(80)]),
  );
  final source = File(pending.path);
  require(
    base64Encode(source.readAsBytesSync()) == base64Encode(bytes),
    'A ZIP changed',
  );
  final platformReceipt = Completer<void>();
  final activity = pending.holdForDelivery(() => platformReceipt.future);
  final discard = pending.cleanup!.discard();
  await b.reclaimInterruptedArtifacts();
  require(source.existsSync(), 'source deleted while the system held it');
  final second = await b.save(Stream.value(accountExportFixture('B')));
  require(
    File(second.path).parent.path != source.parent.path,
    'accounts share a namespace',
  );
  await second.cleanup!.discard();
  require(source.existsSync(), 'B cleanup deleted the held source');
  platformReceipt.complete();
  await activity;
  await discard;
  require(
    root.listSync(recursive: true).isEmpty,
    'delivery did not remove its staging tree',
  );

  final scratch = root.createTempSync('scratch.');
  final prior = await FilePrivacyExportSink(scratch).save(Stream.value(bytes));
  final accountA = await privacyExportAccountDirectory(root, 'A');
  accountA.createSync(recursive: true);
  final part = File('${accountA.path}/high-eq-export-1-1.zip.part');
  final owner = File('${accountA.path}/high-eq-export-1-1.zip.owner');
  File(prior.path).renameSync(part.path);
  File('${prior.path}.owner').renameSync(owner.path);
  final keep = File('${accountA.path}/keep.txt')..writeAsStringSync('keep');
  await b.reclaimInterruptedArtifacts();
  require(part.existsSync() && owner.existsSync(), 'B cleaned A cold residue');
  await a.reclaimInterruptedArtifacts();
  require(!part.existsSync() && !owner.existsSync(), 'A left cold residue');
  require(
    keep.readAsStringSync() == 'keep',
    'recovery modified unrelated data',
  );
}
