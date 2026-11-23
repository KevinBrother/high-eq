import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:high_eq/core/consent.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/voice/access.dart';
import 'package:high_eq/features/voice/controller.dart';
import 'package:high_eq/features/voice/features.dart';
import 'package:high_eq/features/voice/platform.dart';
import 'package:high_eq/features/voice/store.dart';

class MemorySecret implements SecretStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> replace(String? next) async => value = next;
}

Tokens testTokens(String account) => Tokens(
  account,
  'access-$account',
  'refresh-$account',
  DateTime.now().toUtc().add(const Duration(hours: 1)),
);

class FakeVoiceAccess implements VoiceAccess {
  bool voiceGranted;
  bool retentionGranted;
  DateTime? expiry;
  bool readAllowed = true;
  int readFailuresRemaining = 0;
  bool failVoiceRevocation = false;
  bool failRetentionRevocation = false;
  int readCalls = 0;
  Completer<void>? readGate;
  final List<String> events = [];
  final List<String>? audit;

  FakeVoiceAccess({
    this.voiceGranted = true,
    this.retentionGranted = false,
    this.expiry,
    this.audit,
  });

  void _record(String event) {
    events.add(event);
    audit?.add(event);
  }

  @override
  Future<bool> readIfAllowed(
    AccountScope scope,
    CollectionPurpose purpose, {
    required Future<bool> Function() systemGranted,
    required void Function() beginRead,
  }) async {
    readCalls++;
    if (readGate != null) await readGate!.future;
    final granted = switch (purpose) {
      CollectionPurpose.voice => voiceGranted,
      CollectionPurpose.audioRetention => voiceGranted && retentionGranted,
      CollectionPurpose.health => false,
    };
    if (!readAllowed || !granted || readFailuresRemaining > 0) {
      if (readFailuresRemaining > 0) readFailuresRemaining--;
      return false;
    }
    if (!await systemGranted()) return false;
    beginRead();
    return true;
  }

  @override
  Future<bool> hasConsent(
    AccountScope scope,
    CollectionPurpose purpose,
  ) async => switch (purpose) {
    CollectionPurpose.voice => voiceGranted,
    CollectionPurpose.audioRetention => retentionGranted,
    CollectionPurpose.health => false,
  };

  @override
  Future<DateTime?> memberExpiry(AccountScope scope) async => expiry;

  @override
  Future<void> setConsent(
    AccountScope scope,
    CollectionPurpose purpose,
    bool granted,
  ) async {
    _record('consent:${wirePurpose(purpose)}:$granted');
    if (!granted && purpose == CollectionPurpose.voice && failVoiceRevocation) {
      throw StateError('simulated revoke failure');
    }
    if (!granted &&
        purpose == CollectionPurpose.audioRetention &&
        failRetentionRevocation) {
      throw StateError('simulated retention revoke failure');
    }
    switch (purpose) {
      case CollectionPurpose.voice:
        voiceGranted = granted;
      case CollectionPurpose.audioRetention:
        retentionGranted = granted;
      case CollectionPurpose.health:
        break;
    }
  }
}

class FakeVoiceCapture implements VoiceCapturePlatform {
  final StreamController<VoicePcmChunk> _pcm =
      StreamController<VoicePcmChunk>.broadcast();
  final List<String> events = [];
  final List<Uint8List> played = [];
  bool permission = true;
  bool permissionRequested = false;
  DateTime? defaultCapturedAt;
  int startCalls = 0;
  int stopCalls = 0;
  int stopPlaybackCalls = 0;
  int stopFailuresRemaining = 0;
  int stopPlaybackFailuresRemaining = 0;
  Completer<void>? startGate;
  bool closed = false;
  Future<void>? _disposing;
  final List<String>? audit;

  FakeVoiceCapture({this.audit});

  void _record(String event) {
    events.add(event);
    audit?.add(event);
  }

  @override
  Stream<VoicePcmChunk> get pcm => _pcm.stream;

  void emitEvent(Map<String, Object?> event) {
    if (!closed) _pcm.add(voicePcmChunkFromEvent(event));
  }

  void emit(Uint8List pcm, {DateTime? capturedAt}) {
    if (closed) return;
    _pcm.add(
      VoicePcmChunk(
        pcm: pcm,
        capturedAt: (capturedAt ?? defaultCapturedAt ?? DateTime.now()).toUtc(),
      ),
    );
  }

  @override
  Future<bool> checkPermission() async => permission;

  @override
  Future<bool> requestPermission() async {
    permissionRequested = true;
    return permission;
  }

  @override
  Future<void> start() async {
    startCalls++;
    _record('start');
    if (startGate != null) await startGate!.future;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _record('stop');
    if (stopFailuresRemaining > 0) {
      stopFailuresRemaining--;
      throw StateError('simulated native stop failure');
    }
  }

  @override
  Future<void> playPcm(Uint8List pcm) async {
    played.add(pcm);
    _record('play');
  }

  @override
  Future<void> stopPlayback() async {
    stopPlaybackCalls++;
    _record('stopPlayback');
    if (stopPlaybackFailuresRemaining > 0) {
      stopPlaybackFailuresRemaining--;
      throw StateError('simulated playback stop failure');
    }
  }

  @override
  Future<void> dispose() => _disposing ??= _dispose();

  /// Synchronous teardown for widget tests, whose fake-async zone can retain
  /// the completion microtask of [dispose] after the widget has unmounted.
  void disposeSync() {
    if (closed) return;
    closed = true;
    unawaited(_pcm.close());
  }

