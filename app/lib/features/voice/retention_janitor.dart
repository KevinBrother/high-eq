import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/session.dart';
import 'store.dart';

/// Keeps account-scoped recordings within their three-day retention even when
/// the voice page has been closed.
///
/// The janitor captures one [AccountScope] at a time and never swaps to a
/// newer account while an old purge is still running. A short periodic sweep
/// is intentional: page timers disappear with the controller, but the app-level
/// janitor remains alive for the rest of the process.
class VoiceRetentionJanitor {
  static const sweepInterval = Duration(minutes: 1);

  final Sessions sessions;
  final DateTime Function() now;
  final Timer Function(Duration, void Function()) createTimer;
  final Duration interval;

  AccountScope? _scope;
  VoiceWindowStore? _store;
  Timer? _sweepTimer;
  bool _disposed = false;
  Future<void> _tail = Future.value();

  VoiceRetentionJanitor({
    required this.sessions,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createTimer,
    this.interval = sweepInterval,
  }) : now = now ?? DateTime.now,
       createTimer = createTimer ?? Timer.new {
    sessions.identity.addListener(_onIdentityChanged);
    _onIdentityChanged();
  }

  void _onIdentityChanged() {
    if (_disposed) return;
    final next = sessions.identity.value;
    if (identical(next, _scope)) return;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _scope = next;
    _store = next == null ? null : VoiceWindowStore(sessions, next);
    if (next == null) return;
    unawaited(purgeNow());
    _scheduleSweep();
  }

  /// Purges only the scope captured when this call starts. Account changes are
  /// observed as their own event and can never redirect an in-flight purge.
  Future<void> purgeNow() {
    final scope = _scope;
    final store = _store;
    if (_disposed || scope == null || store == null) return Future.value();

    final next = _tail.then((_) async {
      if (_disposed || !identical(sessions.identity.value, scope)) return;
      try {
        await store.purgeExpired(now: now().toUtc());
      } on SessionChanged {
        // A concurrent account change already made this scope inaccessible.
      } catch (_) {
        // Retention cleanup is best effort; a later sweep retries the same
        // captured scope while it remains active.
      }
    });
    _tail = next;
    _scheduleSweep();
    return next;
  }

  void _scheduleSweep() {
    if (_disposed || _scope == null) return;
    _sweepTimer?.cancel();
    _sweepTimer = createTimer(interval, () {
      _sweepTimer = null;
      unawaited(purgeNow());
    });
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sweepTimer?.cancel();
    _sweepTimer = null;
    sessions.identity.removeListener(_onIdentityChanged);
    _scope = null;
    _store = null;
  }
}

/// Hosts the application-wide janitor and asks it to sweep again whenever the
/// app returns to the foreground.
class VoiceRetentionJanitorHost extends StatefulWidget {
  final Sessions sessions;
  final Widget child;

  const VoiceRetentionJanitorHost({
    super.key,
    required this.sessions,
    required this.child,
  });

  @override
  State<VoiceRetentionJanitorHost> createState() =>
      _VoiceRetentionJanitorHostState();
}

class _VoiceRetentionJanitorHostState extends State<VoiceRetentionJanitorHost>
    with WidgetsBindingObserver {
  late final VoiceRetentionJanitor _janitor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _janitor = VoiceRetentionJanitor(sessions: widget.sessions);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_janitor.purgeNow());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _janitor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
