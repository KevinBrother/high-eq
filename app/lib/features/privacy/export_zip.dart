import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'deflate_integrity.dart';
import 'export_staging_file.dart';

const _maxZipComment = 65535;
const _endRecordLength = 22;
const _tailLength = _endRecordLength + _maxZipComment;
const _headLength = 4096;
const _validationChunkLength = 64 * 1024;

/// A downloaded ZIP failed structural validation. This is distinct from an
/// HTTP/transport [FormatException] so the store can show the right recovery.
class PrivacyExportIntegrityFailure extends FormatException {
  const PrivacyExportIntegrityFailure(super.message);
}

/// Bounded-memory ZIP validator. It retains only the first header and the
/// maximum possible end-record window, then checks that the EOCD describes the
/// actual stream length and that `manifest.json` is the first local entry.
class PrivacyExportZipStream {
  final _tail = <int>[];
  final _head = <int>[];
  var _bytes = 0;

  void add(List<int> chunk) {
    _bytes += chunk.length;
    final headRoom = _headLength - _head.length;
    if (headRoom > 0) _head.addAll(chunk.take(headRoom));
    if (chunk.length >= _tailLength) {
      _tail
        ..clear()
        ..addAll(chunk.sublist(chunk.length - _tailLength));
      return;
    }
    final overflow = _tail.length + chunk.length - _tailLength;
    if (overflow > 0) _tail.removeRange(0, overflow);
    _tail.addAll(chunk);
  }

  int finish() {
    if (_bytes < _endRecordLength || _head.length < 30) {
      throw const PrivacyExportIntegrityFailure('导出文件不完整');
    }
    final head = ByteData.sublistView(Uint8List.fromList(_head));
    if (head.getUint32(0, Endian.little) != 0x04034b50) {
      throw const PrivacyExportIntegrityFailure('导出文件不是 ZIP');
    }
    final nameLength = head.getUint16(26, Endian.little);
    final extraLength = head.getUint16(28, Endian.little);
    final nameEnd = 30 + nameLength;
    if (nameEnd + extraLength > _head.length) {
      throw const PrivacyExportIntegrityFailure('导出文件头不完整');
    }
    String firstFile;
    try {
      firstFile = utf8.decode(_head.sublist(30, nameEnd));
    } on FormatException {
      throw const PrivacyExportIntegrityFailure('导出文件条目名称异常');
    }
    if (firstFile != 'manifest.json') {
      throw const PrivacyExportIntegrityFailure('导出文件缺少 manifest.json');
    }

    final tail = ByteData.sublistView(Uint8List.fromList(_tail));
    final tailStart = _bytes - _tail.length;
    var eocd = -1;
    for (var at = _tail.length - _endRecordLength; at >= 0; at--) {
      if (tail.getUint32(at, Endian.little) != 0x06054b50) continue;
      final commentLength = tail.getUint16(at + 20, Endian.little);
      if (at + _endRecordLength + commentLength == _tail.length) {
        eocd = tailStart + at;
        break;
      }
    }
    if (eocd < 0) throw const PrivacyExportIntegrityFailure('导出文件缺少结束目录');

    final relative = eocd - tailStart;
    final disk = tail.getUint16(relative + 4, Endian.little);
    final directoryDisk = tail.getUint16(relative + 6, Endian.little);
    final diskEntries = tail.getUint16(relative + 8, Endian.little);
    final entries = tail.getUint16(relative + 10, Endian.little);
    final directorySize = tail.getUint32(relative + 12, Endian.little);
    final directoryOffset = tail.getUint32(relative + 16, Endian.little);
    if (disk != 0 ||
        directoryDisk != 0 ||
        entries == 0 ||
        diskEntries != entries ||
        directoryOffset + directorySize != eocd) {
      throw const PrivacyExportIntegrityFailure('导出文件目录异常');
    }
    return _bytes;
  }
}

abstract interface class _ZipInput {
  int get length;
  Future<Uint8List> read(int offset, int length);
}

class _FileZipInput implements _ZipInput {
  _FileZipInput(this.staging, this.length);

  final ExportStagingFile staging;

  @override
  final int length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length < 0 || offset + length > this.length) {
      throw const PrivacyExportIntegrityFailure('导出文件不完整');
    }
    final bytes = staging.read(offset, length);
    if (bytes.length != length) {
      throw const PrivacyExportIntegrityFailure('导出文件不完整');
    }
    return bytes;
  }
}

