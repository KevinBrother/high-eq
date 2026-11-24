import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

/// Pins a directory and its parent. Only an exclusive mkdir grants permission
/// to remove that directory. An existing namespace can still stage owned ZIPs.
final class ExportStagingDirectory {
  ExportStagingDirectory._(
    this.path,
    this._name,
    this._parent,
    this._parentFd,
    this._fd,
    this._id,
    this._created,
  ) {
    _finalizer.attach(this, (
      fd: _fd,
      parentFd: _parent == null ? _parentFd : null,
    ), detach: this);
  }

  static ExportStagingDirectory? open(
    Directory directory, {
    bool create = false,
    bool pruneCreated = false,
    ExportStagingDirectory? parent,
  }) {
    final path = directory.absolute.path;
    final name = path.replaceFirst(RegExp(r'/+$'), '').split('/').last;
    parent?.requireCurrent();
    int? openedParent;
    int? fd;
    try {
      final parentFd =
          parent?._fd ??
          (openedParent = _fs.open(
            _fs.cwd,
            directory.parent.absolute.path,
            _fs.directory,
          ));
      final created = create && _fs.makeDirectory(parentFd, name);
      final opened = _fs.open(parentFd, name, _fs.directory);
      fd = opened;
      final id = _fs.identity(opened);
      if (_fs.identityAt(_fs.cwd, path) != id ||
          _fs.identityAt(parentFd, name) != id) {
        throw ExportStagingOwnershipLost(path);
      }
      final result = ExportStagingDirectory._(
        path,
        name,
        parent,
        parentFd,
        opened,
        id,
        created && pruneCreated,
      );
      fd = null;
      openedParent = null;
      return result;
    } on FileSystemException catch (error) {
      if (!create && error.osError?.errorCode == 2) return null;
      rethrow;
    } finally {
      if (fd != null) _fs.close(fd);
      if (openedParent != null) _fs.close(openedParent);
    }
  }

  static final _fs = _PosixFiles();
  static final _finalizer = Finalizer<({int fd, int? parentFd})>((handles) {
    _fs.close(handles.fd);
    if (handles.parentFd case final parentFd?) _fs.close(parentFd);
  });

  final String path;
  final String _name;
  final ExportStagingDirectory? _parent;
  final int _parentFd;
  final int _fd;
  final _FileIdentity _id;
  bool _created;
  bool _closed = false;

  void requireCurrent() {
    _parent?.requireCurrent();
    if (_closed ||
        _fs.identityAt(_parentFd, _name) != _id ||
        _fs.identityAt(_fs.cwd, path) != _id) {
      throw ExportStagingOwnershipLost(path);
    }
  }

  void prune() {
    if (!_closed && !_prune()) close();
  }

  bool _prune() {
    if (_created) {
      try {
        requireCurrent();
        // unlinkat with AT_REMOVEDIR is non-recursive and requires an empty
        // directory at the time of removal. Live ZIPs and ownership records
        // keep the namespace non-empty.
        _fs.remove(_parentFd, _name, directory: true);
        _created = false;
      } on ExportStagingOwnershipLost {
        _created = false;
      } on FileSystemException {
        // Keep a non-empty directory. A later discard may retry while this
        // capability still pins the original identity.
      }
    }
    final parentPending = _parent?._prune() ?? false;
    return _created || parentPending;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _finalizer.detach(this);
    _fs.close(_fd);
    if (_parent == null) {
      _fs.close(_parentFd);
    } else {
      _parent.close();
    }
  }
}

/// The open directory and file pin their filesystem identities for the whole
/// attempt, including a later cleanup retry. File IO never reopens the ZIP.
final class ExportStagingFile {
  ExportStagingFile._(this._directory, this.name, this._fd)
    : _fileId = _fs.identity(_fd) {
    _finalizer.attach(this, _fd, detach: this);
  }

  static ExportStagingFile create(
    ExportStagingDirectory directory,
    String name,
  ) {
    directory.requireCurrent();
    final directoryFd = directory._fd;
    var fileFd = -1;
    var ownerFd = -1;
    var ownerCreated = false;
    try {
      fileFd = _fs.open(directoryFd, '$name.part', _fs.createExclusive);
      final identity = _fs.identity(fileFd);
      // Establish ownership before any ZIP bytes are written. The record is an
      // independent, tiny sidecar: a crash after removing the ZIP aliases can
      // leave metadata, but never a second readable copy of the export.
      ownerFd = _fs.open(directoryFd, ownerName(name), _fs.createExclusive);
      ownerCreated = true;
      _fs.writeAll(ownerFd, _encodeOwnerRecord(identity));
      _fs.flush(ownerFd);
      _fs.close(ownerFd);
      ownerFd = -1;
      return ExportStagingFile._(directory, name, fileFd);
    } catch (_) {
      if (ownerFd != -1) _fs.close(ownerFd);
      if (ownerCreated) {
        try {
          _fs.remove(directoryFd, ownerName(name));
        } catch (_) {}
      }
      if (fileFd != -1) {
        try {
          _fs.remove(directoryFd, '$name.part');
        } catch (_) {}
      }
      if (fileFd != -1) _fs.close(fileFd);
      rethrow;
    }
  }