  Future<void> _dispose() async {
    await stop();
    await stopPlayback();
    if (!closed) {
      closed = true;
      await _pcm.close();
    }
  }
}

class FakeVoiceUploader implements VoiceUploader {
  final List<VoiceWindow> uploaded = [];
  final List<String> events = [];
  final List<String>? audit;
  Object? failure;
  Object? Function(VoiceWindow window)? failureFor;
  Future<void> Function()? beforeGuard;

  FakeVoiceUploader({this.audit});

  @override
  Future<void> upload(
    AccountScope scope,
    VoiceWindow window, {
    Future<void> Function()? beforeSend,
  }) async {
    await beforeGuard?.call();
    await beforeSend?.call();
    events.add('upload');
    audit?.add('upload');
    final failure = failureFor?.call(window) ?? this.failure;
    if (failure != null) throw failure;
    uploaded.add(window);
  }
}

class ManualTimer implements Timer {
  final Duration duration;
  final void Function() callback;
  bool _active = true;
  int _ticks = 0;

  ManualTimer(this.duration, this.callback);

  void fire() {
    if (!_active) return;
    _active = false;
    _ticks++;
    callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _ticks;
}

class ManualTimerFactory {
  final List<ManualTimer> timers = [];

  Timer create(Duration duration, void Function() callback) {
    final timer = ManualTimer(duration, callback);
    timers.add(timer);
    return timer;
  }

  ManualTimer get latestActive => timers.lastWhere((timer) => timer.isActive);

  List<ManualTimer> activeFor(Duration duration) => timers
      .where((timer) => timer.isActive && timer.duration == duration)
      .toList();
}

class RecordingVoiceStore extends VoiceWindowStore {
  final List<String> events = [];
  final List<String>? audit;
  int readRecordingCalls = 0;
  bool failClearPending = false;
  bool failDeleteAllRecordings = false;
  bool failVoiceRevokedTrue = false;
  bool failVoiceRevokedFalse = false;
  bool failRetentionRevokedTrue = false;
  bool failRetentionRevokedFalse = false;

  RecordingVoiceStore(super.sessions, super.scope, {this.audit});

  void _record(String event) {
    events.add(event);
    audit?.add(event);
  }

  @override
  Future<void> clearPending() {
    _record('store:clearPending');
    if (failClearPending) throw StateError('simulated clear failure');
    return super.clearPending();
  }

  @override
  Future<void> deleteAllRecordings() {
    _record('store:deleteAllRecordings');
    if (failDeleteAllRecordings) {
      throw StateError('simulated recording deletion failure');
    }
    return super.deleteAllRecordings();
  }

  @override
  Future<void> setVoiceRevoked(bool value) {
    _record('store:voiceRevoked:$value');
    if ((value && failVoiceRevokedTrue) || (!value && failVoiceRevokedFalse)) {
      throw StateError('simulated voice marker failure');
    }
    return super.setVoiceRevoked(value);
  }

  @override
  Future<void> setRetentionRevoked(bool value) {
    _record('store:retentionRevoked:$value');
    if ((value && failRetentionRevokedTrue) ||
        (!value && failRetentionRevokedFalse)) {
      throw StateError('simulated retention marker failure');
    }
    return super.setRetentionRevoked(value);
  }

  @override
  Future<Uint8List?> readRecording(String id, {DateTime? now}) {
    readRecordingCalls++;
    return super.readRecording(id, now: now);
  }
}

class VoiceHarness {
  final Directory directory;
  final Sessions sessions;
  final AccountScope scope;
  final FakeVoiceAccess access;
  final FakeVoiceCapture platform;
  final FakeVoiceUploader uploader;
  final RecordingVoiceStore store;
  final ManualTimerFactory timers;
  final List<String> audit;
  DateTime clockNow;
  late VoiceController controller;

  VoiceHarness._({
    required this.directory,
    required this.sessions,
    required this.scope,
    required this.access,
    required this.platform,
    required this.uploader,
    required this.store,
    required this.timers,
    required this.audit,
    required this.clockNow,
  });

  static Future<VoiceHarness> create({
    DateTime? clock,
    bool voiceGranted = true,
    bool retentionGranted = false,
    DateTime? expiry,
  }) async {
    final now = (clock ?? DateTime.now()).toUtc();
    final directory = await Directory.systemTemp.createTemp('t29-controller');
    final sessions = Sessions(MemorySecret(), directory);
    final scope = await sessions.activate(testTokens('A'));
    final audit = <String>[];
    final access = FakeVoiceAccess(
      voiceGranted: voiceGranted,
      retentionGranted: retentionGranted,
      expiry: expiry ?? now.add(const Duration(hours: 1)),
      audit: audit,
    );
    final platform = FakeVoiceCapture(audit: audit)..defaultCapturedAt = now;
    final uploader = FakeVoiceUploader(audit: audit);
    final store = RecordingVoiceStore(sessions, scope, audit: audit);
    final timers = ManualTimerFactory();
    final harness = VoiceHarness._(
      directory: directory,
      sessions: sessions,
      scope: scope,
      access: access,
      platform: platform,
      uploader: uploader,
      store: store,
      timers: timers,
      audit: audit,
      clockNow: now,
    );
    harness.controller = VoiceController(
      sessions: sessions,
      scope: scope,
      access: access,
      uploader: uploader,
      platform: platform,
      store: store,
      now: () => harness.clockNow,
      createTimer: timers.create,
    );
    return harness;
  }

  void dispose() {
    controller.dispose();
    platform.disposeSync();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}
