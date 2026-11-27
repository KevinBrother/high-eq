import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api.dart';
import '../../../core/session.dart';
import '../../voice/store.dart';
import 'baseline_progress_section.dart';
import 'models.dart';
import 'presentation.dart';
import 'repository.dart';
import 'summary_request_fence.dart';
import 'summary_section.dart';

/// Membership-scoped summary view that never depends on the live voice
/// composition.
///
/// This page reads entitlements, consent records, and authorized aggregates. It
/// has no frame source, replay source, recorder, uploader, or decision runtime,
/// so a free or expired member and a member without voice consent both fail
/// closed for every sensor-backed capability.
class SummaryOnlyPage extends StatefulWidget {
  const SummaryOnlyPage({
    super.key,
    required this.api,
    required this.scope,
    this.entitlementRevision = 0,
    this.onOpenMarks,
    this.onOpenMembership,
    this.onOpenVoice,
    this.sourceNotice,
    this.now,
    this.createTimer,
    this.repository,
  });

  final AppApi api;
  final AccountScope scope;

  /// Advances after a screen that can mutate membership returns. Summary-only
  /// mode has no voice-controller initialization signal, so this explicit
  /// revision is its account-scoped entitlement refresh trigger.
  final int entitlementRevision;
  final VoidCallback? onOpenMarks;
  final VoidCallback? onOpenMembership;
  final VoidCallback? onOpenVoice;
  final String? sourceNotice;
  final DateTime Function()? now;
  final Timer Function(Duration, void Function())? createTimer;

  /// Test seam only. Production always constructs the account-scoped API
  /// repository from [api] and [scope].
  final AssistRepository? repository;

  @override
  State<SummaryOnlyPage> createState() => _SummaryOnlyPageState();
}

