import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/api.dart';
import '../../../core/session.dart';
import 'summary_only_page.dart';

enum EmotionEntryOrigin { summary, membership, voice }

/// The formal account route uses the read-only membership composition.
class EmotionEntryRoute extends StatefulWidget {
  const EmotionEntryRoute({
    super.key,
    required this.api,
    required this.scope,
    this.origin,
  });

  final AppApi api;
  final AccountScope scope;
  final EmotionEntryOrigin? origin;

  @override
  State<EmotionEntryRoute> createState() => _EmotionEntryRouteState();
}

class _EmotionEntryRouteState extends State<EmotionEntryRoute> {
  int _entitlementRevision = 0;

  Future<void> _open(String route, EmotionEntryOrigin destination) async {
    final navigator = Navigator.of(context);
    if (widget.origin == destination) {
      navigator.pop();
      return;
    }
    await navigator.pushNamed(route, arguments: EmotionEntryOrigin.summary);
    if (mounted) {
      setState(() => _entitlementRevision++);
    }
  }

  @override
  Widget build(BuildContext context) => SummaryOnlyPage(
    api: widget.api,
    scope: widget.scope,
    entitlementRevision: _entitlementRevision,
    onOpenMembership: () =>
        unawaited(_open('/membership', EmotionEntryOrigin.membership)),
    onOpenVoice: () => unawaited(_open('/voice', EmotionEntryOrigin.voice)),
  );
}
