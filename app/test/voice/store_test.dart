import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/voice/features.dart';
import 'package:high_eq/features/voice/store.dart';
import 'synthetic.dart';

class MemorySecret implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String? next) async => value = next;
}

class _PausedIndexSessions extends Sessions {
  _PausedIndexSessions(super.secret, super.directory);

  bool _pauseNextRecordingIndexRead = false;
  Completer<void>? _recordingIndexReadPaused;
  Completer<void>? _recordingIndexReadRelease;
  bool _observeRecordingIndexWrite = false;
  Completer<void>? _recordingIndexWritten;

  Future<void> pauseNextRecordingIndexRead() {
    _pauseNextRecordingIndexRead = true;
    _recordingIndexReadPaused = Completer<void>();
    _recordingIndexReadRelease = Completer<void>();
    return _recordingIndexReadPaused!.future;
  }

  void releaseRecordingIndexRead() {
    _recordingIndexReadRelease?.complete();
  }

  Future<void> observeNextRecordingIndexWrite() {
    _observeRecordingIndexWrite = true;
    _recordingIndexWritten = Completer<void>();
    return _recordingIndexWritten!.future;
  }

  @override
  Future<List<int>?> get(AccountScope scope, CacheKind kind, String id) async {
    final value = await super.get(scope, kind, id);
    if (_pauseNextRecordingIndexRead &&
        kind == CacheKind.draft &&
        id == VoiceWindowStore.recordingIndexId) {
      _pauseNextRecordingIndexRead = false;
      _recordingIndexReadPaused!.complete();
      await _recordingIndexReadRelease!.future;
    }
    return value;
  }

  @override
  Future<void> put(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) async {
    await super.put(scope, kind, id, bytes);
    if (_observeRecordingIndexWrite &&
        kind == CacheKind.draft &&
        id == VoiceWindowStore.recordingIndexId) {
      _observeRecordingIndexWrite = false;
      _recordingIndexWritten!.complete();
    }
  }
}

Tokens tokens(String account) => Tokens(
  account,
  'access',
  'refresh',
  DateTime.now().toUtc().add(const Duration(hours: 1)),
);

List<File> recordingFiles(Directory directory) => directory
    .listSync()
    .whereType<File>()
    .where((file) => file.path.endsWith('.audio'))
    .toList();

VoiceWindow window(DateTime start) => VoiceWindow(
  startsAt: start,
  analysis: PcmAnalyzer().analyze(
    silence(duration: const Duration(seconds: 30)),
  ),
);

