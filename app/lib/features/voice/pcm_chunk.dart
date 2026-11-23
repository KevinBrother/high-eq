import 'dart:typed_data';

class VoicePcmChunk {
  final Uint8List pcm;
  final DateTime capturedAt;
  final bool startsNewSegment;

  const VoicePcmChunk({
    required this.pcm,
    required this.capturedAt,
    this.startsNewSegment = false,
  });
}

VoicePcmChunk voicePcmChunkFromEvent(Object? event) {
  if (event is! Map) {
    throw const FormatException('语音平台返回了无效采样事件');
  }
  final pcm = _asPcm(event['pcm']);
  final capturedAtUs = event['captured_at_us'];
  if (capturedAtUs is! int || capturedAtUs <= 0) {
    throw const FormatException('语音平台缺少样本采集时间');
  }
  final startsNewSegment = event.containsKey('starts_new_segment')
      ? event['starts_new_segment']
      : false;
  if (startsNewSegment is! bool) {
    throw const FormatException('语音平台返回了无效采样段标记');
  }
  return VoicePcmChunk(
    pcm: pcm,
    capturedAt: DateTime.fromMicrosecondsSinceEpoch(capturedAtUs, isUtc: true),
    startsNewSegment: startsNewSegment,
  );
}

Uint8List _asPcm(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  throw const FormatException('语音平台返回了非 PCM 数据');
}
