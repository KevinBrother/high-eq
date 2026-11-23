import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/api.dart';
import '../../core/consent.dart';
import '../../core/session.dart';
import 'access.dart';
import 'aggregator.dart';
import 'cleanup.dart';
import 'features.dart';
import 'platform.dart';
import 'store.dart';

enum VoiceStatus { idle, starting, listening, stopping, error }

/// Coordinates explicit consent, native capture, local analysis, encrypted
/// queues and recording retention. It never looks up a different active
/// account and never sends PCM through the uploader.
class VoiceController extends ChangeNotifier {
  final Sessions sessions;
  final AccountScope scope;
  final VoiceAccess access;
  final VoiceUploader uploader;
  final VoiceCapturePlatform platform;
  final VoiceWindowStore store;
  final DateTime Function() now;
  final PcmAnalyzer analyzer;
  final Timer Function(Duration, void Function()) createTimer;

  VoiceStatus _status = VoiceStatus.idle;
  bool _initialized = false;
  bool _disposed = false;
  bool _capturing = false;
  bool _voiceConsent = false;
  bool _retentionConsent = false;
  bool _memberActive = false;
  bool _retainAudio = false;
  bool _voiceRevocationPending = false;
  bool _retentionRevocationPending = false;
  bool _uploading = false;
  DateTime? _membershipExpiry;
  String? _notice;
  String? _playingRecordingId;
  DateTime? _captureStartedAt;
  DateTime? _lastLevelNotify;
  double? _levelDb;
  VoiceAnalysis? _latestAnalysis;
  List<VoiceRecording> _recordings = const [];
  int _pendingCount = 0;
  int _startGeneration = 0;

  StreamSubscription<VoicePcmChunk>? _pcmSubscription;
  Timer? _membershipTimer;
  Timer? _recordingExpiryTimer;
  VoiceWindowAggregator? _aggregator;
  Future<void> _windowTail = Future.value();
  late final VoiceCleanupCoordinator _cleanup;

  VoiceController({
    required this.sessions,
    required this.scope,
    required this.access,
    required this.uploader,
    required this.platform,
    required this.store,
    DateTime Function()? now,
    PcmAnalyzer? analyzer,
    Timer Function(Duration, void Function())? createTimer,
  }) : now = now ?? DateTime.now,
       analyzer = analyzer ?? const PcmAnalyzer(),
       createTimer = createTimer ?? Timer.new {
    _cleanup = VoiceCleanupCoordinator(
      scope: scope,
      access: access,
      platform: platform,
      store: store,
    );
  }

  VoiceStatus get status => _status;
  bool get initialized => _initialized;
  bool get isCapturing => _capturing;
  bool get voiceConsent => _voiceConsent;
  bool get retentionConsent => _retentionConsent;
  bool get memberActive => _memberActive;
  bool get retainAudio => _retainAudio;
  bool get voiceRevocationPending => _voiceRevocationPending;
  bool get retentionRevocationPending => _retentionRevocationPending;
  bool get uploading => _uploading;
  DateTime? get membershipExpiry => _membershipExpiry;
  String? get notice => _notice;
  String? get playingRecordingId => _playingRecordingId;
  DateTime? get captureStartedAt => _captureStartedAt;
  double? get levelDb => _levelDb;
  VoiceAnalysis? get latestAnalysis => _latestAnalysis;
  List<VoiceRecording> get recordings => List.unmodifiable(_recordings);
  int get pendingCount => _pendingCount;