  static final _fs = ExportStagingDirectory._fs;
  static final _finalizer = Finalizer<int>((fd) {
    _fs.close(fd);
  });

  final ExportStagingDirectory _directory;
  final String name;
  final int _fd;
  final _FileIdentity _fileId;
  var _hasPart = true;
  var _hasFinal = false;
  var _hasOwner = true;
  var _closed = false;
  Future<void>? _platformUse;

  String get _part => '$name.part';
  String get _owner => ownerName(name);
  String get directory => _directory.path;
  String get partPath => '$directory/$_part';
  String get path => '$directory/$name';
  bool get isClosed => _closed;
  Future<void>? get platformUse => _platformUse;

  /// Native save/share may open the path after the bridge call starts.
  /// Keep the source and its namespace until the platform replies.
  Future<void> holdForDelivery(Future<void> Function() share) async {
    final released = Completer<void>();
    _platformUse = released.future;
    try {
      await share();
    } finally {
      _platformUse = null;
      released.complete();
    }
  }

  static String logicalName(String artifactName) =>
      artifactName.endsWith('.owner')
      ? artifactName.substring(0, artifactName.length - 6)
      : artifactName.endsWith('.part')
      ? artifactName.substring(0, artifactName.length - 5)
      : artifactName;

  static String ownerName(String artifactName) {
    // The record belongs to the logical ZIP, not to whichever alias (final
    // name or `.part`) is being reclaimed.
    return '${logicalName(artifactName)}.owner';
  }

  void _requireDirectory() => _directory.requireCurrent();

  bool _ownsEntry(String entry, {bool allowMissing = false}) {
    final id = _fs.identityAt(_directory._fd, entry);
    if (id == null && allowMissing) return false;
    if (id != _fileId) throw ExportStagingOwnershipLost('$directory/$entry');
    return true;
  }

  void requireCurrent() {
    if (_closed) throw ExportStagingOwnershipLost(path);
    _requireDirectory();
    if (_hasPart) {
      _ownsEntry(_part);
    } else if (_hasFinal) {
      _ownsEntry(name);
    }
    if (_hasOwner &&
        _ownerRecordStateAt(_directory, _owner, _fileId) !=
            _OwnerRecordState.matched) {
      throw ExportStagingOwnershipLost(_ownerPath);
    }
  }

  void write(List<int> bytes) {
    requireCurrent();
    _fs.writeAll(_fd, bytes);
  }

  void flush() {
    requireCurrent();
    _fs.flush(_fd);
  }

  Uint8List read(int offset, int length) {
    requireCurrent();
    return _fs.read(_fd, offset, length);
  }

  void publish() {
    requireCurrent();
    // linkat is exclusive at the destination. Both names are relative to the
    // open private directory, even if its public pathname changes here.
    _fs.link(_directory._fd, _part, name);
    _hasFinal = true;
    _requireDirectory();
    _ownsEntry(name);
    _ownsEntry(_part);
    _fs.remove(_directory._fd, _part);
    _hasPart = false;
    requireCurrent();
  }

  void checkCleanup() {
    if (_closed) return;
    _requireDirectory();
    var hasData = false;
    if (_hasPart) {
      hasData = _checkAlias(_part) || hasData;
    }
    if (_hasFinal) {
      hasData = _checkAlias(name) || hasData;
    }
    if (_hasOwner) {
      final state = _ownerRecordStateAt(_directory, _owner, _fileId);
      if (state == _OwnerRecordState.invalid ||
          (state == _OwnerRecordState.missing && hasData)) {
        throw ExportStagingOwnershipLost(_ownerPath);
      }
    }
  }

