import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:high_eq/core/session.dart';
import 'package:high_eq/features/voice/controller.dart';
import 'package:high_eq/features/voice/retention_janitor.dart';
import 'package:high_eq/features/voice/store.dart';

import 'fakes.dart';
import 'synthetic.dart';

class _CaptureTimers {
  final List<ManualTimer> timers = [];

  Timer create(Duration duration, void Function() callback) {
    final timer = ManualTimer(duration, callback);
    timers.add(timer);
    return timer;
  }
}

void main() {
  test(
    'purges expired recordings after the voice controller is disposed',
    () async {
      final directory = await Directory.systemTemp.createTemp('t29-janitor');
      addTearDown(() => directory.delete(recursive: true));
      final sessions = Sessions(MemorySecret(), directory);
      final scope = await sessions.activate(testTokens('A'));
      final now = DateTime.utc(2026, 11, 21, 9);
      var clock = now;
      final store = VoiceWindowStore(sessions, scope);
      await store.saveRecording(
        now,
        tone(duration: const Duration(seconds: 1), syllableHz: 4),
      );

      final access = FakeVoiceAccess(retentionGranted: true);
      final platform = FakeVoiceCapture();
      final controller = VoiceController(
        sessions: sessions,
        scope: scope,
        access: access,
        uploader: FakeVoiceUploader(),
        platform: platform,
        store: store,
        now: () => clock,
      );
      controller.dispose();
      platform.disposeSync();

      final timers = _CaptureTimers();
      final janitor = VoiceRetentionJanitor(
        sessions: sessions,
        now: () => clock,
        createTimer: timers.create,
      );
      addTearDown(janitor.dispose);
      clock = now.add(const Duration(days: 3));

      await janitor.purgeNow();

      expect(
        await sessions.get(
          scope,
          CacheKind.draft,
          VoiceWindowStore.recordingIndexId,
        ),
        isNull,
      );
      expect(
        await store.readRecording(store.recordingId(now), now: clock),
        isNull,
      );
      expect(timers.timers, isNotEmpty);
    },
  );
}
