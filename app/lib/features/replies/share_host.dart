import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/session.dart';

/// Native sources are destructive one-shot reads, never clipboard inspection.
class ShareHost extends StatefulWidget {
  const ShareHost(this.sessions, this.builder, {super.key, this.onWarmShare});
  final Sessions sessions;
  final Widget Function(AccountScope?, String?, int, VoidCallback) builder;

  /// Called when a share arrives while an account is active. Return true when
  /// the draft was put on the existing navigation stack; [discard] clears the
  /// pending warm draft without rebuilding that stack. A false result keeps
  /// the draft for the initial route when the navigator is not mounted yet.
  final bool Function(AccountScope scope, String text, VoidCallback discard)?
  onWarmShare;
  @override
  State<ShareHost> createState() => _ShareHostState();
}

class _ShareHostState extends State<ShareHost> with WidgetsBindingObserver {
  static const channel = MethodChannel('cn.higheq/reply-share');
  String? draft;
  late AccountScope? account = widget.sessions.active;
  int generation = 0, revision = 0;
  void identity() {
    final next = widget.sessions.active;
    if (account != null && account != next) {
      generation++;
      draft = null;
      revision++;
    }
    setState(() => account = next);
  }

  @override
  void initState() {
    super.initState();
    account = widget.sessions.active;
    widget.sessions.identity.addListener(identity);
    WidgetsBinding.instance.addObserver(this);
    channel.setMethodCallHandler((c) async {
      if (c.method == 'available') await take();
    });
    take();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) take();
  }

  Future<void> take() async {
    final epoch = generation;
    try {
      final value = await channel.invokeMethod<String>('take');
      if (mounted &&
          epoch == generation &&
          value != null &&
          value.trim().isNotEmpty) {
        final current = account;
        void discard() {
          if (!mounted) return;
          setState(() {
            draft = null;
            revision++;
          });
        }

        final handled =
            current != null &&
            (widget.onWarmShare?.call(current, value, discard) ?? false);
        if (!handled) {
          setState(() {
            draft = value;
            revision++;
          });
        }
      }
    } on MissingPluginException {
      /* Desktop and widget tests have no share source. */
    } on PlatformException {
      /* Never expose payloads in diagnostics. */
    }
  }

  @override
  void dispose() {
    generation++;
    widget.sessions.identity.removeListener(identity);
    WidgetsBinding.instance.removeObserver(this);
    channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(
    account,
    draft,
    revision,
    () => setState(() {
      draft = null;
      revision++;
    }),
  );
}

/// Keep the login navigator mounted when a warm share arrives. Do not reveal
/// another person's words or require login just to discard the draft.
class ShareLoginNotice extends StatelessWidget {
  const ShareLoginNotice({
    super.key,
    required this.pending,
    required this.discard,
    required this.child,
  });
  final bool pending;
  final VoidCallback? discard;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (pending)
        Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: SafeArea(
            bottom: false,
            child: ListTile(
              title: const Text('分享已暂存，登录后可编辑'),
              trailing: TextButton(onPressed: discard, child: const Text('丢弃')),
            ),
          ),
        ),
      Expanded(key: const ValueKey('account-flow'), child: child),
    ],
  );
}
