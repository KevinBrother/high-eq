import 'dart:async';

import 'package:flutter/services.dart';

class VoicePcmChunk {
  final Uint8List pcm;
  final DateTime capturedAt;

  const VoicePcmChunk({required this.pcm, required this.capturedAt});
}

/// The only boundary allowed to read the microphone or play local PCM.
///
/// Implementations return 16 kHz mono PCM16LE together with the UTC time of
/// the samples. They must not transcribe, persist plaintext, or upload audio.
abstract interface class VoiceCapturePlatform {
  Stream<VoicePcmChunk> get pcm;
  Future<bool> checkPermission();
  Future<bool> requestPermission();
  Future<void> start();
  Future<void> stop();
  Future<void> playPcm(Uint8List pcm);
  Future<void> stopPlayback();
  Future<void> dispose();
}

class MethodChannelVoiceCapture implements VoiceCapturePlatform {
  static const controlChannel = MethodChannel('cn.higheq/voice-capture');
  static const pcmChannel = EventChannel('cn.higheq/voice-capture/pcm');

  final MethodChannel _control;
  final EventChannel _pcm;
  late final Stream<VoicePcmChunk> _samples = _pcm
      .receiveBroadcastStream()
      .map(voicePcmChunkFromEvent)
      .asBroadcastStream();

  MethodChannelVoiceCapture({MethodChannel? control, EventChannel? pcm})
    : _control = control ?? controlChannel,
      _pcm = pcm ?? pcmChannel;

  @override
  Stream<VoicePcmChunk> get pcm => _samples;

  @override
  Future<bool> checkPermission() async {
    try {
      return await _control.invokeMethod<bool>('checkPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _control.invokeMethod<bool>('requestPermission') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> start() => _control.invokeMethod<void>('start');

  @override
  Future<void> stop() async {
    try {
      await _control.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Tests and unsupported targets fail closed without crashing the page.
    }
  }

  @override
  Future<void> playPcm(Uint8List pcm) =>
      _control.invokeMethod<void>('play', {'pcm': pcm});

  @override
  Future<void> stopPlayback() async {
    try {
      await _control.invokeMethod<void>('stopPlayback');
    } on MissingPluginException {
      // Nothing to stop when the native host is unavailable.
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await stop();
    } finally {
      await stopPlayback();
    }
  }
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
  return VoicePcmChunk(
    pcm: pcm,
    capturedAt: DateTime.fromMicrosecondsSinceEpoch(capturedAtUs, isUtc: true),
  );
}

Uint8List _asPcm(Object? value) {
  if (value is Uint8List) return value;
  if (value is List<int>) return Uint8List.fromList(value);
  throw const FormatException('语音平台返回了非 PCM 数据');
}