  bool get transcriptionAvailable => false;
  String get transcriptionLabel => '转写不可用';
  String get speechRateLabel => '声学音节速率代理';

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    sessions.identity.addListener(_onIdentityChanged);
    await _refreshStorage();
    try {
      _voiceConsent = await access.hasConsent(scope, CollectionPurpose.voice);
      _retentionConsent = await access.hasConsent(
        scope,
        CollectionPurpose.audioRetention,
      );
      _applyMembershipExpiry(await access.memberExpiry(scope));
      _voiceRevocationPending = await store.voiceRevoked();
      _retentionRevocationPending = await store.retentionRevoked();
      if (_voiceRevocationPending) {
        _voiceConsent = false;
        _retentionConsent = false;
        _retainAudio = false;
        _notice = '上次语音撤回尚未同步到服务端。本机不会恢复采集或补传旧窗口。';
        try {
          // The marker may have reached disk just before a crash interrupted
          // queue cleanup. Finish that local purge before exposing the page.
          await store.clearPending();
          await store.deleteAllRecordings();
          _pendingCount = 0;
          _recordings = const [];
        } catch (_) {
          _notice = '上次撤回的本机队列或录音尚未清理完成；采集与补传保持关闭。';
        }
      } else if (_retentionRevocationPending) {
        _retainAudio = false;
        _notice = '上次录音保留撤回尚未同步到服务端。本机录音已不可用。';
        try {
          await store.deleteAllRecordings();
          _recordings = const [];
        } catch (_) {
          _notice = '上次录音保留撤回的本地清理尚未完成；回听保持关闭。';
        }
      } else {
        _retainAudio = _voiceConsent && _retentionConsent && _memberActive;
      }
      _pcmSubscription = platform.pcm.listen(
        _onPcm,
        onError: (_) => unawaited(_platformFailed()),
        onDone: () {
          if (_capturing) unawaited(_platformFailed());
        },
      );
      _scheduleRecordingExpiry();
      _notify();
    } catch (_) {
      _status = VoiceStatus.error;
      _voiceConsent = false;
      _retainAudio = false;
      _notice = '无法确认语音授权或会员状态，采集保持关闭。';
      _notify();
    }
  }

  Future<void> _refreshStorage() async {
    try {
      await store.purgeExpired(now: now());
      _recordings = await store.recordings(now: now());
      _pendingCount = await store.pendingCount();
      _scheduleRecordingExpiry();
      _notify();
    } on SessionChanged {
      _recordingExpiryTimer?.cancel();
      _recordingExpiryTimer = null;
      _status = VoiceStatus.error;
      _notice = '账号已切换，本页的语音数据已失效。';
      _notify();
    }
  }

  Future<bool> grantVoiceConsent() async {
    if (_voiceRevocationPending) {
      _notice = '请先重试完成上次撤回，再重新开启语音。';
      _notify();
      return false;
    }
    try {
      await access.setConsent(scope, CollectionPurpose.voice, true);
      await store.setVoiceRevoked(false);
      _voiceConsent = true;
      _notice = '语音授权已记录。下一步只检查系统麦克风权限。';
      _notify();
      return true;
    } catch (_) {
      _notice = '语音授权未保存，采集不会开启。';
      _notify();
      return false;
    }
  }

  Future<bool> start() async {
    if (_disposed) return false;
    if (_capturing) return true;
    if (_status == VoiceStatus.starting) return false;
    if (_voiceRevocationPending) {
      _notice = '撤回尚未同步，不能重新开启语音。';
      _notify();
      return false;
    }
    final generation = ++_startGeneration;
    bool stillCurrent() =>
        !_disposed &&
        generation == _startGeneration &&
        _status == VoiceStatus.starting &&
        identical(sessions.identity.value, scope);

    _status = VoiceStatus.starting;
    _notice = '正在重新检查会员、授权和系统权限…';
    _notify();
    try {
      _voiceConsent = await access.hasConsent(scope, CollectionPurpose.voice);
      if (!stillCurrent()) return false;
      if (!_voiceConsent) {
        _status = VoiceStatus.idle;
        _notice = '尚未同意语音特征采集。';
        _notify();
        return false;
      }
      _applyMembershipExpiry(await access.memberExpiry(scope));
      if (!stillCurrent()) return false;
      _retentionConsent = await access.hasConsent(
        scope,
        CollectionPurpose.audioRetention,
      );
      if (!stillCurrent()) return false;
      if (!_memberActive) {
        _status = VoiceStatus.idle;
        _retainAudio = false;
        _notice = '语音特征仅对有效会员开放，采集未开启。';
        _notify();
        return false;
      }
      _retainAudio =
          _voiceConsent &&
          _retentionConsent &&
          _memberActive &&
          !_retentionRevocationPending;
      if (!await platform.checkPermission()) {
        if (!stillCurrent()) return false;
        if (!await platform.requestPermission()) {
          if (!stillCurrent()) return false;
          _status = VoiceStatus.idle;
          _notice = '未获得系统麦克风权限，语音采集保持关闭。';
          _notify();
          return false;
        }
      }
      if (!stillCurrent()) return false;

      var beginRead = false;
      final allowed = await access.readIfAllowed(
        scope,
        CollectionPurpose.voice,
        systemGranted: platform.checkPermission,
        beginRead: () {
          if (stillCurrent()) beginRead = true;
        },
      );
      if (!stillCurrent()) return false;
      if (!allowed || !beginRead) {
        _status = VoiceStatus.idle;
        _voiceConsent = await _safeVoiceConsent();
        if (!stillCurrent()) return false;
        _notice = '授权、会员或网络状态无法确认，采集保持关闭。';
        _notify();
        return false;
      }

      _aggregator = VoiceWindowAggregator(
        onWindow: _queueCapture,
        analyzer: analyzer,
      );
      await platform.start();
      if (!stillCurrent()) {
        // stop() may have run while the native start call was in flight. A
        // second stop closes the recorder that returned after that teardown.
        try {
          await platform.stop();
        } catch (_) {
          // The controller remains fail-closed even if native cleanup fails.
        }
        return false;
      }
      _capturing = true;
      _captureStartedAt = now();
      _levelDb = null;
      _status = VoiceStatus.listening;
      _notice = _retainAudio ? '正在本地分析语音，并加密保存整段录音。' : '正在本地分析语音，不保存原始录音。';
      _notify();
      return true;
    } catch (_) {
      // If the native side partially started before throwing, make a best
      // effort to release its recorder before leaving the page closed.
      try {
        await platform.stop();
      } catch (_) {
        // The privacy state remains closed even when native cleanup fails.
      }
      if (!stillCurrent()) return false;
      _aggregator = null;
      _capturing = false;
      _captureStartedAt = null;
      _status = VoiceStatus.error;
      _notice = '无法开始语音采集。请检查系统权限或稍后重试。';
      _notify();
      return false;
    }
  }

  void _onIdentityChanged() {
    if (_disposed || identical(sessions.identity.value, scope)) return;
    final shouldStopCapture = _capturing || _status == VoiceStatus.starting;
    _startGeneration++;

    _membershipTimer?.cancel();
    _membershipTimer = null;
    _recordingExpiryTimer?.cancel();
    _recordingExpiryTimer = null;
    _membershipExpiry = null;
    _memberActive = false;
    _voiceConsent = false;
    _retentionConsent = false;
    _retainAudio = false;
    _voiceRevocationPending = false;
    _retentionRevocationPending = false;
    _uploading = false;
    _capturing = false;
    _captureStartedAt = null;
    _lastLevelNotify = null;
    _levelDb = null;
    _latestAnalysis = null;
    _recordings = const [];
    _pendingCount = 0;
    _playingRecordingId = null;
    _aggregator?.stop();
    _aggregator = null;
    _status = VoiceStatus.error;
    _notice = '账号已切换，旧账号的语音状态、回听和本地数据访问均已失效。';
    _notify();

    if (shouldStopCapture) {
      unawaited(platform.stop().catchError((_) {}));
    }
    unawaited(platform.stopPlayback().catchError((_) {}));
  }

  Future<bool> _playbackAllowed() async {
    try {
      final voiceGranted = await access.hasConsent(
        scope,
        CollectionPurpose.voice,
      );
      final retentionGranted = await access.hasConsent(
        scope,
        CollectionPurpose.audioRetention,
      );
      _applyMembershipExpiry(await access.memberExpiry(scope));
      _voiceConsent = voiceGranted;
      _retentionConsent = retentionGranted;
      final allowed =
          voiceGranted &&
          retentionGranted &&
          _memberActive &&
          !_voiceRevocationPending &&
          !_retentionRevocationPending;
      _retainAudio = allowed;
      return allowed;
    } catch (_) {
      _voiceConsent = false;
      _retentionConsent = false;
      _retainAudio = false;
      _memberActive = false;
      return false;
    }
  }

  Future<bool> _safeVoiceConsent() async {
    try {
      return await access.hasConsent(scope, CollectionPurpose.voice);
    } catch (_) {
      return false;
    }
  }

  void _applyMembershipExpiry(DateTime? expiry) {
    _membershipTimer?.cancel();
    _membershipExpiry = expiry?.toUtc();
    _memberActive =
        _membershipExpiry != null && _membershipExpiry!.isAfter(now().toUtc());
    if (!_memberActive) return;
    _membershipTimer = createTimer(
      _membershipExpiry!.difference(now().toUtc()),
      () => unawaited(_membershipExpired()),
    );
  }

  Future<void> _membershipExpired() async {
    if (_disposed || !_memberActive) return;
    _startGeneration++;
    _memberActive = false;
    _retainAudio = false;
    _aggregator?.setRetention(false);
    _capturing = false;
    _captureStartedAt = null;
    _levelDb = null;
    _aggregator?.stop();
    _aggregator = null;
    try {
      await platform.stop();
    } catch (_) {
      // Local membership gating remains closed even if native teardown fails.
    }
    await stopPlayback();
    try {
      await store.clearPending();
      _pendingCount = 0;
    } catch (_) {
      // The controller will refuse uploads while membership remains inactive.
    }
    _status = VoiceStatus.idle;
    _notice = '会员已到期，语音采集已立即停止；未上传窗口已清除，续费后不会补传。';
    _notify();
  }

  Future<void> stop() async {
    if (!_capturing && _status != VoiceStatus.starting) return;
    _startGeneration++;
    _capturing = false;
    _status = VoiceStatus.stopping;
    _aggregator?.stop();
    _aggregator = null;
    _captureStartedAt = null;
    _levelDb = null;
    _notify();
    try {
      await platform.stop();
      _status = VoiceStatus.idle;
      _notice = '语音采集已停止。';
    } catch (_) {
      _status = VoiceStatus.error;
      _notice = '系统录音停止未确认；本页已禁止继续采集，请返回后重新打开。';
    }
    _notify();
  }

  Future<bool> enableRetention() async {
    if (!_voiceConsent || !_memberActive || _retentionRevocationPending) {
      _notice = '请先开启有效的会员语音特征采集，再单独同意录音保留。';
      _notify();
      return false;
    }
    if (!await platform.checkPermission()) {
      _notice = '系统麦克风权限不可用，不能开启录音保留。';
      _notify();
      return false;
    }
    try {
      await access.setConsent(scope, CollectionPurpose.audioRetention, true);
      final allowed = await access.readIfAllowed(
        scope,
        CollectionPurpose.audioRetention,
        systemGranted: platform.checkPermission,
        beginRead: () {},
      );
      if (!allowed) {
        // A failed re-check must remain fail-closed across process restarts.
        // Local recordings must also be gone before the marker can be cleared.
        final outcome = await _revokeRetentionFailClosed();
        _notice = outcome.recordingsCleared
            ? '录音保留授权未生效；语音特征分析不受影响。'
            : '录音保留授权未生效，本机录音删除未完成；回听保持关闭。';
        _notify();
        return false;
      }
      await store.setRetentionRevoked(false);
      _retentionConsent = true;
      _retainAudio = true;
      _notice = '录音保留已开启。只保存完整 30 秒窗口，本机加密 3 天。';
      _notify();
      return true;
    } catch (_) {
      final outcome = await _revokeRetentionFailClosed();
      _notice = outcome.recordingsCleared
          ? '录音保留未开启；语音特征分析仍可继续。'
          : '录音保留未开启，本机录音删除未完成；回听保持关闭。';
      _notify();
      return false;
    }
  }

  Future<void> disableRetention() async {
    final outcome = await _revokeRetentionFailClosed();
    if (!outcome.markerPersisted) {
      _notice = '录音保留已关闭，但撤回标记未能持久化；请重试。';
    } else if (!outcome.playbackStopped) {
      _notice = '录音保留已关闭，但回听停止未确认；请重试。';
    } else if (!outcome.recordingsCleared) {
      _notice = '录音保留已关闭，但本机录音删除未完成；回听保持关闭，请重试。';
    } else if (!outcome.synced) {
      _notice = '录音保留已关闭，本机录音已删除；服务端撤回尚未同步。';
    } else if (!outcome.markerCleared) {
      _notice = '录音保留已关闭，本机录音已删除；撤回标记清理失败，请重试。';
    } else {
      _notice = '录音保留已关闭，本机录音已删除，服务端授权已撤回。';
    }
    _notify();
  }

  Future<bool> retryRetentionRevocation() async {
    final outcome = await _revokeRetentionFailClosed();
    if (!outcome.markerPersisted) {
      _notice = '仍未完成录音保留撤回：撤回标记未能持久化，本机录音不会恢复。';
    } else if (!outcome.playbackStopped) {
      _notice = '仍未完成录音保留撤回：回听停止未确认，本机录音不会恢复。';
    } else if (!outcome.recordingsCleared) {
      _notice = '仍未完成录音保留撤回：本机录音删除失败，回听保持关闭。';
    } else if (!outcome.synced) {
      _notice = '仍未同步录音保留撤回；本机录音已删除，不会恢复。';
    } else if (!outcome.markerCleared) {
      _notice = '录音保留撤回已同步，但本机撤回标记清理失败；请重试。';
    } else {
      _notice = '录音保留撤回已同步。';
    }
    _notify();
    return outcome.complete;
  }

  Future<bool> revokeVoice() async {
    _beginVoiceCleanup(VoiceStatus.stopping);
    _notify();
    final outcome = await _cleanup.revokeVoice(awaitSettled: () => _windowTail);
    _applyVoiceCleanup(outcome);
    _notify();
    return outcome.complete;
  }

  Future<bool> retryVoiceRevocation() async {
    _beginVoiceCleanup(VoiceStatus.stopping);
    _notify();
    final outcome = await _cleanup.revokeVoice(awaitSettled: () => _windowTail);
    _applyVoiceCleanup(outcome, retrying: true);
    _notify();
    return outcome.complete;
  }

  void _beginVoiceCleanup(VoiceStatus status) {
    _startGeneration++;
    _voiceRevocationPending = true;
    _voiceConsent = false;
    _retentionConsent = false;
    _retainAudio = false;
    _capturing = false;
    _status = status;
    _captureStartedAt = null;
    _levelDb = null;
    _playingRecordingId = null;
    _aggregator?.stop();
    _aggregator = null;
  }

  void _applyVoiceCleanup(
    VoiceCleanupResult outcome, {
    bool retrying = false,
    bool serverRejected = false,
  }) {
    _voiceConsent = false;
    _retentionConsent = false;
    _retainAudio = false;
    _capturing = false;
    _captureStartedAt = null;
    _levelDb = null;
    _playingRecordingId = null;
    _aggregator?.stop();
    _aggregator = null;
    if (outcome.queuesCleared) _pendingCount = 0;
    if (outcome.recordingsCleared) _recordings = const [];
    _voiceRevocationPending = !outcome.markerCleared;
    _status = outcome.nativeStopped ? VoiceStatus.idle : VoiceStatus.error;

    final String detail;
    if (!outcome.markerPersisted) {
      detail = '撤回标记未能持久化；本机仍禁止采集和补传，请重试。';
    } else if (!outcome.nativeStopped) {
      detail = '系统录音停止未确认；本机已禁止继续采集和补传，请重试。';
    } else if (!outcome.playbackStopped) {
      detail = '系统录音已停止，但回听停止未确认；本机仍禁止补传。';
    } else if (!outcome.queuesCleared) {
      detail = '系统录音和回听已停止，但待发窗口清理未确认；不会恢复补传。';
    } else if (!outcome.recordingsCleared) {
      detail = '系统录音、回听和待发窗口已处理，但本机录音删除未确认；回听保持关闭。';
    } else if (serverRejected) {
      detail = '系统录音、回听、待发窗口和本机录音均已处理确认；撤回标记保留，不会补传。';
    } else if (!outcome.synced) {
      detail = '系统录音、回听和本机数据已处理确认；服务端撤回尚未同步。';
    } else if (!outcome.markerCleared) {
      detail = '服务端撤回已同步，但本机撤回标记清理失败；请重试。';
    } else {
      detail = '语音授权已撤回，采集、回听、待发窗口和本机录音均已处理确认。';
    }
    _notice = retrying
        ? (outcome.complete ? '语音撤回重试已完成。' : '撤回重试仍未完成：$detail')
        : (serverRejected ? '授权或会员状态已失效；$detail' : detail);
  }

  void _onPcm(VoicePcmChunk chunk) {
    if (!_capturing || _aggregator == null || chunk.pcm.isEmpty) return;
    try {
      final levelAt = now();
      final level = PcmAnalyzer.level(chunk.pcm);
      _levelDb = level;
      _aggregator!.add(
        chunk.pcm,
        chunk.capturedAt,
        retainAudio: _retainAudio,
        startsNewSegment: chunk.startsNewSegment,
      );
      if (_lastLevelNotify == null ||
          levelAt.difference(_lastLevelNotify!) >=
              const Duration(milliseconds: 120)) {
        _lastLevelNotify = levelAt;
        _notify();
      }
    } catch (_) {
      unawaited(_platformFailed());
    }
  }

  void _queueCapture(VoiceWindowCapture capture) {
    _windowTail = _windowTail.then((_) => _commitCapture(capture)).catchError((
      Object _,
    ) {
      _notice = '本机聚合遇到问题，未上传不完整窗口。';
      _notify();
    });
  }

  Future<void> _commitCapture(VoiceWindowCapture capture) async {
    if (!_capturing) return;
    try {
      final allowed = await access.readIfAllowed(
        scope,
        CollectionPurpose.voice,
        systemGranted: platform.checkPermission,
        beginRead: () {},
      );
      if (!allowed || !_capturing) {
        await stop();
        _notice = '采集授权无法继续确认，已停止且本窗口未入队。';
        _notify();
        return;
      }

      await store.enqueue(capture.window);
      _latestAnalysis = capture.window.analysis;
      _pendingCount = await store.pendingCount();
      _notify();

      if (capture.retained && _retainAudio) {
        final retentionAllowed = await access.readIfAllowed(
          scope,
          CollectionPurpose.audioRetention,
          systemGranted: platform.checkPermission,
          beginRead: () {},
        );
        if (retentionAllowed && _retainAudio) {
          await store.saveRecording(capture.window.startsAt, capture.pcm);
          _recordings = await store.recordings(now: now());
          _scheduleRecordingExpiry();
        } else {
          final outcome = await _revokeRetentionFailClosed();
          _notice = outcome.localCleared
              ? '录音保留授权已失效；统计窗口仍可继续，本窗口不保存录音。'
              : '录音保留授权已失效；本机旧录音删除未完成，回听保持关闭。';
        }
      }
      await uploadPending();
    } on SessionChanged {
      _capturing = false;
      _status = VoiceStatus.error;
      _notice = '账号已切换，当前窗口已丢弃。';
      _notify();
    } catch (_) {
      _notice = '本窗口未完成入队或上传，请稍后重试。';
      _notify();
    }
  }

  Future<bool> uploadPending() async {
    if (_uploading || _voiceRevocationPending || !_voiceConsent) return false;
    try {
      final queued = await store.pending();
      _pendingCount = queued.length;
      if (queued.isEmpty) {
        _notify();
        return true;
      }
      final allowed = await access.readIfAllowed(
        scope,
        CollectionPurpose.voice,
        systemGranted: platform.checkPermission,
        beginRead: () {},
      );
      if (!allowed) {
        _notice = '无法确认语音授权，待发窗口暂不上传。';
        _notify();
        return false;
      }

      _uploading = true;
      _notify();
      var discardedWindow = false;
      while (true) {
        if (_voiceRevocationPending) break;
        final pending = await store.pending();
        if (pending.isEmpty) break;
        final window = pending.first;

        // Consent, membership and the account can change while a queue is
        // draining. Re-check before every window, not just once per batch.
        final allowedNow = await access.readIfAllowed(
          scope,
          CollectionPurpose.voice,
          systemGranted: platform.checkPermission,
          beginRead: () {},
        );
        if (!allowedNow || _voiceRevocationPending) {
          await _stopAndDiscardForRevocation();
          return false;
        }

        try {
          if (_voiceRevocationPending) break;
          await uploader.upload(
            scope,
            window,
            beforeSend: () async {
              final allowedAtSend = await access.readIfAllowed(
                scope,
                CollectionPurpose.voice,
                systemGranted: platform.checkPermission,
                beginRead: () {},
              );
              final membershipCurrent =
                  _memberActive &&
                  (_membershipExpiry?.isAfter(now().toUtc()) ?? false);
              if (!allowedAtSend ||
                  _voiceRevocationPending ||
                  !_voiceConsent ||
                  !membershipCurrent) {
                throw const ApiFailure(403, 'voice_revoked', '语音授权已失效', false);
              }
            },
          );
          await store.removePending(window.startsAt);
        } on ApiFailure catch (error) {
          if (error.status == 400 || error.status == 422) {
            // A deterministic validation rejection can never become valid by
            // retrying. Discard it so it cannot poison the queue head.
            await store.removePending(window.startsAt);
            _notice = '服务端拒绝了不合法窗口，已丢弃并继续后续窗口。';
            discardedWindow = true;
            continue;
          }
          if (error.status == 409) {
            // The UTC key already exists. Keeping a conflicting body would
            // retry forever, so it is discarded rather than mutated.
            await store.removePending(window.startsAt);
            _notice = '服务端已有同时间窗口，冲突窗口未重复上传。';
            discardedWindow = true;
            continue;
          }
          if (error.status == 403) {
            await _stopAndDiscardForRevocation();
            return false;
          }
          rethrow;
        }
      }
      _pendingCount = 0;
      if (!discardedWindow) _notice = '语音统计窗口已上传。';
      _notify();
      return true;
    } on SessionChanged {
      _notice = '账号已切换，不能上传旧账号窗口。';
      _notify();
      return false;
    } catch (_) {
      _notice = '网络暂不可用，统计窗口仍在本机加密队列中。';
      _notify();
      return false;
    } finally {
      _uploading = false;
      try {
        _pendingCount = await store.pendingCount();
      } on Object {
        _pendingCount = 0;
      }
      _notify();
    }
  }

  Future<void> _stopAndDiscardForRevocation() async {
    _beginVoiceCleanup(VoiceStatus.idle);
    _notify();
    // This helper can run from inside the window-tail commit that is currently
    // uploading. Do not await that same tail here; stop future commits with
    // `_capturing = false` and clear everything already queued.
    final outcome = await _cleanup.discardForRevocation();
    _applyVoiceCleanup(outcome, serverRejected: true);
    _notify();
  }

  Future<RetentionCleanupResult> _revokeRetentionFailClosed() async {
    _retentionConsent = false;
    _retainAudio = false;
    _retentionRevocationPending = true;
    _playingRecordingId = null;
    _aggregator?.setRetention(false);
    final outcome = await _cleanup.revokeRetention();
    if (outcome.recordingsCleared) _recordings = const [];
    _retentionRevocationPending = !outcome.markerCleared;
    return outcome;
  }

  Future<void> _platformFailed() async {
    if (!_capturing) return;
    _capturing = false;
    _aggregator?.stop();
    _aggregator = null;
    _captureStartedAt = null;
    _status = VoiceStatus.error;
    _notice = '语音采集流已中断，未完成窗口已丢弃。';
    _notify();
    try {
      await platform.stop();
    } catch (_) {
      // Native cleanup is best effort after a stream failure.
    }
  }

  Future<bool> playRecording(String id) async {
    if (_capturing) {
      _notice = '回听会混入麦克风，请先停止语音采集。';
      _notify();
      return false;
    }
    await stopPlayback();
    if (!await _playbackAllowed()) {
      _notice = '会员、语音授权或录音保留授权无法确认，本机录音不可回听。';
      _notify();
      return false;
    }
    try {
      final pcm = await store.readRecording(id, now: now());
      if (pcm == null || pcm.isEmpty) {
        await refreshRecordings();
        _notice = '这段录音已超过 3 天或已被删除，不能回听。';
        _notify();
        return false;
      }
      await platform.playPcm(pcm);
      _playingRecordingId = id;
      _notice = '正在从本机加密存储临时回听。';
      _notify();
      return true;
    } catch (_) {
      _playingRecordingId = null;
      _notice = '无法回听这段本机录音。';
      _notify();
      return false;
    }
  }

  Future<void> stopPlayback() async {
    _playingRecordingId = null;
    try {
      await platform.stopPlayback();
    } catch (_) {
      // Playback is not allowed to block privacy cleanup.
    }
    _notify();
  }

  Future<void> deleteRecording(String id) async {
    if (_playingRecordingId == id) await stopPlayback();
    try {
      await store.deleteRecording(id);
      await refreshRecordings();
      _notice = '本机录音已删除。';
    } catch (_) {
      _notice = '本机录音删除失败，请重试。';
    }
    _notify();
  }

  Future<void> deleteAllRecordings() async {
    await store.deleteAllRecordings();
    _recordings = const [];
    _scheduleRecordingExpiry();
    _notify();
  }

  Future<void> refreshRecordings() async {
    try {
      _recordings = await store.recordings(now: now());
      _scheduleRecordingExpiry();
      _notify();
    } on SessionChanged {
      _recordingExpiryTimer?.cancel();
      _recordingExpiryTimer = null;
      _recordings = const [];
      _notice = '账号已切换，旧账号录音不可访问。';
      _notify();
    }
  }

  void _scheduleRecordingExpiry() {
    _recordingExpiryTimer?.cancel();
    _recordingExpiryTimer = null;
    if (_disposed || _recordings.isEmpty) return;
    var earliest = _recordings.first.expiresAt;
    for (final recording in _recordings.skip(1)) {
      if (recording.expiresAt.isBefore(earliest)) {
        earliest = recording.expiresAt;
      }
    }
    final delay = earliest.difference(now().toUtc());
    _recordingExpiryTimer = createTimer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_purgeExpiredRecordings()),
    );
  }

  Future<void> _purgeExpiredRecordings() async {
    if (_disposed) return;
    try {
      _recordings = await store.recordings(now: now());
      _scheduleRecordingExpiry();
      _notify();
    } on SessionChanged {
      _recordingExpiryTimer?.cancel();
      _recordingExpiryTimer = null;
      _recordings = const [];
      _notice = '账号已切换，旧账号录音不可访问。';
      _notify();
    }
  }

  Future<void> settle() => _windowTail;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _startGeneration++;
    _membershipTimer?.cancel();
    _recordingExpiryTimer?.cancel();
    _capturing = false;
    _captureStartedAt = null;
    _aggregator?.stop();
    _aggregator = null;
    sessions.identity.removeListener(_onIdentityChanged);
    unawaited(_pcmSubscription?.cancel());
    unawaited(platform.dispose());
    super.dispose();
  }
}