class _CentralEntry {
  _CentralEntry({
    required this.name,
    required this.flags,
    required this.compression,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localOffset,
  });

  final String name;
  final int flags;
  final int compression;
  final int crc32;
  final int compressedSize;
  final int uncompressedSize;
  final int localOffset;
  late int dataOffset;
}

Future<void> validateStagedPrivacyExport(
  ExportStagingFile staging,
  int length, {
  required bool requireAccountManifest,
}) => _validateZip(
  _FileZipInput(staging, length),
  requireAccountManifest: requireAccountManifest,
);

Future<void> _validateZip(
  _ZipInput input, {
  bool requireAccountManifest = false,
}) async {
  if (input.length < _endRecordLength) {
    throw const PrivacyExportIntegrityFailure('导出文件不完整');
  }
  final eocd = await _findEndRecord(input);
  final end = await input.read(eocd, _endRecordLength);
  final disk = _uint16(end, 4);
  final directoryDisk = _uint16(end, 6);
  final diskEntries = _uint16(end, 8);
  final entries = _uint16(end, 10);
  final directorySize = _uint32(end, 12);
  final directoryOffset = _uint32(end, 16);
  final commentLength = _uint16(end, 20);
  if (disk != 0 ||
      directoryDisk != 0 ||
      diskEntries != entries ||
      entries == 0 ||
      entries == 0xffff ||
      (requireAccountManifest && entries != _accountModules.length + 1) ||
      directorySize == 0xffffffff ||
      directoryOffset == 0xffffffff ||
      directoryOffset + directorySize != eocd ||
      eocd + _endRecordLength + commentLength != input.length) {
    throw const PrivacyExportIntegrityFailure('导出文件目录异常');
  }

  final central = <_CentralEntry>[];
  final names = <String>{};
  var cursor = directoryOffset;
  final directoryEnd = directoryOffset + directorySize;
  for (var index = 0; index < entries; index++) {
    if (cursor + 46 > directoryEnd) {
      throw const PrivacyExportIntegrityFailure('导出文件目录条目不完整');
    }
    final fixed = await input.read(cursor, 46);
    if (_uint32(fixed, 0) != 0x02014b50) {
      throw const PrivacyExportIntegrityFailure('导出文件目录条目异常');
    }
    final flags = _uint16(fixed, 8);
    final compression = _uint16(fixed, 10);
    final crc32 = _uint32(fixed, 16);
    final compressedSize = _uint32(fixed, 20);
    final uncompressedSize = _uint32(fixed, 24);
    final nameLength = _uint16(fixed, 28);
    final extraLength = _uint16(fixed, 30);
    final entryCommentLength = _uint16(fixed, 32);
    final entryDisk = _uint16(fixed, 34);
    final localOffset = _uint32(fixed, 42);
    final variableLength = nameLength + extraLength + entryCommentLength;
    if (cursor + 46 + variableLength > directoryEnd) {
      throw const PrivacyExportIntegrityFailure('导出文件目录条目异常');
    }
    final variable = await input.read(cursor + 46, variableLength);
    final name = _entryName(variable, 0, nameLength);
    if (name.isEmpty ||
        (flags & 0x41) != 0 ||
        (compression != 0 && compression != 8) ||
        entryDisk != 0 ||
        compressedSize == 0xffffffff ||
        uncompressedSize == 0xffffffff ||
        localOffset == 0xffffffff ||
        localOffset >= directoryOffset ||
        !names.add(name)) {
      throw const PrivacyExportIntegrityFailure('导出文件目录条目异常');
    }
    central.add(
      _CentralEntry(
        name: name,
        flags: flags,
        compression: compression,
        crc32: crc32,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localOffset: localOffset,
      ),
    );
    cursor += 46 + variableLength;
  }
  if (cursor != directoryEnd) {
    throw const PrivacyExportIntegrityFailure('导出文件目录条目数量异常');
  }

  central.sort((left, right) => left.localOffset.compareTo(right.localOffset));
  if (central.first.localOffset != 0 || central.first.name != 'manifest.json') {
    throw const PrivacyExportIntegrityFailure('导出文件缺少 manifest.json');
  }
  for (var index = 0; index < central.length; index++) {
    final entry = central[index];
    final nextOffset = index + 1 < central.length
        ? central[index + 1].localOffset
        : directoryOffset;
    final fixed = await input.read(entry.localOffset, 30);
    if (_uint32(fixed, 0) != 0x04034b50) {
      throw const PrivacyExportIntegrityFailure('导出文件本地条目异常');
    }
    final localFlags = _uint16(fixed, 6);
    final localCompression = _uint16(fixed, 8);
    final localCrc32 = _uint32(fixed, 14);
    final localCompressedSize = _uint32(fixed, 18);
    final localUncompressedSize = _uint32(fixed, 22);
    final nameLength = _uint16(fixed, 26);
    final extraLength = _uint16(fixed, 28);
    final name = _entryName(
      await input.read(entry.localOffset + 30, nameLength + extraLength),
      0,
      nameLength,
    );
    if (localFlags != entry.flags ||
        localCompression != entry.compression ||
        name != entry.name) {
      throw const PrivacyExportIntegrityFailure('导出文件本地条目与目录不一致');
    }
    final hasDescriptor = (entry.flags & 0x08) != 0;
    if (!hasDescriptor &&
        (localCrc32 != entry.crc32 ||
            localCompressedSize != entry.compressedSize ||
            localUncompressedSize != entry.uncompressedSize)) {
      throw const PrivacyExportIntegrityFailure('导出文件本地条目大小异常');
    }
    if (hasDescriptor &&
        ((localCrc32 != 0 && localCrc32 != entry.crc32) ||
            (localCompressedSize != 0 &&
                localCompressedSize != entry.compressedSize) ||
            (localUncompressedSize != 0 &&
                localUncompressedSize != entry.uncompressedSize))) {
      throw const PrivacyExportIntegrityFailure('导出文件本地条目大小异常');
    }
    entry.dataOffset = entry.localOffset + 30 + nameLength + extraLength;
    final dataEnd = entry.dataOffset + entry.compressedSize;
    if (dataEnd > nextOffset) {
      throw const PrivacyExportIntegrityFailure('导出文件条目越界');
    }
    final descriptorLength = nextOffset - dataEnd;
    if (!hasDescriptor) {
      if (descriptorLength != 0) {
        throw const PrivacyExportIntegrityFailure('导出文件本地条目重叠或缺失');
      }
      continue;
    }
    // The optional signature can equal an unsigned descriptor's CRC. Use the
    // next record's offset to tell the 12-byte and 16-byte forms apart.
    if (descriptorLength != 12 && descriptorLength != 16) {
      throw const PrivacyExportIntegrityFailure('导出文件数据描述符异常');
    }
    final descriptor = await input.read(dataEnd, descriptorLength);
    final valueOffset = descriptorLength - 12;
    if ((valueOffset == 4 && _uint32(descriptor, 0) != 0x08074b50) ||
        _uint32(descriptor, valueOffset) != entry.crc32 ||
        _uint32(descriptor, valueOffset + 4) != entry.compressedSize ||
        _uint32(descriptor, valueOffset + 8) != entry.uncompressedSize) {
      throw const PrivacyExportIntegrityFailure('导出文件数据描述符异常');
    }
  }

  if (requireAccountManifest) {
    final manifest = central.first;
    const maxManifestBytes = 4096;
    if (manifest.uncompressedSize > maxManifestBytes ||
        manifest.compressedSize > maxManifestBytes) {
      throw const PrivacyExportIntegrityFailure('导出清单大小异常');
    }
    final content = BytesBuilder(copy: false);
    await _verifyEntry(input, manifest, onData: content.add);
    _verifyAccountManifest(content.takeBytes(), names);
  }

  for (final entry in requireAccountManifest ? central.skip(1) : central) {
    await _verifyEntry(input, entry);
  }
}