void main() {
  late Directory dir;
  late Sessions sessions;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('t29-store');
    sessions = Sessions(MemorySecret(), dir);
  });
  tearDown(() => dir.delete(recursive: true));

  test('queue is encrypted and clears before revoke sync', () async {
    final a = await sessions.activate(tokens('A'));
    final store = VoiceWindowStore(sessions, a);
    await store.enqueue(window(DateTime.utc(2026, 11, 21, 9, 0)));

    expect(await store.pending(), hasLength(1));
    for (final file in dir.listSync().whereType<File>()) {
      expect(latin1.decode(await file.readAsBytes()), isNot(contains('voice')));
    }

    await store.clearPending();
    expect(await store.pending(), isEmpty);
    expect(await store.voiceRevoked(), isFalse);
    await store.setVoiceRevoked(true);
    expect(await store.voiceRevoked(), isTrue);
  });

  test(
    'switching accounts invalidates the old scope and hides all data',
    () async {
      final a = await sessions.activate(tokens('A'));
      final storeA = VoiceWindowStore(sessions, a);
      await storeA.enqueue(window(DateTime.utc(2026, 11, 21, 9, 0)));
      await storeA.saveRecording(
        DateTime.utc(2026, 11, 21, 9, 0),
        syntheticSampleRateBytes(),
      );
      await storeA.setVoiceRevoked(true);

      final b = await sessions.activate(tokens('B'));
      final storeB = VoiceWindowStore(sessions, b);
      expect(await storeB.pending(), isEmpty);
      expect(await storeB.recordings(), isEmpty);
      expect(await storeB.voiceRevoked(), isFalse);
      await expectLater(storeA.pending(), throwsA(isA<SessionChanged>()));
      await expectLater(storeA.recordings(), throwsA(isA<SessionChanged>()));
      await expectLater(storeA.voiceRevoked(), throwsA(isA<SessionChanged>()));
    },
  );

  test('recordings expire after three days and are not readable', () async {
    final a = await sessions.activate(tokens('A'));
    final store = VoiceWindowStore(sessions, a);
    final start = DateTime.utc(2026, 11, 17, 9);
    await store.saveRecording(start, syntheticSampleRateBytes());
    expect(
      await store.recordings(
        now: start.add(const Duration(days: 2, hours: 23)),
      ),
      hasLength(1),
    );
    expect(
      await store.recordings(now: start.add(const Duration(days: 3))),
      isEmpty,
    );
    expect(await store.readRecording(store.recordingId(start)), isNull);
  });

  test(
    'expiry cleanup and save serialize across independent store instances',
    () async {
      await dir.delete(recursive: true);
      final gated = _PausedIndexSessions(MemorySecret(), dir);
      sessions = gated;
      await dir.create(recursive: true);
      final scope = await sessions.activate(tokens('A'));
      final expiredStart = DateTime.utc(2026, 11, 17, 9);
      final now = expiredStart.add(const Duration(days: 3));
      final freshStart = now.add(const Duration(seconds: 1));
      final expiredPcm = tone(
        duration: const Duration(seconds: 1),
        syllableHz: 3,
      );
      final freshPcm = tone(
        duration: const Duration(seconds: 1),
        syllableHz: 5,
      );
      final historyStore = VoiceWindowStore(sessions, scope);
      final janitorStore = VoiceWindowStore(sessions, scope);

      await historyStore.saveRecording(expiredStart, expiredPcm);
      final paused = gated.pauseNextRecordingIndexRead();
      final purge = janitorStore.purgeExpired(now: now);
      await paused;
      final staleIndexWrite = gated.observeNextRecordingIndexWrite();
      final save = historyStore.saveRecording(freshStart, freshPcm);

      await Future.any<void>([
        staleIndexWrite,
        Future<void>.delayed(const Duration(milliseconds: 20)),
      ]);
      gated.releaseRecordingIndexRead();
      await Future.wait([purge, save]);

      expect(
        await historyStore.recordings(now: now.add(const Duration(seconds: 1))),
        hasLength(1),
      );
      expect(
        await historyStore.readRecording(
          historyStore.recordingId(freshStart),
          now: now.add(const Duration(seconds: 1)),
        ),
        freshPcm,
      );
      expect(
        await historyStore.readRecording(
          historyStore.recordingId(expiredStart),
          now: now.add(const Duration(seconds: 1)),
        ),
        isNull,
      );
      expect(recordingFiles(dir), hasLength(1));
    },
  );

  test(
    'single-recording delete and save serialize across store instances',
    () async {
      await dir.delete(recursive: true);
      final gated = _PausedIndexSessions(MemorySecret(), dir);
      sessions = gated;
      await dir.create(recursive: true);
      final scope = await sessions.activate(tokens('A'));
      final oldStart = DateTime.utc(2026, 11, 17, 9);
      final freshStart = oldStart.add(const Duration(seconds: 30));
      final now = freshStart.add(const Duration(seconds: 1));
      final freshPcm = tone(
        duration: const Duration(seconds: 1),
        syllableHz: 5,
      );
      final historyStore = VoiceWindowStore(sessions, scope);
      final cleanupStore = VoiceWindowStore(sessions, scope);
      await historyStore.saveRecording(
        oldStart,
        tone(duration: const Duration(seconds: 1), syllableHz: 3),
      );

      final paused = gated.pauseNextRecordingIndexRead();
      final deletion = cleanupStore.deleteRecording(
        historyStore.recordingId(oldStart),
      );
      await paused;
      final staleIndexWrite = gated.observeNextRecordingIndexWrite();
      final save = historyStore.saveRecording(freshStart, freshPcm);
      await Future.any<void>([
        staleIndexWrite,
        Future<void>.delayed(const Duration(milliseconds: 20)),
      ]);
      gated.releaseRecordingIndexRead();
      await Future.wait([deletion, save]);

      expect(await historyStore.recordings(now: now), hasLength(1));
      expect(
        await historyStore.readRecording(
          historyStore.recordingId(freshStart),
          now: now,
        ),
        freshPcm,
      );
      expect(
        await historyStore.readRecording(
          historyStore.recordingId(oldStart),
          now: now,
        ),
        isNull,
      );
      expect(recordingFiles(dir), hasLength(1));
    },
  );

  test('clear-all and save serialize across store instances', () async {
    await dir.delete(recursive: true);
    final gated = _PausedIndexSessions(MemorySecret(), dir);
    sessions = gated;
    await dir.create(recursive: true);
    final scope = await sessions.activate(tokens('A'));
    final oldStart = DateTime.utc(2026, 11, 17, 9);
    final freshStart = oldStart.add(const Duration(seconds: 30));
    final now = freshStart.add(const Duration(seconds: 1));
    final freshPcm = tone(duration: const Duration(seconds: 1), syllableHz: 5);
    final historyStore = VoiceWindowStore(sessions, scope);
    final cleanupStore = VoiceWindowStore(sessions, scope);
    await historyStore.saveRecording(
      oldStart,
      tone(duration: const Duration(seconds: 1), syllableHz: 3),
    );

    final paused = gated.pauseNextRecordingIndexRead();
    final clear = cleanupStore.deleteAllRecordings();
    await paused;
    final staleIndexWrite = gated.observeNextRecordingIndexWrite();
    final save = historyStore.saveRecording(freshStart, freshPcm);
    await Future.any<void>([
      staleIndexWrite,
      Future<void>.delayed(const Duration(milliseconds: 20)),
    ]);
    gated.releaseRecordingIndexRead();
    await Future.wait([clear, save]);

    expect(await historyStore.recordings(now: now), hasLength(1));
    expect(
      await historyStore.readRecording(
        historyStore.recordingId(freshStart),
        now: now,
      ),
      freshPcm,
    );
    expect(
      await historyStore.readRecording(
        historyStore.recordingId(oldStart),
        now: now,
      ),
      isNull,
    );
    expect(recordingFiles(dir), hasLength(1));
  });
}

Uint8List syntheticSampleRateBytes() =>
    tone(duration: const Duration(seconds: 1), syllableHz: 4);
