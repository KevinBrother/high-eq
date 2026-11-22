import '../../core/consent.dart';
import '../../core/session.dart';
import 'access.dart';
import 'platform.dart';
import 'store.dart';

/// Confirmed effects of a voice revocation attempt.
///
/// A caller must not describe an effect as complete merely because it was
/// requested. The persisted markers stay in place until every required effect
/// has succeeded.
class VoiceCleanupResult {
  final bool markerPersisted;
  final bool queuesCleared;
  final bool recordingsCleared;
  final bool nativeStopped;
  final bool playbackStopped;
  final bool synced;
  final bool markerCleared;

  const VoiceCleanupResult({
    required this.markerPersisted,
    required this.queuesCleared,
    required this.recordingsCleared,
    required this.nativeStopped,
    required this.playbackStopped,
    required this.synced,
    required this.markerCleared,
  });

  bool get localCleared => queuesCleared && recordingsCleared;

  /// Local capture, playback, queued uploads and recordings are all confirmed
  /// closed. Remote consent may still be outstanding.
  bool get locallyClosed =>
      markerPersisted && localCleared && nativeStopped && playbackStopped;

  bool get complete => locallyClosed && synced && markerCleared;
}

class RetentionCleanupResult {
  final bool markerPersisted;
  final bool recordingsCleared;
  final bool playbackStopped;
  final bool synced;
  final bool markerCleared;

  const RetentionCleanupResult({
    required this.markerPersisted,
    required this.recordingsCleared,
    required this.playbackStopped,
    required this.synced,
    required this.markerCleared,
  });

  bool get localCleared => recordingsCleared && playbackStopped;

  bool get locallyClosed => markerPersisted && localCleared;

  bool get complete => locallyClosed && synced && markerCleared;
}

/// Owns the ordering and evidence collection for privacy cleanup. Controllers
/// map this result to UI state; they do not infer success from an attempted
/// platform call.
class VoiceCleanupCoordinator {
  final AccountScope scope;
  final VoiceAccess access;
  final VoiceCapturePlatform platform;
  final VoiceWindowStore store;

  const VoiceCleanupCoordinator({
    required this.scope,
    required this.access,
    required this.platform,
    required this.store,
  });

  Future<VoiceCleanupResult> revokeVoice({
    Future<void> Function()? awaitSettled,
  }) => _cleanVoice(awaitSettled: awaitSettled, syncConsent: true);

  /// Used after an upload is denied. The server has already rejected access, so
  /// stop and purge locally without issuing another consent write.
  Future<VoiceCleanupResult> discardForRevocation({
    Future<void> Function()? awaitSettled,
  }) => _cleanVoice(awaitSettled: awaitSettled, syncConsent: false);

  Future<VoiceCleanupResult> _cleanVoice({
    required bool syncConsent,
    Future<void> Function()? awaitSettled,
  }) async {
    var markerPersisted = false;
    try {
      await store.setVoiceRevoked(true);
      markerPersisted = true;
    } catch (_) {
      // Continue: the in-memory gate must still close.
    }

    var nativeStopped = true;
    try {
      await platform.stop();
    } catch (_) {
      nativeStopped = false;
    }

    var playbackStopped = true;
    try {
      await platform.stopPlayback();
    } catch (_) {
      playbackStopped = false;
    }

    if (awaitSettled != null) {
      try {
        await awaitSettled();
      } catch (_) {
        // A failed window commit is already closed; purge what remains.
      }
    }

    var queuesCleared = true;
    try {
      await store.clearPending();
    } catch (_) {
      queuesCleared = false;
    }

    var recordingsCleared = true;
    try {
      await store.deleteAllRecordings();
    } catch (_) {
      recordingsCleared = false;
    }

    // Re-persist after cleanup so a process interruption cannot expose a
    // previous marker-clearing attempt.
    try {
      await store.setVoiceRevoked(true);
      markerPersisted = true;
    } catch (_) {
      // Keep the value proven by the first write, if any.
    }

    var synced = false;
    if (syncConsent) {
      var retentionSynced = true;
      try {
        await access.setConsent(scope, CollectionPurpose.audioRetention, false);
      } catch (_) {
        retentionSynced = false;
      }
      var voiceSynced = true;
      try {
        await access.setConsent(scope, CollectionPurpose.voice, false);
      } catch (_) {
        voiceSynced = false;
      }
      synced = retentionSynced && voiceSynced;
    }

    var markerCleared = false;
    if (markerPersisted &&
        queuesCleared &&
        recordingsCleared &&
        nativeStopped &&
        playbackStopped &&
        synced) {
      try {
        await store.setVoiceRevoked(false);
        markerCleared = true;
      } catch (_) {
        // Leave the gate closed and let the controller offer a retry.
      }
    }

    return VoiceCleanupResult(
      markerPersisted: markerPersisted,
      queuesCleared: queuesCleared,
      recordingsCleared: recordingsCleared,
      nativeStopped: nativeStopped,
      playbackStopped: playbackStopped,
      synced: synced,
      markerCleared: markerCleared,
    );
  }

  Future<RetentionCleanupResult> revokeRetention() async {
    var markerPersisted = false;
    try {
      await store.setRetentionRevoked(true);
      markerPersisted = true;
    } catch (_) {
      // Continue closing playback and deleting anything accessible.
    }

    var playbackStopped = true;
    try {
      await platform.stopPlayback();
    } catch (_) {
      playbackStopped = false;
    }

    var recordingsCleared = true;
    try {
      await store.deleteAllRecordings();
    } catch (_) {
      recordingsCleared = false;
    }

    var synced = true;
    try {
      await access.setConsent(scope, CollectionPurpose.audioRetention, false);
    } catch (_) {
      synced = false;
    }

    var markerCleared = false;
    if (markerPersisted && recordingsCleared && playbackStopped && synced) {
      try {
        await store.setRetentionRevoked(false);
        markerCleared = true;
      } catch (_) {
        // Keep the fail-closed marker until the retry succeeds.
      }
    }

    return RetentionCleanupResult(
      markerPersisted: markerPersisted,
      recordingsCleared: recordingsCleared,
      playbackStopped: playbackStopped,
      synced: synced,
      markerCleared: markerCleared,
    );
  }
}
