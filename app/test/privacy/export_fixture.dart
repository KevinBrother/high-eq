import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const accountExportModules = [
  'accounts',
  'ai_calls',
  'assessments',
  'chat_imports',
  'emotion',
  'growth',
  'manual_marks',
  'membership',
  'payments',
  'profiles',
  'replies',
  'reviews',
  'training',
];

/// Builds a synthetic DEFLATE archive with data descriptors, as on the wire.
Uint8List accountExportFixture(
  String account, {
  String? omit,
  bool wrongManifest = false,
}) {
  final entries = <String, Object>{
    'manifest.json': {
      'modules': [
        for (final module in accountExportModules)
          if (!wrongManifest || module != 'training') module,
      ],
      'files': [
        'manifest.json',
        for (final name in accountExportModules) '$name.json',
      ],
    },
    for (final module in accountExportModules)
      if (module != omit)
        '$module.json': [
          if (module == 'accounts') {'user_id': account},
        ],
  };
  final body = BytesBuilder();
  final central = BytesBuilder();
  for (final MapEntry(:key, :value) in entries.entries) {
    final offset = body.length;
    final name = utf8.encode(key);
    final data = utf8.encode(jsonEncode(value));
    final compressed = ZLibEncoder(raw: true).convert(data);
    final crc = _crc32(data);
    final local = _record(30, 0x04034b50)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 8, Endian.little)
      ..setUint16(8, 8, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    final descriptor = _record(16, 0x08074b50)
      ..setUint32(4, crc, Endian.little)
      ..setUint32(8, compressed.length, Endian.little)
      ..setUint32(12, data.length, Endian.little);
    body
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(compressed)
      ..add(descriptor.buffer.asUint8List());
    final directory = _record(46, 0x02014b50)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(8, 8, Endian.little)
      ..setUint16(10, 8, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, compressed.length, Endian.little)
      ..setUint32(24, data.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(directory.buffer.asUint8List())
      ..add(name);
  }
  final end = _record(22, 0x06054b50)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, central.length, Endian.little)
    ..setUint32(16, body.length, Endian.little);
  body
    ..add(central.takeBytes())
    ..add(end.buffer.asUint8List());
  return body.takeBytes();
}

ByteData _record(int length, int signature) =>
    ByteData(length)..setUint32(0, signature, Endian.little);

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final value in bytes) {
    crc ^= value;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
    }
  }
  return crc ^ 0xffffffff;
}