class _SummaryOnlyPageState extends State<SummaryOnlyPage>
    with WidgetsBindingObserver {
  late AssistRepository _repository;
  AssistAccess? _access;
  List<EmotionGroup> _groups = const [];
  BaselineProgress? _baselineProgress;
  // Decision versions captured when the displayed baseline request started.
  // A purpose whose version moved during that request stays hidden until a
  // fresh read adopts a response begun after the newer decision.
  Map<String, int>? _baselineVersions;
  String? _baselineError;
  Map<String, String> _contactNames = const {};
  bool _loading = true;
  bool _reloading = false;
  String? _error;
  Timer? _expiryTimer;
  DateTime? _timerExpiresAt;
  int _expiryEpoch = 0;
  bool _foreground = true;
  late final SummaryRequestFence _requestFence;

  @override
  void initState() {
    super.initState();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _foreground =
        lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.api.sessions.identity.addListener(_identityChanged);
    widget.api.sessions.consentWithdrawals.addListener(
      _consentWithdrawalsChanged,
    );
    widget.api.sessions.withdrawalIntentRevision.addListener(
      _consentWithdrawalsChanged,
    );
    widget.api.sessions.voiceRevocation.addListener(_consentWithdrawalsChanged);
    unawaited(_hydrateVoiceRevocation());
    _repository = _createRepository();
    _requestFence = SummaryRequestFence(
      now: _nowUtc,
      isAccountCurrent: () => _isAccountCurrent,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  AssistRepository _createRepository() =>
      widget.repository ?? ApiAssistRepository(widget.api, widget.scope);

  @override
  void didUpdateWidget(covariant SummaryOnlyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final apiChanged = !identical(oldWidget.api, widget.api);
    final scopeChanged = !identical(oldWidget.scope, widget.scope);
    final repositoryChanged = !identical(
      oldWidget.repository,
      widget.repository,
    );
    final entitlementRefresh =
        oldWidget.entitlementRevision != widget.entitlementRevision;
    if (!apiChanged &&
        !scopeChanged &&
        !repositoryChanged &&
        !entitlementRefresh) {
      return;
    }

    if (apiChanged || scopeChanged || repositoryChanged) {
      if (apiChanged || scopeChanged) {
        oldWidget.api.sessions.identity.removeListener(_identityChanged);
        widget.api.sessions.identity.addListener(_identityChanged);
        oldWidget.api.sessions.consentWithdrawals.removeListener(
          _consentWithdrawalsChanged,
        );
        widget.api.sessions.consentWithdrawals.addListener(
          _consentWithdrawalsChanged,
        );
        oldWidget.api.sessions.withdrawalIntentRevision.removeListener(
          _consentWithdrawalsChanged,
        );
        widget.api.sessions.withdrawalIntentRevision.addListener(
          _consentWithdrawalsChanged,
        );
        oldWidget.api.sessions.voiceRevocation.removeListener(
          _consentWithdrawalsChanged,
        );
        widget.api.sessions.voiceRevocation.addListener(
          _consentWithdrawalsChanged,
        );
        unawaited(_hydrateVoiceRevocation());
      }
      _repository = _createRepository();
      _hideRestricted(
        error: _isAccountCurrent ? null : '账号已切换，旧账号的会员汇总已隐藏。',
        reload: _isAccountCurrent,
      );
      return;
    }

    unawaited(_load(preserveData: true));
  }

  bool get _isAccountCurrent =>
      identical(widget.api.sessions.identity.value, widget.scope);

  DateTime _nowUtc() => (widget.now?.call() ?? DateTime.now()).toUtc();

  bool _isCurrent(int requestEpoch) =>
      mounted && _requestFence.isCurrentRequest(requestEpoch);

  bool _canSend(int requestEpoch) =>
      mounted && _foreground && _requestFence.canContinue(requestEpoch);

  bool _canProbeAccess(int requestEpoch) =>
      _foreground && _isCurrent(requestEpoch) && _requestFence.displayedActive;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      // Background timers are not a security boundary. Invalidate network
      // adoption while retaining the earliest displayed snapshot boundary.
      _requestFence.invalidateRequest();
      return;
    }
    if (!_isAccountCurrent) return;
    final boundaryAccess = _requestFence.boundaryAccess;
    if (boundaryAccess != null && _requestFence.boundaryExpired) {
      _fenceExpired(boundaryAccess);
      return;
    }
    _scheduleBoundaryExpiry();
    unawaited(_load(preserveData: true));
  }

  void _identityChanged() {
    if (_isAccountCurrent || !mounted) return;
    _hideRestricted(error: '账号已切换，旧账号的会员汇总已隐藏。');
  }

  @override
  void dispose() {
    _requestFence.invalidateRequest();
    _cancelExpiryTimer();
    widget.api.sessions.identity.removeListener(_identityChanged);
    widget.api.sessions.consentWithdrawals.removeListener(
      _consentWithdrawalsChanged,
    );
    widget.api.sessions.withdrawalIntentRevision.removeListener(
      _consentWithdrawalsChanged,
    );
    widget.api.sessions.voiceRevocation.removeListener(
      _consentWithdrawalsChanged,
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load({bool preserveData = false}) async {
    if (!_foreground) return;
    if (!_isAccountCurrent) {
      _hideRestricted(error: '账号已切换，旧账号的会员汇总已隐藏。');
      return;
    }
    final keepData = preserveData && _requestFence.displayedAccess != null;
    final requestEpoch = _requestFence.beginRequest(clearDisplayed: !keepData);
    if (!keepData) _cancelExpiryTimer();
    setState(() {
      _error = null;
      _baselineProgress = null;
      _baselineVersions = null;
      _baselineError = null;
      _loading = !keepData;
      _reloading = keepData;
      if (!keepData) {
        _access = null;
        _groups = const [];
        _contactNames = const {};
      }
    });

    try {
      final access = await _repository.access(
        canSend: () => _canProbeAccess(requestEpoch),
      );
      if (!_isCurrent(requestEpoch)) return;
      if (!_requestFence.captureRequest(requestEpoch, access)) return;
      if (!access.activeAt(_nowUtc())) {
        _fenceExpired(access);
        return;
      }
      if (keepData) {
        // A refresh may shorten or lengthen the entitlement. The old counts
        // remain fenced by both the snapshot's original boundary and every
        // candidate returned while that snapshot is still displayed.
        _requestFence.tightenDisplayedBoundary(access);
      }
      _scheduleBoundaryExpiry();

      final groups = await _repository.summary(
        canSend: () => _canSend(requestEpoch),
      );
      if (!_isCurrent(requestEpoch)) return;
      if (_requestFence.boundaryExpired) {
        final boundaryAccess = _requestFence.boundaryAccess ?? access;
        _fenceExpired(boundaryAccess);
        return;
      }
      if (!_requestFence.adoptSnapshot(requestEpoch, access)) {
        if (!_isCurrent(requestEpoch)) return;
        final boundaryAccess = _requestFence.boundaryAccess ?? access;
        _fenceExpired(boundaryAccess);
        return;
      }
      setState(() {
        // Entitlement and counts become one atomic snapshot only after the
        // same refresh round has produced a summary.
        _access = access;
        _groups = List.unmodifiable(groups);
        // Use neutral labels without requesting the contacts directory.
        _contactNames = const {};
        _loading = false;
        _reloading = false;
      });
      _scheduleBoundaryExpiry();
      unawaited(_loadBaselineProgress(requestEpoch));
    } on SummaryRequestCancelled {
      if (!_isCurrent(requestEpoch)) return;
      final boundaryAccess = _requestFence.boundaryAccess;
      if (boundaryAccess != null && _requestFence.boundaryExpired) {
        _fenceExpired(boundaryAccess);
        return;
      }
      _hideRestricted(error: '会员汇总请求已安全取消，请稍后重试。');
    } on Object catch (error) {
      if (!_isCurrent(requestEpoch)) return;
      _hideRestricted(error: _fixedLoadError(error));
    }
  }

  Future<void> _loadBaselineProgress(int requestEpoch) async {
    final versions = widget.api.sessions.consentVersions();
    try {
      final progress = await _repository.baselineProgress(
        canSend: () => _canSend(requestEpoch),
      );
      if (!_canSend(requestEpoch)) return;
      setState(() {
        _baselineVersions = versions;
        _baselineProgress = _maskKnownWithdrawals(progress, versions);
      });
    } on Object catch (error) {
      if (!_canSend(requestEpoch)) return;
      if (error is ApiFailure && error.status == 403) {
        // The baseline read also re-checks collection entitlement. A 403 means
        // this refresh round no longer holds it, so the summary adopted earlier
        // in the same round cannot stay on screen.
        _hideRestricted(error: _fixedLoadError(error));
        return;
      }
      setState(() {
        _baselineError = '暂时无法读取基线进度，请重试。';
      });
    }
  }

  /// A withdrawal confirmed in this process hides only the affected signals.
  /// The mask is applied again when an in-flight response is adopted, so a
  /// stale 200 cannot restore a dimension the user already withdrew.
  void _consentWithdrawalsChanged() {
    if (!mounted) return;
    final progress = _baselineProgress;
    if (progress == null) return;
    final masked = _maskKnownWithdrawals(progress, _baselineVersions);
    if (identical(masked, progress)) return;
    setState(() => _baselineProgress = masked);
  }

  /// Picks up a voice revocation persisted before this page opened. The live
  /// notifier covers revocations that happen while the page is mounted.
  Future<void> _hydrateVoiceRevocation() async {
    final scope = widget.scope;
    try {
      final revoked = await VoiceWindowStore(
        widget.api.sessions,
        scope,
      ).voiceRevoked();
      if (!mounted || !identical(widget.scope, scope)) return;
      if (revoked) widget.api.sessions.noteVoiceRevoked(scope, true);
    } on Object {
      // An unreadable local marker must not block the summary; the consent
      // decision path still fails closed on its own.
    }
  }

  BaselineProgress _maskKnownWithdrawals(
    BaselineProgress progress, [
    Map<String, int>? versions,
  ]) {
    final withdrawn = widget.api.sessions.consentWithdrawals.value;
    final atRead = versions ?? const <String, int>{};
    bool fenced(String purpose) =>
        withdrawn.contains(purpose) ||
        widget.api.sessions.consentVersion(purpose) != (atRead[purpose] ?? 0);
    // An offline HealthSync withdrawal stores a durable local intent before the
    // server sees it. Treat it as known withdrawal immediately.
    final health =
        fenced('health') ||
        widget.api.sessions.hasWithdrawalIntent(widget.scope);
    // A failed voice revocation sync keeps its durable local marker; the
    // summary must not show voice rows until a successful grant clears it.
    final voice = fenced('voice') || widget.api.sessions.voiceRevocation.value;
    if (!health && !voice) return progress;
    final heartRate = health ? null : progress.heartRate;
    final hrv = health ? null : progress.hrv;
    final speechRate = voice ? null : progress.speechRate;
    final volume = voice ? null : progress.volume;
    final pitch = voice ? null : progress.pitch;
    if (identical(heartRate, progress.heartRate) &&
        identical(hrv, progress.hrv) &&
        identical(speechRate, progress.speechRate) &&
        identical(volume, progress.volume) &&
        identical(pitch, progress.pitch)) {
      return progress;
    }
    return BaselineProgress(
      heartRate: heartRate,
      speechRate: speechRate,
      volume: volume,
      pitch: pitch,
      hrv: hrv,
    );
  }

  String _fixedLoadError(Object error) {
    if (error is ApiFailure) {
      return switch (error.status) {
        401 => '登录凭证无效或已过期，会员汇总已隐藏。',
        403 => '会员汇总已隐藏：没有获得所需授权。',
        _ => '会员汇总暂时无法读取，请稍后重试。',
      };
    }
    if (error is SessionChanged) {
      return '账号已切换，旧账号的会员汇总已隐藏。';
    }
    return '会员汇总暂时无法读取，请稍后重试。';
  }

  void _hideRestricted({String? error, bool reload = false}) {
    if (!mounted) return;
    _requestFence.clear();
    _cancelExpiryTimer();
    setState(() {
      _access = null;
      _groups = const [];
      _baselineProgress = null;
      _baselineVersions = null;
      _baselineError = null;
      _contactNames = const {};
      _loading = false;
      _reloading = false;
      _error = error;
    });
    if (reload) unawaited(_load());
  }

  void _cancelExpiryTimer() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _timerExpiresAt = null;
  }

  void _scheduleBoundaryExpiry() {
    final expiresAt = _requestFence.boundaryExpiresAt;
    final access = _requestFence.boundaryAccess;
    if (expiresAt == null || access == null) {
      _cancelExpiryTimer();
      return;
    }
    final now = _nowUtc();
    if (!expiresAt.isAfter(now)) {
      _fenceExpired(access);
      return;
    }
    final scheduled = _timerExpiresAt;
    if (_expiryTimer != null &&
        scheduled != null &&
        scheduled.isAtSameMomentAs(expiresAt)) {
      return;
    }
    final expiryEpoch = ++_expiryEpoch;
    _cancelExpiryTimer();
    final createTimer =
        widget.createTimer ?? (duration, callback) => Timer(duration, callback);
    _timerExpiresAt = expiresAt;
    _expiryTimer = createTimer(
      expiresAt.difference(now),
      () => _handleExpiry(expiryEpoch),
    );
  }

  void _handleExpiry(int expiryEpoch) {
    _expiryTimer = null;
    _timerExpiresAt = null;
    if (!mounted || expiryEpoch != _expiryEpoch) return;
    final access = _requestFence.boundaryAccess;
    final expiresAt = _requestFence.boundaryExpiresAt;
    if (access == null || expiresAt == null) return;
    if (expiresAt.isAfter(_nowUtc())) {
      _scheduleBoundaryExpiry();
      return;
    }
    _fenceExpired(access);
  }

  void _fenceExpired(AssistAccess access) {
    if (!mounted) return;
    // The boundary invalidates every in-flight request and queued timer. Keep
    // the expired access only to render the fail-closed membership card.
    _requestFence.clear();
    _cancelExpiryTimer();
    setState(() {
      _access = access;
      _groups = const [];
      _baselineProgress = null;
      _baselineVersions = null;
      _baselineError = null;
      _contactNames = const {};
      _loading = false;
      _reloading = false;
      _error = null;
    });
  }

  void _openMarks() {
    if (widget.onOpenMarks case final callback?) {
      callback();
      return;
    }
    Navigator.pushNamed(context, '/marks', arguments: true);
  }

  void _openMembership() {
    if (widget.onOpenMembership case final callback?) {
      callback();
      return;
    }
    Navigator.pushNamed(context, '/membership');
  }

  void _openVoice() {
    if (widget.onOpenVoice case final callback?) {
      _requestFence.invalidateRequest();
      setState(() {
        _baselineProgress = null;
        _baselineVersions = null;
        _baselineError = null;
      });
      callback();
    }
  }

  @override
  Widget build(BuildContext context) {
    final active =
        _isAccountCurrent &&
        _requestFence.displayedActive &&
        (_access?.activeAt(_nowUtc()) ?? false);
    final showSummary = active && !_loading && _error == null;
    final showLocked =
        !_loading && _error == null && _access != null && !active;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('情绪辅助')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
              children: [
                Text(
                  '只回看已授权的记录，帮助你识别当下、补充上下文。这里不诊断情绪，也不推断关系人的人格。',
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                ),
                const SizedBox(height: 18),
                if (widget.sourceNotice case final notice?) ...[
                  _SummaryNoticeCard(notice: notice),
                  const SizedBox(height: 14),
                ],
                if (widget.onOpenVoice != null) ...[
                  OutlinedButton.icon(
                    style: assistButtonStyle,
                    onPressed: _openVoice,
                    icon: const Icon(Icons.mic_none),
                    label: const Text('打开语音页'),
                  ),
                  const SizedBox(height: 14),
                ],
                FilledButton.icon(
                  style: assistButtonStyle,
                  onPressed: _openMarks,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('我上头了'),
                ),
                const SizedBox(height: 8),
                const Text('手动标记和历史记录始终可用，不要求会员，也不占用 AI 次数。'),
                if (_loading) ...[
                  const SizedBox(height: 28),
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 12),
                  const Center(child: Text('正在读取会员汇总…')),
                ] else if (_error case final error?) ...[
                  const SizedBox(height: 22),
                  _SummaryErrorCard(error: error, retry: _load),
                ] else if (showLocked) ...[
                  const SizedBox(height: 22),
                  _SummaryLockedCard(
                    expired: _access!.tier == 'member',
                    onOpenMembership: _openMembership,
                  ),
                ] else if (showSummary) ...[
                  const SizedBox(height: 26),
                  Semantics(
                    header: true,
                    child: Text('会员汇总仍可查看', style: theme.textTheme.titleLarge),
                  ),
                  const SizedBox(height: 8),
                  const Text('可查看已授权的历史汇总和分项基线进度。'),
                  const SizedBox(height: 18),
                  SummarySection(
                    groups: _groups,
                    contactNames: _contactNames,
                    reloading: _reloading,
                    onReload: () => _load(preserveData: true),
                  ),
                  const SizedBox(height: 24),
                  BaselineProgressSection(
                    progress: _baselineProgress,
                    error: _baselineError,
                    onReload: () => _load(preserveData: true),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryNoticeCard extends StatelessWidget {
  const _SummaryNoticeCard({required this.notice});

  final String notice;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, color: colors.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(notice, style: const TextStyle(height: 1.45))),
          ],
        ),
      ),
    );
  }
}

class _SummaryErrorCard extends StatelessWidget {
  const _SummaryErrorCard({required this.error, required this.retry});

  final String error;
  final VoidCallback retry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: assistButtonStyle,
                onPressed: retry,
                child: const Text('重新读取汇总'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryLockedCard extends StatelessWidget {
  const _SummaryLockedCard({
    required this.expired,
    required this.onOpenMembership,
  });

  final bool expired;
  final VoidCallback onOpenMembership;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              expired ? '会员已到期，会员数据已隐藏。' : '会员数据需要有效会员后查看。',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text('你的手动标记、历史与复盘仍可继续使用。'),
            const SizedBox(height: 12),
            OutlinedButton(
              style: assistButtonStyle,
              onPressed: onOpenMembership,
              child: const Text('查看会员方案'),
            ),
          ],
        ),
      ),
    );
  }
}
