import 'dart:async';

import 'package:flutter/widgets.dart';

/// Rebuilds a page when a reminder deadline is reached or the app resumes.
///
/// The page remains responsible for rendering from its injected clock. This
/// widget only supplies the missing time boundary and lifecycle signal.
class ReminderBoundary extends StatefulWidget {
  const ReminderBoundary({
    required this.deadline,
    required this.now,
    required this.onDue,
    required this.child,
    super.key,
  });

  final DateTime? deadline;
  final DateTime Function() now;
  final VoidCallback onDue;
  final Widget child;

  @override
  State<ReminderBoundary> createState() => _ReminderBoundaryState();
}

class _ReminderBoundaryState extends State<ReminderBoundary>
    with WidgetsBindingObserver {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didUpdateWidget(covariant ReminderBoundary oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deadline != widget.deadline) _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_isDue) widget.onDue();
    _schedule();
  }

  bool get _isDue {
    final deadline = widget.deadline;
    return deadline != null && !widget.now().isBefore(deadline);
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    final deadline = widget.deadline;
    if (deadline == null) return;
    final remaining = deadline.difference(widget.now());
    if (remaining <= Duration.zero) return;
    _timer = Timer(remaining, () {
      if (!mounted) return;
      widget.onDue();
      _schedule();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
