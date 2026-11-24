import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:high_eq/features/privacy/export.dart';
import 'package:high_eq/features/privacy/export_delivery.dart';
import 'package:path_provider/path_provider.dart';

import '../../../test/privacy/export_fixture.dart';

void main() => runApp(const MaterialApp(home: _RunnerExport()));

class _RunnerExport extends StatefulWidget {
  const _RunnerExport();

  @override
  State<_RunnerExport> createState() => _RunnerExportState();
}

class _RunnerExportState extends State<_RunnerExport> {
  String _status = 'Ready';

  Future<void> _run() async {
    setState(() => _status = 'Waiting for the iOS share sheet');
    try {
      final evidence = await _shareAndCheckCancellation();
      if (mounted) setState(() => _status = evidence);
    } catch (error) {
      if (mounted) setState(() => _status = 'FAIL: $error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FilledButton(
              onPressed: _status == 'Ready' ? _run : null,
              child: const Text('Share synthetic ZIP'),
            ),
            Semantics(
              identifier: 't35-runner-export-status',
              label: _status,
              excludeSemantics: true,
              child: Text(_status),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<String> _shareAndCheckCancellation() async {
  const account = 't35-runner-synthetic';
  final zip = accountExportFixture(account);
  final sink = FilePrivacyExportSink.accountScopedLazy(
    getTemporaryDirectory,
    account,
    requireAccountManifest: true,
  );
  final artifact = await sink.save(Stream.value(zip));
  final file = File(artifact.path);
  final owner = File('${artifact.path}.owner');
  final part = File('${artifact.path}.part');
  final events = <String>[];
  final presentation = Stopwatch();
  var heldAtPresentation = false;
  late final bool heldAtReceipt;

  bool stillStaged() {
    try {
      artifact.requireCurrent();
      return listEquals(file.readAsBytesSync(), zip) &&
          owner.lengthSync() > 0 &&
          !part.existsSync();
    } on FileSystemException {
      return false;
    }
  }

  try {
    await const PlatformPrivacyExportDelivery().deliverArtifact(
      artifact,
      requireAllowed: () {}, // The fixture has no live account session.
      onDispatched: () => events.add('dispatched'),
      onPresented: () {
        events.add('presented');
        heldAtPresentation = stillStaged();
        presentation.start();
      },
    );
    events.add('completed');
  } on PrivacyExportDeliveryFailure catch (error) {
    final reply = error.cause;
    if (reply is! PlatformException || reply.code != error.deliveryCode) {
      rethrow;
    }
    events.add(reply.code);
  } finally {
    presentation.stop();
    heldAtReceipt = stillStaged();
    await artifact.cleanup!.discard();
  }

  if (!listEquals(events, ['dispatched', 'presented', 'cancelled'])) {
    throw StateError(
      'Expected dispatch, presentation and cancellation: $events',
    );
  }
  if (presentation.elapsed < const Duration(seconds: 2) ||
      !heldAtPresentation ||
      !heldAtReceipt) {
    throw StateError(
      'Expected ZIP and owner to stay staged until cancellation',
    );
  }
  if ([file, owner, part].any(
    (entry) =>
        FileSystemEntity.typeSync(entry.path, followLinks: false) !=
        FileSystemEntityType.notFound,
  )) {
    throw StateError('ZIP, owner or partial file remained after cancellation');
  }
  return 'dispatched=1 | presented=1 | held=ZIP+owner | '
      'cancelled=1 | cleanup=ZIP+owner+part absent';
}