  bool discard() {
    if (_closed) {
      _directory.prune();
      return false;
    }
    checkCleanup();
    var removed = false;
    if (_hasPart && _ownsEntry(_part, allowMissing: true)) {
      removed = _fs.remove(_directory._fd, _part);
    }
    _hasPart = false;
    if (_hasFinal && _ownsEntry(name, allowMissing: true)) {
      _requireDirectory();
      removed = _fs.remove(_directory._fd, name) || removed;
    }
    _hasFinal = false;
    if (_hasOwner) {
      final state = _ownerRecordStateAt(_directory, _owner, _fileId);
      if (state == _OwnerRecordState.invalid) {
        throw ExportStagingOwnershipLost(_ownerPath);
      }
      if (state == _OwnerRecordState.matched) {
        _requireDirectory();
        removed = _fs.remove(_directory._fd, _owner) || removed;
      }
    }
    _hasOwner = false;
    _closed = true;
    _finalizer.detach(this);
    _fs.close(_fd);
    _directory.prune();
    return removed;
  }

  /// Recovers one logical artifact after a process restart. The owner sidecar
  /// records the device/inode of the module's ZIP. Any discovered aliases must
  /// match that identity; they are removed while the record remains available
  /// as proof. The owner is removed last so a failed attempt can be retried
  /// from any surviving alias. An owner-only residue is removable only after
  /// its record validates and both ZIP aliases are absent.
  static bool discardRecovered(
    ExportStagingDirectory directory,
    String artifactName,
  ) {
    directory.requireCurrent();
    final base = logicalName(artifactName);
    final owner = ownerName(base);
    final aliases = <String>[base, '$base.part'];
    final directoryFd = directory._fd;
    var ownerFd = -1;
    try {
      final ownerPathIdentity = _fs.identityAt(directoryFd, owner);
      if (ownerPathIdentity == null) return false;
      try {
        ownerFd = _fs.open(directoryFd, owner, 0);
      } on FileSystemException catch (error) {
        if (_fs.isMissingOrLink(error)) return false;
        rethrow;
      }
      if (_fs.identity(ownerFd) != ownerPathIdentity ||
          _fs.identityAt(directoryFd, owner) != ownerPathIdentity) {
        return false;
      }
      final expected = _decodeOwnerRecord(
        _fs.read(ownerFd, 0, _maxOwnerRecordLength + 1),
      );
      if (expected == null) return false;

      final aliasIdentities = <String, _FileIdentity>{};
      for (final alias in aliases) {
        final identity = _fs.identityAt(directoryFd, alias);
        if (identity == null) continue;
        if (identity != expected) return false;
        aliasIdentities[alias] = identity;
      }
      if (artifactName != owner && !aliasIdentities.containsKey(artifactName)) {
        return false;
      }

      directory.requireCurrent();
      for (final alias in aliasIdentities.keys) {
        if (_fs.identityAt(directoryFd, alias) != expected) return false;
        _fs.remove(directoryFd, alias);
      }
      // Recheck both the path and the record contents at the final mutation
      // point. A replaced or edited owner is unrelated and must be preserved.
      if (_fs.identityAt(directoryFd, owner) != ownerPathIdentity ||
          _decodeOwnerRecord(_fs.read(ownerFd, 0, _maxOwnerRecordLength + 1)) !=
              expected) {
        return false;
      }
      directory.requireCurrent();
      _fs.remove(directoryFd, owner);
      return true;
    } finally {
      if (ownerFd != -1) _fs.close(ownerFd);
    }
  }

  static const _ownerRecordFormat = 'high-eq-privacy-export-owner-v1';
  static const _maxOwnerRecordLength = 512;

  String get _ownerPath => '$directory/$_owner';

  bool _checkAlias(String entry) {
    final identity = _fs.identityAt(_directory._fd, entry);
    if (identity == null) return false;
    if (identity != _fileId) {
      throw ExportStagingOwnershipLost('$directory/$entry');
    }
    return true;
  }

  static List<int> _encodeOwnerRecord(_FileIdentity identity) => utf8.encode(
    jsonEncode({
      'format': _ownerRecordFormat,
      'device': identity.device,
      'inode': identity.inode,
    }),
  );