const _accountModules = {
  'accounts',
  'assessments',
  'profiles',
  'training',
  'chat_imports',
  'replies',
  'reviews',
  'growth',
  'ai_calls',
  'emotion',
  'manual_marks',
  'payments',
  'membership',
};

void _verifyAccountManifest(Uint8List bytes, Set<String> actualNames) {
  final expectedNames = {
    'manifest.json',
    ..._accountModules.map((name) => '$name.json'),
  };
  bool matches(Object? value, Set<String> expected) =>
      value is List &&
      value.length == expected.length &&
      value.toSet().length == expected.length &&
      value.every(expected.contains);
  try {
    final manifest = jsonDecode(utf8.decode(bytes));
    if (manifest is Map &&
        matches(manifest['modules'], _accountModules) &&
        matches(manifest['files'], expectedNames) &&
        actualNames.length == expectedNames.length &&
        actualNames.containsAll(expectedNames)) {
      return;
    }
  } on FormatException {
    // Do not expose the downloaded manifest in an error message.
  }
  throw const PrivacyExportIntegrityFailure('导出清单与分区不一致');
}

Future<int> _findEndRecord(_ZipInput input) async {
  final length = input.length < _tailLength ? input.length : _tailLength;
  final start = input.length - length;
  final tail = await input.read(start, length);
  for (var at = tail.length - _endRecordLength; at >= 0; at--) {
    if (_uint32(tail, at) != 0x06054b50) continue;
    final commentLength = _uint16(tail, at + 20);
    if (at + _endRecordLength + commentLength == tail.length) {
      return start + at;
    }
  }
  throw const PrivacyExportIntegrityFailure('导出文件缺少结束目录');
}

