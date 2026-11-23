import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/api.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/voice/controller.dart';
import 'package:high_eq/features/voice/features.dart';

import 'fakes.dart';
import 'synthetic.dart';

final aligned = DateTime.utc(2026, 11, 21, 9);

VoiceWindow silentWindow(DateTime startsAt) => VoiceWindow(
  startsAt: startsAt,
  analysis: const VoiceAnalysis(voicedSeconds: 0),
);

Future<void> emitAndSettle(VoiceHarness harness) async {
  harness.platform.emit(
    tone(duration: const Duration(seconds: 30), syllableHz: 4),
  );
  await pumpEventQueue();
  await harness.controller.settle();
  await pumpEventQueue();
}

Future<void> waitUntil(Future<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition was not reached before timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void expectStatisticsOnly(Object? value) {
  if (value is Map) {
    const forbidden = {
      'pcm',
      'audio',
      'raw_audio',
      'transcript',
      'samples',
      'per_second',
      'base64',
    };
    for (final entry in value.entries) {
      expect(forbidden, isNot(contains(entry.key)));
      expectStatisticsOnly(entry.value);
    }
    return;
  }
  expect(value, isNot(isA<Iterable>()));
  expect(value, anyOf(isA<String>(), isA<num>(), isA<bool>(), isNull));
  if (value is String) {
    expect(value.length, lessThan(128));
    expect(value, isNot(contains('pcm')));
    expect(value, isNot(contains('transcript')));
    expect(value, isNot(contains('base64')));
    expect(value, isNot(contains('data:audio')));
  }
}

void main() {
  late VoiceHarness harness;

  setUp(() async {
    harness = await VoiceHarness.create(clock: aligned);
  });

  tearDown(() => harness.dispose());

  test('cancelling the final gate never starts native capture', () async {
    await harness.controller.initialize();
    final gate = Completer<void>();
    harness.access.readGate = gate;
    final starting = harness.controller.start();
    await waitUntil(() async => harness.access.readCalls == 1);

    await harness.controller.stop();
    gate.complete();

    expect(await starting, isFalse);
    expect(harness.controller.isCapturing, isFalse);
    expect(harness.platform.startCalls, 0);
  });

  test('disposing during native start stops the late recorder', () async {
    await harness.controller.initialize();
    final gate = Completer<void>();
    harness.platform.startGate = gate;
    final starting = harness.controller.start();
    await waitUntil(() async => harness.platform.startCalls == 1);

    harness.controller.dispose();
    gate.complete();

    expect(await starting, isFalse);
    expect(harness.controller.isCapturing, isFalse);
    expect(harness.platform.stopCalls, greaterThanOrEqualTo(2));
  });

  test('reauthorization failure drops the window and stops capture', () async {
    await harness.controller.initialize();
    expect(await harness.controller.start(), isTrue);
    harness.access.readFailuresRemaining = 1;

    await emitAndSettle(harness);

    expect(harness.controller.isCapturing, isFalse);
    expect(await harness.store.pending(), isEmpty);
    expect(harness.uploader.uploaded, isEmpty);
    expect(harness.platform.stopCalls, greaterThan(0));
    expect(harness.controller.notice, contains('未入队'));
  });

  test(
    'only a strict 30-second statistics object reaches the uploader',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      expect(harness.controller.retentionConsent, isFalse);
      expect(harness.controller.retainAudio, isFalse);

      await emitAndSettle(harness);

      expect(harness.uploader.uploaded, hasLength(1));
      final uploaded = harness.uploader.uploaded.single;
      expect(uploaded.startsAt, aligned);
      expect(uploaded.analysis.voicedSeconds, greaterThan(20));
      expect(uploaded.analysis.speechRate, isNotNull);
      expectStatisticsOnly(uploaded.toWire());
      expect(uploaded.toWire().toString(), isNot(contains('pcm')));
      expect(uploaded.toWire().toString(), isNot(contains('transcript')));
      expect(await harness.store.pending(), isEmpty);
      expect(harness.controller.transcriptionAvailable, isFalse);
    },
  );

  test('a rejected malformed window does not block later windows', () async {
    await harness.controller.initialize();
    final later = aligned.add(const Duration(seconds: 30));
    await harness.store.enqueue(silentWindow(aligned));
    await harness.store.enqueue(silentWindow(later));
    harness.uploader.failureFor = (window) => window.startsAt == aligned
        ? const ApiFailure(400, 'invalid', 'invalid window', false)
        : null;

    expect(await harness.controller.uploadPending(), isTrue);

    expect(harness.uploader.uploaded.map((window) => window.startsAt), [later]);
    expect(await harness.store.pending(), isEmpty);
  });

  test('revoke persists the gate before stop and local purge', () async {
    await harness.controller.initialize();
    expect(await harness.controller.start(), isTrue);
    await harness.store.enqueue(silentWindow(aligned));
    await harness.store.saveRecording(
      aligned,
      tone(duration: const Duration(seconds: 1), syllableHz: 4),
    );
    harness.access.failVoiceRevocation = true;
    harness.audit.clear();

    expect(await harness.controller.revokeVoice(), isFalse);

    expect(harness.audit.take(6), [
      'store:voiceRevoked:true',
      'stop',
      'stopPlayback',
      'store:clearPending',
      'store:deleteAllRecordings',
      'store:voiceRevoked:true',
    ]);
    expect(await harness.store.pending(), isEmpty);
    expect(await harness.store.recordings(now: aligned), isEmpty);
    expect(await harness.store.voiceRevoked(), isTrue);
    expect(harness.controller.voiceRevocationPending, isTrue);
    expect(harness.controller.isCapturing, isFalse);
  });

  test(
    'failed revoke stays fail-closed and purges stale data on restart',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      harness.access.failVoiceRevocation = true;
      await harness.controller.revokeVoice();

      // Simulate a crash after the marker reached disk but before cleanup ended.
      await harness.store.enqueue(silentWindow(aligned));
      await harness.store.saveRecording(
        aligned,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );
      harness.controller.dispose();
      await harness.platform.dispose();

      final restarted = VoiceController(
        sessions: harness.sessions,
        scope: harness.scope,
        access: harness.access,
        uploader: harness.uploader,
        platform: harness.platform,
        store: harness.store,
        now: () => harness.clockNow,
        createTimer: harness.timers.create,
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();

      expect(restarted.voiceRevocationPending, isTrue);
      expect(restarted.voiceConsent, isFalse);
      expect(await harness.store.pending(), isEmpty);
      expect(await harness.store.recordings(now: aligned), isEmpty);
      expect(await restarted.uploadPending(), isFalse);
      expect(harness.uploader.uploaded, isEmpty);
    },
  );

  test(
    'membership expiry immediately stops and clears pending windows',
    () async {
      harness.access.retentionGranted = true;
      harness.access.expiry = aligned.add(const Duration(minutes: 30));
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      expect(harness.controller.retainAudio, isTrue);
      await harness.store.enqueue(silentWindow(aligned));

      harness.timers.latestActive.fire();
      await waitUntil(() async {
        final pending = await harness.store.pending();
        return !harness.controller.memberActive && pending.isEmpty;
      });

      expect(harness.controller.isCapturing, isFalse);
      expect(harness.controller.retainAudio, isFalse);
      expect(harness.platform.stopCalls, greaterThan(0));
      expect(harness.platform.stopPlaybackCalls, greaterThan(0));
      expect(harness.controller.pendingCount, 0);
    },
  );

  test(
    'startup purges a recording exactly at its three-day boundary',
    () async {
      final expired = aligned.subtract(const Duration(days: 3));
      await harness.store.saveRecording(
        expired,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );

      await harness.controller.initialize();

      expect(harness.controller.recordings, isEmpty);
      expect(
        await harness.store.readRecording(
          harness.store.recordingId(expired),
          now: aligned,
        ),
        isNull,
      );
    },
  );

  test(
    'account switch stops capture and invalidates the old store scope',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);

      await harness.sessions.activate(testTokens('B'));
      await waitUntil(() async => harness.platform.stopCalls > 0);

      expect(harness.controller.isCapturing, isFalse);
      expect(harness.controller.notice, contains('账号已切换'));
      await expectLater(
        harness.store.pending(),
        throwsA(isA<SessionChanged>()),
      );
    },
  );

  test(
    'account switch clears in-memory state and stops playback while idle',
    () async {
      final recordingId = harness.store.recordingId(aligned);
      await harness.store.saveRecording(
        aligned,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );
      harness.access.retentionGranted = true;
      harness.uploader.failure = StateError('simulated offline upload');
      await harness.controller.initialize();
      expect(harness.controller.recordings, hasLength(1));

      expect(await harness.controller.start(), isTrue);
      await emitAndSettle(harness);
      await harness.controller.stop();
      expect(harness.controller.latestAnalysis, isNotNull);
      expect(harness.controller.pendingCount, 1);
      expect(await harness.controller.playRecording(recordingId), isTrue);
      expect(harness.controller.playingRecordingId, recordingId);
      final playbackStops = harness.platform.stopPlaybackCalls;

      await harness.sessions.activate(testTokens('B'));
      await waitUntil(
        () async => harness.platform.stopPlaybackCalls > playbackStops,
      );

      expect(harness.controller.latestAnalysis, isNull);
      expect(harness.controller.levelDb, isNull);
      expect(harness.controller.recordings, isEmpty);
      expect(harness.controller.pendingCount, 0);
      expect(harness.controller.playingRecordingId, isNull);
      expect(harness.controller.voiceConsent, isFalse);
      expect(harness.controller.retentionConsent, isFalse);
      expect(harness.controller.retainAudio, isFalse);
      expect(harness.controller.memberActive, isFalse);
    },
  );

  test('playback rechecks membership before decrypting a recording', () async {
    harness.access.retentionGranted = true;
    await harness.controller.initialize();
    await harness.store.saveRecording(
      aligned,
      tone(duration: const Duration(seconds: 1), syllableHz: 4),
    );
    await harness.controller.refreshRecordings();
    final recordingId = harness.store.recordingId(aligned);
    harness.access.expiry = aligned.subtract(const Duration(seconds: 1));

    expect(await harness.controller.playRecording(recordingId), isFalse);
    expect(harness.store.readRecordingCalls, 0);
    expect(harness.platform.played, isEmpty);
    expect(harness.controller.memberActive, isFalse);
    expect(harness.controller.retainAudio, isFalse);
  });

  test('playback rechecks voice consent before decrypting', () async {
    harness.access.retentionGranted = true;
    await harness.controller.initialize();
    await harness.store.saveRecording(
      aligned,
      tone(duration: const Duration(seconds: 1), syllableHz: 4),
    );
    await harness.controller.refreshRecordings();
    final recordingId = harness.store.recordingId(aligned);
    harness.access.voiceGranted = false;

    expect(await harness.controller.playRecording(recordingId), isFalse);
    expect(harness.store.readRecordingCalls, 0);
    expect(harness.platform.played, isEmpty);
    expect(harness.controller.voiceConsent, isFalse);
    expect(harness.controller.retainAudio, isFalse);
  });

  test('playback rechecks audio-retention consent before decrypting', () async {
    harness.access.retentionGranted = true;
    await harness.controller.initialize();
    await harness.store.saveRecording(
      aligned,
      tone(duration: const Duration(seconds: 1), syllableHz: 4),
    );
    await harness.controller.refreshRecordings();
    final recordingId = harness.store.recordingId(aligned);
    harness.access.retentionGranted = false;

    expect(await harness.controller.playRecording(recordingId), isFalse);
    expect(harness.store.readRecordingCalls, 0);
    expect(harness.platform.played, isEmpty);
    expect(harness.controller.retentionConsent, isFalse);
    expect(harness.controller.retainAudio, isFalse);
  });
  test(
    '403 upload rejection stops native capture and playback immediately',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      harness.uploader.failure = const ApiFailure(
        403,
        'forbidden',
        'voice revoked',
        false,
      );

      await emitAndSettle(harness);

      expect(harness.controller.isCapturing, isFalse);
      expect(harness.controller.status, VoiceStatus.idle);
      expect(harness.platform.stopCalls, greaterThan(0));
      expect(harness.platform.stopPlaybackCalls, greaterThan(0));
      expect(await harness.store.pending(), isEmpty);
      expect(await harness.store.voiceRevoked(), isTrue);
    },
  );

  test(
    'revoke keeps the persisted gate when local queue cleanup fails',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      await harness.store.enqueue(silentWindow(aligned));
      harness.store.failClearPending = true;

      expect(await harness.controller.revokeVoice(), isFalse);

      expect(harness.controller.voiceRevocationPending, isTrue);
      expect(await harness.store.voiceRevoked(), isTrue);
      expect(await harness.controller.grantVoiceConsent(), isFalse);
    },
  );

  test(
    'retention deletion failure never claims recordings were deleted',
    () async {
      harness.access.retentionGranted = true;
      await harness.controller.initialize();
      await harness.store.saveRecording(
        aligned,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );
      await harness.controller.refreshRecordings();
      harness.store.failDeleteAllRecordings = true;

      await harness.controller.disableRetention();

      expect(harness.controller.notice, isNot(contains('已删除')));
      expect(harness.controller.retentionRevocationPending, isTrue);
      expect(await harness.store.retentionRevoked(), isTrue);
      expect(
        await harness.store.recordings(now: harness.clockNow),
        hasLength(1),
      );
    },
  );

  test(
    'retrying retention revocation deletes locally before clearing the gate',
    () async {
      harness.access.retentionGranted = true;
      await harness.controller.initialize();
      await harness.store.saveRecording(
        aligned,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );
      await harness.controller.refreshRecordings();
      harness.store.failDeleteAllRecordings = true;
      await harness.controller.disableRetention();
      final deletionsBefore = harness.store.events
          .where((event) => event == 'store:deleteAllRecordings')
          .length;
      harness.store.failDeleteAllRecordings = false;

      expect(await harness.controller.retryRetentionRevocation(), isTrue);

      final deletionsAfter = harness.store.events
          .where((event) => event == 'store:deleteAllRecordings')
          .length;
      expect(deletionsAfter, deletionsBefore + 1);
      expect(await harness.store.recordings(now: harness.clockNow), isEmpty);
      expect(await harness.store.retentionRevoked(), isFalse);
      expect(harness.controller.retentionRevocationPending, isFalse);
    },
  );

  test(
    'sample timestamps preserve a window when the last callback is delayed',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      final chunk = tone(
        duration: const Duration(milliseconds: 100),
        syllableHz: 4,
      );
      harness.clockNow = aligned.add(
        const Duration(seconds: 30, milliseconds: 1),
      );
      for (var index = 0; index < 300; index++) {
        harness.platform.emit(
          chunk,
          capturedAt: aligned.add(Duration(milliseconds: index * 100)),
        );
      }

      await pumpEventQueue();
      await harness.controller.settle();
      await pumpEventQueue();

      expect(harness.uploader.uploaded, hasLength(1));
      expect(harness.uploader.uploaded.single.startsAt, aligned);
    },
  );

  test('a native segment boundary discards the partial window', () async {
    await harness.controller.initialize();
    expect(await harness.controller.start(), isTrue);
    harness.platform.emit(
      tone(duration: const Duration(seconds: 15), syllableHz: 4),
      capturedAt: aligned,
    );
    final resume = aligned.add(const Duration(seconds: 15));
    harness.platform.emitEvent({
      'pcm': tone(duration: const Duration(seconds: 45), syllableHz: 4),
      'captured_at_us': resume.microsecondsSinceEpoch,
      'starts_new_segment': true,
    });

    await pumpEventQueue();
    await harness.controller.settle();
    await pumpEventQueue();

    expect(harness.uploader.uploaded.map((window) => window.startsAt), [
      aligned.add(const Duration(seconds: 30)),
    ]);
  });

  test(
    'native stop failure is reported without claiming capture stopped',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      harness.platform.stopFailuresRemaining = 1;

      await harness.controller.stop();

      expect(harness.controller.status, VoiceStatus.error);
      expect(harness.controller.notice, contains('系统录音停止未确认'));
      expect(harness.controller.notice, isNot(contains('语音采集已停止')));
    },
  );

  test('playback stop failure is not reported as confirmed', () async {
    harness.access.retentionGranted = true;
    await harness.controller.initialize();
    harness.platform.stopPlaybackFailuresRemaining = 1;

    await harness.controller.disableRetention();

    expect(harness.controller.notice, contains('回听停止未确认'));
    expect(harness.controller.notice, isNot(contains('回听已停止')));
  });

  test(
    'voice revocation reports failed recording deletion without false completion',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      await harness.store.saveRecording(
        aligned,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );
      harness.store.failDeleteAllRecordings = true;

      expect(await harness.controller.revokeVoice(), isFalse);

      expect(harness.controller.notice, contains('本机录音删除未确认'));
      expect(harness.controller.notice, isNot(contains('均已处理确认')));
      expect(harness.controller.notice, isNot(contains('已删除')));
      expect(harness.controller.voiceRevocationPending, isTrue);
    },
  );

  test('voice marker write failure keeps the in-memory gate closed', () async {
    await harness.controller.initialize();
    expect(await harness.controller.start(), isTrue);
    harness.store.failVoiceRevokedTrue = true;

    expect(await harness.controller.revokeVoice(), isFalse);

    expect(harness.controller.notice, contains('撤回标记未能持久化'));
    expect(harness.controller.voiceRevocationPending, isTrue);
    expect(harness.controller.isCapturing, isFalse);
    expect(await harness.controller.grantVoiceConsent(), isFalse);
  });

  test(
    'revocation before upload never marks or sends the queued window',
    () async {
      await harness.controller.initialize();
      expect(await harness.controller.start(), isTrue);
      harness.uploader.beforeGuard = () async {
        harness.access.voiceGranted = false;
      };

      await emitAndSettle(harness);

      expect(harness.uploader.events, isNot(contains('upload')));
      expect(harness.uploader.uploaded, isEmpty);
      expect(harness.platform.stopCalls, greaterThan(0));
      expect(await harness.store.pending(), isEmpty);
      expect(await harness.store.voiceRevoked(), isTrue);
      expect(harness.controller.notice, contains('撤回标记保留'));
    },
  );

  test('retention marker write failure keeps playback disabled', () async {
    harness.access.retentionGranted = true;
    await harness.controller.initialize();
    harness.store.failRetentionRevokedTrue = true;

    await harness.controller.disableRetention();

    expect(harness.controller.notice, contains('撤回标记未能持久化'));
    expect(harness.controller.retentionRevocationPending, isTrue);
    expect(harness.controller.retainAudio, isFalse);
  });

  test(
    'recording expires while the history stays open without user action',
    () async {
      harness.access.expiry = aligned.add(const Duration(days: 10));
      harness.access.retentionGranted = true;
      await harness.controller.initialize();
      await harness.store.saveRecording(
        aligned,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );
      await harness.controller.refreshRecordings();
      expect(harness.controller.recordings, hasLength(1));

      final expiryTimers = harness.timers.activeFor(const Duration(days: 3));
      expect(expiryTimers, hasLength(1));
      harness.clockNow = aligned.add(const Duration(days: 3));
      expiryTimers.single.fire();

      await waitUntil(() async {
        final stored = await harness.store.recordings(now: harness.clockNow);
        return stored.isEmpty && harness.controller.recordings.isEmpty;
      });
      expect(
        await harness.store.readRecording(
          harness.store.recordingId(aligned),
          now: harness.clockNow,
        ),
        isNull,
      );
    },
  );
}
