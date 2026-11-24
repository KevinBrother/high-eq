import 'dart:io';

import 'export_cleanup_status.dart';
import 'export_namespace.dart';
import 'export_staging_file.dart';
import 'export_zip.dart';

export 'export_cleanup_status.dart';
export 'export_zip.dart' show PrivacyExportIntegrityFailure;

final _privacyExportArtifactName = RegExp(
  r'^high-eq-export-[0-9]+(?:-[0-9]+)?\.zip(?:\.part|\.owner)?$',
);

/// Removes only module-generated artifacts from one private staging directory.
/// It never scans recursively, follows links, or deletes user-selected files.
Future<PrivacyExportCleanupStatus> cleanupPrivacyExportStorage(
  Directory directory,
) async {
  var removed = 0;
  var failed = 0;
  try {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) {
      return const PrivacyExportCleanupStatus(ok: true, removed: 0, failed: 0);
    }
    if (type != FileSystemEntityType.directory) {
      return const PrivacyExportCleanupStatus(ok: false, removed: 0, failed: 1);
    }
    await for (final entity in directory.list(followLinks: false)) {
      final name = _privacyExportEntityName(entity.path);
      if (!_privacyExportArtifactName.hasMatch(name)) continue;
      if (entity is! File) {
        // A same-named link or directory is not provably owned by this
        // module. Leave it untouched without turning an unrelated entry into a
        // permanent export failure.
        continue;
      }
      try {
        if (await _deleteOwnedPrivacyExportFile(entity.path)) removed++;
      } catch (_) {
        failed++;
      }
    }
  } catch (_) {
    failed++;
  }
  return PrivacyExportCleanupStatus(
    ok: failed == 0,
    removed: removed,
    failed: failed,
  );
}

class PrivacyExportArtifact {
  const PrivacyExportArtifact({
    required this.path,
    required this.bytes,
    this.cleanup,
  });

  final String path;
  final int bytes;
  final PrivacyExportCleanup? cleanup;

  Future<void> holdForDelivery(Future<void> Function() share) {
    final staging = cleanup?._staging;
    return staging == null ? share() : staging.holdForDelivery(share);
  }

  void requireCurrent() {
    try {
      cleanup?._staging?.requireCurrent();
    } on FileSystemException catch (error) {
      throw PrivacyExportStagingFileFailure(error);
    }
  }
}

class PrivacyExportCleanup {
  const PrivacyExportCleanup(this.path) : _staging = null;

  const PrivacyExportCleanup._(this.path, this._staging);

  final String path;
  final ExportStagingFile? _staging;

  Future<void> discard([
    Future<void> Function(String path)? deleteOverride,
  ]) async {
    final staging = _staging;
    final platformUse = staging?.platformUse;
    if (platformUse != null) await platformUse;
    if (staging != null && staging.isClosed) {
      staging.discard();
      return;
    }
    try {
      if (deleteOverride != null) {
        staging?.checkCleanup();
        await deleteOverride(path);
      }
      if (staging != null) {
        staging.discard();
        FilePrivacyExportSink._interrupted.remove(staging.partPath);
      } else if (deleteOverride == null) {
        await deletePrivacyExport(path);
      }
    } finally {
      // Once cleanup is attempted, a later page may reclaim the path. A
      // failed attempt is intentionally not protected: the privacy boundary
      // requires the next page to retry deletion before exporting.
      if (staging != null) {
        FilePrivacyExportSink._activeArtifacts.remove(staging.path);
      }
    }
  }
}

/// Reclaims interrupted module-owned staging files without scanning recursively.
/// Implementations must verify the staging directory and file type without
/// following links before deleting anything.
abstract interface class PrivacyExportStagingRecovery {
  Future<void> reclaimInterruptedArtifacts();
}

/// A local filesystem failure while creating, writing, or finalizing the staged
/// archive. It remains a [FileSystemException] for direct sink callers, while
/// the store can map it to actionable device-storage guidance.
class PrivacyExportStagingFileFailure extends FileSystemException {
  PrivacyExportStagingFileFailure(FileSystemException cause)
    : super(cause.message, cause.path, cause.osError);
}

