import 'dart:async';

import 'package:flutter/material.dart';

import '../privacy/page.dart';
import '../privacy/store.dart';
import 'surface.dart';

/// Gates named routes and individually pushed share pages on the same
/// account read. Keep a mounted draft during a transient status recheck.
class AccountEntryPage extends StatefulWidget {
  const AccountEntryPage(
    this.privacy, {
    super.key,
    required this.onActive,
    required this.onClosureSubmitted,
    required this.onClosureUnconfirmed,
    required this.onClosureCancelled,
    required this.onExit,
  });

  final PrivacyStore privacy;
  final WidgetBuilder onActive;
  final ValueChanged<ClosureSubmission> onClosureSubmitted;
  final ValueChanged<bool> onClosureUnconfirmed;
  final VoidCallback onClosureCancelled;
  final VoidCallback onExit;

  @override
  State<AccountEntryPage> createState() => _AccountEntryPageState();
}

class _AccountEntryPageState extends State<AccountEntryPage> {
  late final _admission = widget.privacy.admission;
  bool _entered = false;
  bool _recovering = false;

  @override
  void initState() {
    super.initState();
    scheduleMicrotask(() {
      if (!mounted) return;
      unawaited(_admission.ensure().then<void>((_) {}, onError: (Object _) {}));
    });
  }

  Future<void> _retry() async {
    try {
      await _admission.refresh();
    } catch (_) {
      // The admission owner publishes the error for this attempt.
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _admission,
    builder: (context, _) {
      _recovering = _recovering || _admission.frozenUntil != null;
      if (_recovering) {
        _entered = false;
        return PrivacyPage(
          widget.privacy,
          onClosureSubmitted: widget.onClosureSubmitted,
          onClosureUnconfirmed: widget.onClosureUnconfirmed,
          onClosureCancelled: widget.onClosureCancelled,
          onExit: widget.onExit,
          refreshOnEntry: false,
        );
      }
      final allowed = _admission.isOrdinary;
      _entered = _entered || allowed;
      final error = _admission.error;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_entered)
            Visibility(
              visible: allowed,
              maintainState: true,
              child: Builder(builder: widget.onActive),
            ),
          if (!allowed)
            FlowSurface(
              '个人空间',
              '正在确认账号状态',
              busy: error == null,
              message: error == null ? null : friendlyError(error),
              [
                if (error != null) ...[
                  FilledButton(
                    key: const Key('account-entry-retry'),
                    onPressed: _retry,
                    child: const Text('重试'),
                  ),
                  TextButton(
                    onPressed: widget.onExit,
                    child: const Text('退出账号'),
                  ),
                ],
              ],
            ),
        ],
      );
    },
  );
}
