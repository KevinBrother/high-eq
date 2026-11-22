import 'dart:math' as math;
import 'dart:typed_data';

const syntheticSampleRate = 16000;

Uint8List tone({
  required Duration duration,
  double frequency = 220,
  double amplitude = 8000,
  double syllableHz = 0,
  int sampleRate = syntheticSampleRate,
}) {
  final count = (duration.inMicroseconds * sampleRate / 1000000).round();
  final bytes = Uint8List(count * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < count; i++) {
    final t = i / sampleRate;
    final envelope = syllableHz == 0
        ? 1.0
        : (math.sin(2 * math.pi * syllableHz * t) > 0 ? 1.0 : 0.08);
    final sample =
        (amplitude * envelope * math.sin(2 * math.pi * frequency * t))
            .round()
            .clamp(-32768, 32767);
    data.setInt16(i * 2, sample, Endian.little);
  }
  return bytes;
}

Uint8List silence({
  required Duration duration,
  int sampleRate = syntheticSampleRate,
}) {
  final count = (duration.inMicroseconds * sampleRate / 1000000).round();
  return Uint8List(count * 2);
}

Uint8List concatPcm(Iterable<Uint8List> chunks) {
  final builder = BytesBuilder(copy: false);
  for (final chunk in chunks) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
