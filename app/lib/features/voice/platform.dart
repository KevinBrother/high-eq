import 'dart:async';

import 'package:flutter/services.dart';

import 'pcm_chunk.dart';

export 'pcm_chunk.dart';

/// The only boundary allowed to read the microphone or play local PCM.
///
/// Implementations return 16 kHz mono PCM16LE together with the UTC time of
/// the samples. They may mark the first chunk after a capture discontinuity.
/// They must not transcribe, persist plaintext, or upload audio.
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
