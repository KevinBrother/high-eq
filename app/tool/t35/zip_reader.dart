import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _endOfCentralDirectory = 0x06054b50;
const _centralFileHeader = 0x02014b50;
const _localFileHeader = 0x04034b50;
const _maxCommentLength = 65535;
const _endRecordLength = 22;

/// Minimal, test-only ZIP reader for the export archive produced by Go's
/// archive/zip writer. It supports stored and raw-deflate entries and verifies
/// sizes plus CRC32, without adding a production dependency.
Future<Map<String, Uint8List>> readZipArchive(String path) async {
  final bytes = await File(path).readAsBytes();
  if (bytes.length < _endRecordLength) {
    throw const FormatException('ZIP is too short');
  }
  final data = ByteData.sublistView(bytes);
  final minimum = bytes.length > _endRecordLength + _maxCommentLength
      ? bytes.length - _endRecordLength - _maxCommentLength
      : 0;
  int? eocd;
  for (var at = bytes.length - _endRecordLength; at >= minimum; at--) {
    if (data.getUint32(at, Endian.little) != _endOfCentralDirectory) continue;
    final commentLength = data.getUint16(at + 20, Endian.little);
    if (at + _endRecordLength + commentLength == bytes.length) {
      eocd = at;
      break;
    }
  }
  if (eocd == null) throw const FormatException('ZIP end record missing');

  final disk = data.getUint16(eocd + 4, Endian.little);
  final directoryDisk = data.getUint16(eocd + 6, Endian.little);
  final diskEntries = data.getUint16(eocd + 8, Endian.little);
  final entries = data.getUint16(eocd + 10, Endian.little);
  final directorySize = data.getUint32(eocd + 12, Endian.little);
  final directoryOffset = data.getUint32(eocd + 16, Endian.little);
  if (disk != 0 ||
      directoryDisk != 0 ||
      entries == 0 ||
      entries == 0xffff ||
      diskEntries != entries ||
      directoryOffset + directorySize != eocd) {
    throw const FormatException('ZIP directory is invalid or unsupported');
  }

  final files = <String, Uint8List>{};
  var cursor = directoryOffset;
  for (var index = 0; index < entries; index++) {
    _require(bytes, cursor, 46, 'central directory header');
    if (data.getUint32(cursor, Endian.little) != _centralFileHeader) {
      throw const FormatException('ZIP central directory header missing');
    }
    final flags = data.getUint16(cursor + 8, Endian.little);
    final method = data.getUint16(cursor + 10, Endian.little);
    final expectedCrc = data.getUint32(cursor + 16, Endian.little);
    final compressedSize = data.getUint32(cursor + 20, Endian.little);
    final uncompressedSize = data.getUint32(cursor + 24, Endian.little);
    final nameLength = data.getUint16(cursor + 28, Endian.little);
    final extraLength = data.getUint16(cursor + 30, Endian.little);
    final commentLength = data.getUint16(cursor + 32, Endian.little);
    final localOffset = data.getUint32(cursor + 42, Endian.little);
    if ((flags & 1) != 0 ||
        compressedSize == 0xffffffff ||
        uncompressedSize == 0xffffffff ||
        localOffset == 0xffffffff) {
      throw const FormatException('encrypted or ZIP64 entries are unsupported');
    }
    final nameStart = cursor + 46;
    final nameEnd = nameStart + nameLength;
    final next = nameEnd + extraLength + commentLength;
    _require(bytes, nameStart, nameLength, 'central directory name');
    _require(bytes, next, 0, 'central directory entry');
    final name = utf8.decode(bytes.sublist(nameStart, nameEnd));

    _require(bytes, localOffset, 30, 'local file header');
    if (data.getUint32(localOffset, Endian.little) != _localFileHeader) {
      throw const FormatException('ZIP local file header missing');
    }
    final localNameLength = data.getUint16(localOffset + 26, Endian.little);
    final localExtraLength = data.getUint16(localOffset + 28, Endian.little);
    final contentStart = localOffset + 30 + localNameLength + localExtraLength;
    final contentEnd = contentStart + compressedSize;
    _require(bytes, contentStart, compressedSize, 'ZIP entry data');
    final compressed = Uint8List.sublistView(bytes, contentStart, contentEnd);
    final content = switch (method) {
      0 => Uint8List.fromList(compressed),
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(compressed)),
      _ => throw FormatException('unsupported ZIP compression method $method'),
    };
    if (content.length != uncompressedSize) {
      throw FormatException('ZIP entry size mismatch for $name');
    }
    if (_crc32(content) != expectedCrc) {
      throw FormatException('ZIP entry checksum mismatch for $name');
    }
    if (files.containsKey(name)) {
      throw FormatException('duplicate ZIP entry $name');
    }
    files[name] = content;
    cursor = next;
  }
  if (cursor != directoryOffset + directorySize) {
    throw const FormatException('ZIP directory size mismatch');
  }
  return files;
}

void _require(List<int> bytes, int offset, int length, String label) {
  if (offset < 0 || length < 0 || offset + length > bytes.length) {
    throw FormatException('truncated $label');
  }
}

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
