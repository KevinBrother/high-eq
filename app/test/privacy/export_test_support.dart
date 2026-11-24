import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/privacy/export.dart';

Future<void> reportPrivacyExportPresented(
  TestDefaultBinaryMessenger messenger,
  int requestId,
) async {
  const codec = StandardMethodCodec();
  final reply = await messenger.handlePlatformMessage(
    'cn.higheq/mobile-commerce',
    codec.encodeMethodCall(MethodCall('shareExportPresented', requestId)),
    null,
  );
  expect(reply, isNotNull);
  expect(codec.decodeEnvelope(reply!), isNull);
}

/// Ownership metadata is a separate inode record and is excluded here.
/// Tests that count artifacts still assert their exact visible count and check
/// full-directory emptiness after cleanup separately.
bool isPrivacyExportOwnerMetadata(FileSystemEntity entity) =>
    entity.path.endsWith('.owner');

List<FileSystemEntity> privacyExportArtifacts(Directory directory) => directory
    .listSync()
    .where((entity) => !isPrivacyExportOwnerMetadata(entity))
    .toList();

File privacyExportPart(Directory directory) => directory
    .listSync()
    .whereType<File>()
    .singleWhere((entity) => entity.path.endsWith('.part'));

String privacyExportOwnerPath(File artifact) {
  final base = artifact.path.endsWith('.part')
      ? artifact.path.substring(0, artifact.path.length - 5)
      : artifact.path;
  return '$base.owner';
}

/// Replaces [artifact] with a real sink-written ZIP and matching owner record.
/// The desired fixture bytes are written through the original ZIP path first
/// so its device/inode remains the one recorded by the sidecar.
Future<void> createPrivacyExportOwnerRecord(File artifact) async {
  final bytes = await artifact.readAsBytes();
  await artifact.parent.create(recursive: true);
  final fixture = await Directory(
    '${artifact.parent.path}/.t35-owner-record-'
    '${DateTime.now().microsecondsSinceEpoch}',
  ).create();
  try {
    final generated = await FilePrivacyExportSink(
      fixture,
    ).save(Stream<List<int>>.value(await exportFixture()));
    await File(generated.path).writeAsBytes(bytes);
    await artifact.delete();
    await File(generated.path).rename(artifact.path);
    await File(
      '${generated.path}.owner',
    ).rename(privacyExportOwnerPath(artifact));
  } finally {
    if (await fixture.exists()) await fixture.delete(recursive: true);
  }
}

Future<void> createPrivacyExportHardLink(
  File artifact,
  String targetPath,
) async {
  final result = await Process.run('ln', [artifact.path, targetPath]);
  expect(
    result.exitCode,
    0,
    reason: 'synthetic export hard link failed: ${result.stderr}',
  );
}

Future<List<int>> exportFixture() async {
  final fixtures = jsonDecode(
    await File('assets/contract_examples.json').readAsString(),
  );
  return base64Decode((fixtures as Map)['exportData'] as String);
}