  static _FileIdentity? _decodeOwnerRecord(Uint8List bytes) {
    if (bytes.length > _maxOwnerRecordLength) return null;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map ||
          value['format'] != _ownerRecordFormat ||
          value['device'] is! int ||
          value['inode'] is! int) {
        return null;
      }
      final device = value['device'] as int;
      final inode = value['inode'] as int;
      if (device < 0 || inode < 0) return null;
      return (device: device, inode: inode);
    } on FormatException {
      return null;
    }
  }

  static _OwnerRecordState _ownerRecordStateAt(
    ExportStagingDirectory directory,
    String owner,
    _FileIdentity expected,
  ) {
    final directoryFd = directory._fd;
    final ownerPathIdentity = _fs.identityAt(directoryFd, owner);
    if (ownerPathIdentity == null) return _OwnerRecordState.missing;
    var ownerFd = -1;
    try {
      try {
        ownerFd = _fs.open(directoryFd, owner, 0);
      } on FileSystemException catch (error) {
        if (_fs.isMissingOrLink(error)) return _OwnerRecordState.invalid;
        rethrow;
      }
      if (_fs.identity(ownerFd) != ownerPathIdentity) {
        return _OwnerRecordState.invalid;
      }
      final record = _decodeOwnerRecord(
        _fs.read(ownerFd, 0, _maxOwnerRecordLength + 1),
      );
      if (record != expected ||
          _fs.identityAt(directoryFd, owner) != ownerPathIdentity) {
        return _OwnerRecordState.invalid;
      }
      return _OwnerRecordState.matched;
    } on FileSystemException catch (error) {
      if (_fs.isMissingOrLink(error)) return _OwnerRecordState.invalid;
      rethrow;
    } finally {
      if (ownerFd != -1) _fs.close(ownerFd);
    }
  }
}

enum _OwnerRecordState { missing, matched, invalid }

final class ExportStagingOwnershipLost extends FileSystemException {
  ExportStagingOwnershipLost(String path) : super('导出暂存归属已变化', path);
}

typedef _FileIdentity = ({int device, int inode});

/// POSIX descriptor-relative filesystem operations. The stat buffer layout is
/// selected by the C library ABI, independently of Dart object layout.
final class _PosixFiles {
  _PosixFiles() {
    if (!_darwin && !Platform.isAndroid && !Platform.isLinux) {
      throw const FileSystemException('此平台无法安全暂存导出文件');
    }
    if (!_darwin && !_arm && !_arm64 && !_x64) {
      throw const FileSystemException('此平台无法安全暂存导出文件');
    }
  }

  static final _lib = Platform.isAndroid
      ? DynamicLibrary.open('libc.so')
      : DynamicLibrary.process();
  static final _abi = Abi.current();
  static final _darwin = Platform.isMacOS || Platform.isIOS;
  static final _arm = _abi == Abi.androidArm || _abi == Abi.linuxArm;
  static final _arm64 = _abi == Abi.androidArm64 || _abi == Abi.linuxArm64;
  static final _x64 = _abi == Abi.androidX64 || _abi == Abi.linuxX64;

  int get cwd => _darwin ? -2 : -100;
  int get _noFollow => _darwin ? 0x100 : (_arm || _arm64 ? 0x8000 : 0x20000);
  int get _closeOnExec => _darwin ? 0x1000000 : 0x80000;
  int get directory => _darwin ? 0x100000 : (_arm || _arm64 ? 0x4000 : 0x10000);
  int get createExclusive => (_darwin ? 0x200 | 0x800 : 0x40 | 0x80) | 2;

  bool isMissingOrLink(FileSystemException error) {
    final code = error.osError?.errorCode;
    return code == 2 || code == 21 || code == 40 || code == 62;
  }