/// Reports a staging failure whose module-owned `.part` file could not be
/// removed. The cleanup capability is retained for a later retry.
class PrivacyExportStagingFailure implements Exception {
  const PrivacyExportStagingFailure(
    this.cleanup, {
    required this.cause,
    required this.cleanupError,
    this.stackTrace = StackTrace.empty,
  });

  final PrivacyExportCleanup cleanup;
  final Object cause;
  final Object cleanupError;
  final StackTrace stackTrace;

  @override
  String toString() => 'PrivacyExportStagingFailure(${cleanup.path}): $cause';
}

/// Writes the response to a same-directory `.part` file, validates the ZIP
/// structure while consuming it, and publishes only after a complete
/// stream and successful flush. The stream is never materialized as one blob.
abstract interface class PrivacyExportSink {
  Future<PrivacyExportArtifact> save(Stream<List<int>> chunks);
}

class FilePrivacyExportSink
    implements PrivacyExportSink, PrivacyExportStagingRecovery {
  FilePrivacyExportSink(Directory directory, {bool pruneEmptyDirectory = false})
    : this.lazy(
        () async => directory,
        pruneEmptyDirectory: pruneEmptyDirectory,
      );

  FilePrivacyExportSink.lazy(
    this._directory, {
    bool pruneEmptyDirectory = false,
  }) : _pruneEmptyDirectory = pruneEmptyDirectory,
       _accountScoped = false,
       requireAccountManifest = false;

  FilePrivacyExportSink.forAccount(Directory root, String account)
    : this.accountScopedLazy(() async => root, account);

  FilePrivacyExportSink.accountScopedLazy(
    Future<Directory> Function() root,
    String account, {
    this.requireAccountManifest = false,
  }) : _directory = (() async =>
           privacyExportAccountDirectory(await root(), account)),
       _pruneEmptyDirectory = true,
       _accountScoped = true;

  final Future<Directory> Function() _directory;
  final bool _pruneEmptyDirectory;
  final bool _accountScoped;
  final bool requireAccountManifest;
  static int _sequence = 0;
  static final _activeParts = <String>{};
  static final _activeArtifacts = <String>{};
  static final _interrupted = <String, ExportStagingFile>{};

  ExportStagingDirectory? _openDirectory(
    Directory directory, {
    required bool create,
  }) {
    if (!_accountScoped) {
      if (create) directory.parent.createSync(recursive: true);
      return ExportStagingDirectory.open(
        directory,
        create: create,
        pruneCreated: _pruneEmptyDirectory,
      );
    }
    // A scoped sink can open the shared parent but never enumerate it.
    final root = ExportStagingDirectory.open(
      directory.parent,
      create: create,
      pruneCreated: true,
    );
    if (root == null) return null;
    try {
      final namespace = ExportStagingDirectory.open(
        directory,
        create: create,
        pruneCreated: true,
        parent: root,
      );
      if (namespace == null) root.close();
      return namespace;
    } catch (_) {
      root.prune();
      rethrow;
    }
  }

  @override
  Future<void> reclaimInterruptedArtifacts() async {
    final directory = (await _directory()).absolute;
    for (final staging in _interrupted.values.toList()) {
      if (staging.directory != directory.path) continue;
      staging.discard();
      _interrupted.remove(staging.partPath);
    }
    final opened = _openDirectory(directory, create: false);
    if (opened == null) return;
    try {
      for (final entity in directory.listSync(followLinks: false)) {
        final path = entity.path;
        final name = _privacyExportEntityName(path);
        if (entity is! File ||
            !_privacyExportArtifactName.hasMatch(name) ||
            _isActivePrivacyExportName(directory, name)) {
          continue;
        }
        _discardRecoveredPrivacyExportFile(opened, name);
      }
    } finally {
      opened.close();
    }
  }

  @override
  Future<PrivacyExportArtifact> save(Stream<List<int>> chunks) async {
    try {
      return await _save(chunks);
    } on PrivacyExportStagingFailure {
      rethrow;
    } on FileSystemException catch (error, stackTrace) {
      Error.throwWithStackTrace(
        PrivacyExportStagingFileFailure(error),
        stackTrace,
      );
    }
  }

  Future<PrivacyExportArtifact> _save(Stream<List<int>> chunks) async {
    final directory = (await _directory()).absolute;
    final opened = _openDirectory(directory, create: true)!;
    final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
    final ExportStagingFile staging;
    try {
      staging = ExportStagingFile.create(
        opened,
        'high-eq-export-$stamp-${_sequence++}.zip',
      );
    } catch (_) {
      opened.prune();
      rethrow;
    }
    _activeParts.add(staging.partPath);
    try {
      staging.requireCurrent();
      final validator = PrivacyExportZipStream();
      await for (final chunk in chunks) {
        if (chunk.isEmpty) continue;
        staging.write(chunk);
        validator.add(chunk);
      }
      staging.requireCurrent();
      final bytes = validator.finish();
      staging.flush();
      await validateStagedPrivacyExport(
        staging,
        bytes,
        requireAccountManifest: requireAccountManifest,
      );
      if (staging.read(bytes, 1).isNotEmpty) {
        throw const PrivacyExportIntegrityFailure('导出文件长度异常');
      }
      staging.publish();
      _activeArtifacts.add(staging.path);
      return PrivacyExportArtifact(
        path: staging.path,
        bytes: bytes,
        cleanup: PrivacyExportCleanup._(staging.path, staging),
      );
    } catch (error, stackTrace) {
      try {
        staging.discard();
      } catch (cleanupError) {
        _interrupted[staging.partPath] = staging;
        final cause = cleanupError is ExportStagingOwnershipLost
            ? cleanupError
            : error;
        throw PrivacyExportStagingFailure(
          PrivacyExportCleanup._(staging.partPath, staging),
          cause: cause is FileSystemException
              ? PrivacyExportStagingFileFailure(cause)
              : cause,
          cleanupError: cleanupError,
          stackTrace: stackTrace,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _activeParts.remove(staging.partPath);
    }
  }
}

Future<void> deletePrivacyExport(String path) async {
  if (path.startsWith('memory://')) return;
  final name = _privacyExportEntityName(path);
  if (!_privacyExportArtifactName.hasMatch(name)) {
    throw FileSystemException('导出暂存文件名异常', path);
  }
  if (!await _deleteOwnedPrivacyExportFile(path)) {
    throw FileSystemException('导出暂存文件归属无法确认', path);
  }
}

String _privacyExportEntityName(String path) =>
    path.replaceAll('\\', '/').split('/').last;

/// Deletes one module-named file only when its descriptor-relative ownership
/// record still names the same device/inode.
Future<bool> _deleteOwnedPrivacyExportFile(String path) async {
  final name = _privacyExportEntityName(path);
  if (!_privacyExportArtifactName.hasMatch(name)) {
    throw FileSystemException('导出暂存文件名异常', path);
  }
  final directory = ExportStagingDirectory.open(File(path).parent);
  if (directory == null) return false;
  try {
    return _discardRecoveredPrivacyExportFile(directory, name);
  } finally {
    directory.close();
  }
}

bool _discardRecoveredPrivacyExportFile(
  ExportStagingDirectory directory,
  String name,
) {
  directory.requireCurrent();
  final artifact = FileSystemEntity.typeSync(
    '${directory.path}/$name',
    followLinks: false,
  );
  if (artifact != FileSystemEntityType.file) return false;
  final ownerArtifact = FileSystemEntity.typeSync(
    '${directory.path}/${ExportStagingFile.ownerName(name)}',
    followLinks: false,
  );
  if (ownerArtifact != FileSystemEntityType.file) return false;
  return ExportStagingFile.discardRecovered(directory, name);
}

bool _isActivePrivacyExportName(Directory directory, String name) {
  final logical = ExportStagingFile.logicalName(name);
  bool isLiveFile(String path, bool registered) =>
      registered &&
      FileSystemEntity.typeSync(path, followLinks: false) ==
          FileSystemEntityType.file;
  return isLiveFile(
        '${directory.path}/$logical',
        FilePrivacyExportSink._activeArtifacts.contains(
          '${directory.path}/$logical',
        ),
      ) ||
      isLiveFile(
        '${directory.path}/$logical.part',
        FilePrivacyExportSink._activeParts.contains(
          '${directory.path}/$logical.part',
        ),
      );
}
