import 'models.dart';

/// Coordinates the two independent membership boundaries used by summary UI.
///
/// The displayed snapshot boundary protects counts that are already on screen.
/// The current request boundary protects the entitlement obtained for one
/// access/summary round. Both must still be active immediately before a send
/// or state adoption.
class SummaryRequestFence {
  SummaryRequestFence({
    required DateTime Function() now,
    required bool Function() isAccountCurrent,
  }) : _now = now,
       _isAccountCurrent = isAccountCurrent;

  final DateTime Function() _now;
  final bool Function() _isAccountCurrent;

  int _epoch = 0;
  AssistAccess? _requestAccess;
  AssistAccess? _displayedAccess;
  DateTime? _displayedExpiresAt;

  int get epoch => _epoch;
  AssistAccess? get requestAccess => _requestAccess;
  AssistAccess? get displayedAccess => _displayedAccess;

  int beginRequest({bool clearDisplayed = false}) {
    _epoch++;
    _requestAccess = null;
    if (clearDisplayed) {
      _displayedAccess = null;
      _displayedExpiresAt = null;
    }
    return _epoch;
  }

  /// Stops an in-flight round without discarding the displayed snapshot fence.
  void invalidateRequest() {
    _epoch++;
    _requestAccess = null;
  }

  void clear() {
    _epoch++;
    _requestAccess = null;
    _displayedAccess = null;
    _displayedExpiresAt = null;
  }

  bool isCurrentRequest(int epoch) => epoch == _epoch && _isAccountCurrent();

  bool captureRequest(int epoch, AssistAccess access) {
    if (!isCurrentRequest(epoch)) return false;
    _requestAccess = access;
    return true;
  }

  /// Tightens an existing snapshot when a shorter candidate entitlement is
  /// observed. A later renewal must never weaken the fence on old counts.
  void tightenDisplayedBoundary(AssistAccess candidate) {
    final displayed = _displayedAccess;
    if (displayed == null) return;
    final candidateExpiry = candidate.expiresAt;
    final currentExpiry = _displayedExpiresAt ?? displayed.expiresAt;
    if (candidateExpiry == null ||
        (currentExpiry != null && !candidateExpiry.isBefore(currentExpiry))) {
      return;
    }
    _displayedAccess = candidate;
    _displayedExpiresAt = candidateExpiry.toUtc();
  }

  bool canContinue(int epoch) {
    if (!isCurrentRequest(epoch)) return false;
    final request = _requestAccess;
    if (request == null || !request.activeAt(_now())) return false;
    final displayed = _displayedAccess;
    return displayed == null || displayed.activeAt(_now());
  }

  bool get displayedActive {
    final displayed = _displayedAccess;
    return displayed == null || displayed.activeAt(_now());
  }

  bool get requestActive {
    final request = _requestAccess;
    return request != null && request.activeAt(_now());
  }

  bool get boundaryExpired {
    final access = boundaryAccess;
    return access != null && !access.activeAt(_now());
  }

  AssistAccess? get boundaryAccess {
    final request = _requestAccess;
    final displayed = _displayedAccess;
    if (request == null) return displayed;
    if (displayed == null) return request;
    final requestExpiry = request.expiresAt;
    final displayedExpiry = displayed.expiresAt;
    if (requestExpiry == null) return displayed;
    if (displayedExpiry == null) return request;
    return requestExpiry.isBefore(displayedExpiry) ? request : displayed;
  }

  DateTime? get boundaryExpiresAt => boundaryAccess?.expiresAt?.toUtc();

  /// Atomically makes [access] the displayed snapshot boundary after the
  /// caller has successful summary data ready. This rechecks both boundaries
  /// at the exact adoption point.
  bool adoptSnapshot(int epoch, AssistAccess access) {
    if (!canContinue(epoch) || !access.activeAt(_now())) return false;
    _displayedAccess = access;
    _displayedExpiresAt = access.expiresAt?.toUtc();
    return true;
  }
}
