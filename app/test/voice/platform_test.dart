import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/features/voice/platform.dart';

void main() {
  test('parses PCM together with its UTC sample capture time', () {
    final pcm = Uint8List.fromList([1, 0, 2, 0]);
    final capturedAtUs = DateTime.utc(2026, 11, 21, 9).microsecondsSinceEpoch;

    final chunk = voicePcmChunkFromEvent({
      'pcm': pcm,
      'captured_at_us': capturedAtUs,
    });

    expect(chunk.pcm, pcm);
    expect(chunk.capturedAt, DateTime.utc(2026, 11, 21, 9));
  });

  test('rejects a PCM event without a native capture timestamp', () {
    expect(
      () => voicePcmChunkFromEvent({
        'pcm': Uint8List.fromList([1, 0]),
      }),
      throwsFormatException,
    );
  });

  test('rejects the retired bare-PCM event shape', () {
    expect(
      () => voicePcmChunkFromEvent(Uint8List.fromList([1, 0])),
      throwsFormatException,
    );
  });
}