  late final _openAt = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Uint8>, Int, VarArgs<(Uint32,)>),
        int Function(int, Pointer<Uint8>, int, int)
      >('openat');
  late final close = _lib.lookupFunction<Int Function(Int), int Function(int)>(
    'close',
  );
  late final _fstat = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Uint8>),
        int Function(int, Pointer<Uint8>)
      >(_abi == Abi.macosX64 ? r'fstat$INODE64' : (_arm ? 'fstat64' : 'fstat'));
  late final _fstatAt = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Uint8>, Pointer<Uint8>, Int),
        int Function(int, Pointer<Uint8>, Pointer<Uint8>, int)
      >(
        _abi == Abi.macosX64
            ? r'fstatat$INODE64'
            : (_arm ? 'fstatat64' : 'fstatat'),
      );
  late final _linkAt = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Uint8>, Int, Pointer<Uint8>, Int),
        int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int)
      >('linkat');
  late final _unlinkAt = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Uint8>, Int),
        int Function(int, Pointer<Uint8>, int)
      >('unlinkat');
  late final _mkdirAt = _lib
      .lookupFunction<
        Int Function(Int, Pointer<Uint8>, Uint32),
        int Function(int, Pointer<Uint8>, int)
      >('mkdirat');
  late final _write = _lib
      .lookupFunction<
        IntPtr Function(Int, Pointer<Uint8>, Size),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  late final _pread = _lib
      .lookupFunction<
        IntPtr Function(Int, Pointer<Uint8>, Size, Int64),
        int Function(int, Pointer<Uint8>, int, int)
      >(_arm ? 'pread64' : 'pread');
  late final _fsync = _lib.lookupFunction<Int Function(Int), int Function(int)>(
    'fsync',
  );
  late final _malloc = _lib
      .lookupFunction<
        Pointer<Uint8> Function(Size),
        Pointer<Uint8> Function(int)
      >('malloc');
  late final _free = _lib
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('free');
  late final _errno = _lib
      .lookupFunction<Pointer<Int> Function(), Pointer<Int> Function()>(
        _darwin
            ? '__error'
            : (Platform.isAndroid ? '__errno' : '__errno_location'),
      );

  T _buffer<T>(int length, T Function(Pointer<Uint8>) use) {
    final pointer = _malloc(length);
    if (pointer == nullptr) throw const FileSystemException('无法分配导出缓冲区');
    try {
      return use(pointer);
    } finally {
      _free(pointer);
    }
  }

  T _path<T>(String path, T Function(Pointer<Uint8>) use) {
    final encoded = utf8.encode(path);
    return _buffer(encoded.length + 1, (pointer) {
      pointer.asTypedList(encoded.length).setAll(0, encoded);
      pointer[encoded.length] = 0;
      return use(pointer);
    });
  }

  Never _fail(String operation, [String? path]) {
    final code = _errno().value;
    throw FileSystemException(operation, path, OSError('', code));
  }

  int open(int parent, String path, int flags) => _path(path, (pointer) {
    final fd = _openAt(
      parent,
      pointer,
      flags | _noFollow | _closeOnExec,
      0x180,
    );
    if (fd < 0) _fail('无法打开导出暂存对象', path);
    return fd;
  });

  _FileIdentity _readIdentity(Pointer<Uint8> stat) => (
    device: _darwin ? stat.cast<Uint32>().value : stat.cast<Uint64>().value,
    inode: (stat + (_arm ? 96 : 8)).cast<Uint64>().value,
  );

  _FileIdentity identity(int fd) => _buffer(256, (stat) {
    if (_fstat(fd, stat) != 0) _fail('无法确认导出暂存归属');
    return _readIdentity(stat);
  });

  _FileIdentity? identityAt(int parent, String path) => _path(path, (pointer) {
    return _buffer(256, (stat) {
      if (_fstatAt(parent, pointer, stat, _darwin ? 0x20 : 0x100) == 0) {
        return _readIdentity(stat);
      }
      if (_errno().value == 2) return null; // ENOENT
      _fail('无法确认导出暂存归属', path);
    });
  });

  void link(int parent, String from, String to) {
    _path(
      from,
      (source) => _path(to, (target) {
        if (_linkAt(parent, source, parent, target, 0) != 0) {
          _fail('无法发布导出暂存文件', to);
        }
      }),
    );
  }

  bool makeDirectory(int parent, String name) => _path(name, (pointer) {
    if (_mkdirAt(parent, pointer, 0x1c0) == 0) return true; // 0700
    if (_errno().value == 17) return false; // EEXIST
    _fail('无法创建导出暂存目录', name);
  });

  bool remove(int parent, String name, {bool directory = false}) =>
      _path(name, (pointer) {
        final flags = directory ? (_darwin ? 0x80 : 0x200) : 0;
        if (_unlinkAt(parent, pointer, flags) == 0) return true;
        if (_errno().value == 2) return false;
        _fail('无法清理导出暂存文件', name);
      });

  void writeAll(int fd, List<int> bytes) {
    _buffer(bytes.length, (buffer) {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final count = _write(fd, buffer + offset, bytes.length - offset);
        if (count < 0 && _errno().value == 4) continue; // EINTR
        if (count <= 0) _fail('无法写入导出暂存文件');
        offset += count;
      }
    });
  }

  Uint8List read(int fd, int offset, int length) {
    if (length == 0) return Uint8List(0);
    return _buffer(length, (buffer) {
      var read = 0;
      while (read < length) {
        final count = _pread(fd, buffer + read, length - read, offset + read);
        if (count < 0 && _errno().value == 4) continue;
        if (count < 0) _fail('无法读取导出暂存文件');
        if (count == 0) break;
        read += count;
      }
      return Uint8List.fromList(buffer.asTypedList(read));
    });
  }

  void flush(int fd) {
    if (_fsync(fd) != 0) _fail('无法写入导出暂存文件');
  }
}