Future<void> _verifyEntry(
  _ZipInput input,
  _CentralEntry entry, {
  void Function(List<int>)? onData,
}) async {
  final sink = _CrcSink(entry.uncompressedSize, onData);
  ByteConversionSink? decoder;
  DeflateStreamVerifier? deflateVerifier;
  try {
    if (entry.compression == 8) {
      decoder = ZLibDecoder(raw: true).startChunkedConversion(sink);
      deflateVerifier = DeflateStreamVerifier();
    }
    var offset = entry.dataOffset;
    var remaining = entry.compressedSize;
    while (remaining > 0) {
      final length = remaining > _validationChunkLength
          ? _validationChunkLength
          : remaining;
      final chunk = await input.read(offset, length);
      if (decoder == null) {
        sink.add(chunk);
      } else {
        decoder.add(chunk);
        deflateVerifier!.add(chunk);
      }
      offset += length;
      remaining -= length;
    }
    decoder?.close();
    deflateVerifier?.finish();
  } on PrivacyExportIntegrityFailure {
    rethrow;
  } on FileSystemException {
    rethrow;
  } catch (_) {
    throw const PrivacyExportIntegrityFailure('导出文件条目损坏');
  }
  if (sink.bytes != entry.uncompressedSize || sink.crc != entry.crc32) {
    throw const PrivacyExportIntegrityFailure('导出文件条目校验失败');
  }
}

String _entryName(List<int> bytes, int offset, int length) {
  try {
    return utf8.decode(bytes.sublist(offset, offset + length));
  } on FormatException {
    throw const PrivacyExportIntegrityFailure('导出文件条目名称异常');
  }
}

int _uint16(List<int> bytes, int offset) =>
    bytes[offset] | bytes[offset + 1] << 8;

int _uint32(List<int> bytes, int offset) =>
    bytes[offset] |
    bytes[offset + 1] << 8 |
    bytes[offset + 2] << 16 |
    bytes[offset + 3] << 24;

class _CrcSink implements Sink<List<int>> {
  _CrcSink(this.expectedBytes, this.onData);

  final void Function(List<int>)? onData;

  final int expectedBytes;
  final _crc = _Crc32();
  var bytes = 0;

  int get crc => _crc.value;

  @override
  void add(List<int> data) {
    bytes += data.length;
    if (bytes > expectedBytes) {
      throw const PrivacyExportIntegrityFailure('导出文件条目解压大小异常');
    }
    _crc.add(data);
    onData?.call(data);
  }

  @override
  void close() {}
}

class _Crc32 {
  static final List<int> _table = List<int>.generate(256, (value) {
    var crc = value;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 0 ? crc >> 1 : 0xedb88320 ^ (crc >> 1);
    }
    return crc;
  });

  var _value = 0xffffffff;

  void add(List<int> bytes) {
    for (final byte in bytes) {
      _value = _table[(_value ^ byte) & 0xff] ^ (_value >> 8);
    }
  }

  int get value => (_value ^ 0xffffffff) & 0xffffffff;
}
