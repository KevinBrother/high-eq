import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api.dart';
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
    this.result,
    this.dismissResult,
    this.closureNotice,
    this.dismissClosureNotice,
    required this.child,
  });
  final bool pending;
  final VoidCallback? discard;
  final LogoutResult? result;
  final VoidCallback? dismissResult;
  final String? closureNotice;
  final VoidCallback? dismissClosureNotice;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final feedbackLimit =
            constraints.maxHeight.isFinite && constraints.maxHeight > 0
            ? constraints.maxHeight * 0.48
            : 240.0;
        // Keep the notice below the navigator in semantics order. A modal
        // route inside [child] blocks semantics of earlier siblings, while
        // VerticalDirection.up still paints this notice above the account
        // flow. The notice scrolls independently so large text and short
        // screens cannot squeeze the navigator or overflow the host column.
        return Column(
          verticalDirection: VerticalDirection.up,
          children: [
            Expanded(key: const ValueKey('account-flow'), child: child),
            if (result != null || pending || closureNotice != null)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: feedbackLimit),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (result != null)
                        _LogoutFeedback(result!, dismiss: dismissResult),
                      if (closureNotice case final notice?)
                        Material(
                          color: colors.secondaryContainer,
                          child: SafeArea(
                            bottom: false,
                            child: ListTile(
                              title: Semantics(
                                liveRegion: true,
                                child: Text(notice),
                              ),
                              trailing: _NoticeDismissButton(
                                label: '关闭注销提示',
                                onPressed: dismissClosureNotice,
                              ),
                            ),
                          ),
                        ),
                      if (pending)
                        Material(
                          color: colors.secondaryContainer,
                          child: SafeArea(
                            bottom: false,
                            child: ListTile(
                              title: const Text('分享已暂存，登录后可编辑'),
                              trailing: TextButton(
                                onPressed: discard,
                                child: const Text('丢弃'),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// Login notices sit beside the Navigator, so their actions must work without
// a Navigator overlay.
class _NoticeDismissButton extends StatelessWidget {
  const _NoticeDismissButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    enabled: onPressed != null,
    focusable: onPressed != null,
    label: label,
    onTap: onPressed,
    excludeSemantics: true,
    child: TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: const Text('关闭'),
    ),
  );
}

class _LogoutFeedback extends StatelessWidget {
  const _LogoutFeedback(this.result, {this.dismiss});

  final LogoutResult result;
  final VoidCallback? dismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final localConfirmed = result.localCleanup == LogoutStatus.confirmed;
    final serverConfirmed = result.serverLogout == LogoutStatus.confirmed;
    final healthConfirmed =
        result.healthWithdrawal == LogoutHealthStatus.confirmed;
    final healthNotRequired =
        result.healthWithdrawal == LogoutHealthStatus.notRequired;
    final healthNeedsDecision =
        result.healthWithdrawal == LogoutHealthStatus.needsDecision;
    final guidance = <String>[
      if (!localConfirmed) '本机清理未完成，请解锁设备后重试。',
      if (healthNeedsDecision) '健康授权状态需要登录原账号后确认。',
      if (result.healthWithdrawal == LogoutHealthStatus.unconfirmed)
        '健康撤回尚未确认，请登录原账号后重试。',
      if (!serverConfirmed) '服务端登出尚未确认，请登录原账号后重试。',
    ];

    return Material(
      color: colors.surfaceContainerHigh,
      child: SafeArea(
        bottom: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Icon(Icons.logout_rounded, color: colors.primary),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 9),
                      child: Text(
                        '退出结果',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                  _NoticeDismissButton(label: '关闭退出结果', onPressed: dismiss),
                ],
              ),
              const SizedBox(height: 2),
              _LogoutOutcomeRow(
                key: const ValueKey('logout-local'),
                icon: localConfirmed
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                color: localConfirmed ? colors.primary : colors.error,
                label: '本机清理',
                status: localConfirmed ? '已完成' : '未完成',
              ),
              _LogoutOutcomeRow(
                key: const ValueKey('logout-health'),
                icon: healthConfirmed
                    ? Icons.check_circle_outline
                    : healthNotRequired
                    ? Icons.remove_circle_outline
                    : healthNeedsDecision
                    ? Icons.info_outline
                    : Icons.error_outline,
                color: healthConfirmed || healthNotRequired
                    ? colors.primary
                    : healthNeedsDecision
                    ? colors.tertiary
                    : colors.error,
                label: '健康授权',
                status: switch (result.healthWithdrawal) {
                  LogoutHealthStatus.confirmed => '撤回已确认',
                  LogoutHealthStatus.notRequired => '无需撤回',
                  LogoutHealthStatus.needsDecision => '待原账号确认',
                  LogoutHealthStatus.unconfirmed => '撤回未确认',
                },
              ),
              _LogoutOutcomeRow(
                key: const ValueKey('logout-server'),
                icon: serverConfirmed
                    ? Icons.check_circle_outline
                    : Icons.error_outline,
                color: serverConfirmed ? colors.primary : colors.error,
                label: '服务端登出',
                status: serverConfirmed ? '已确认' : '未确认',
              ),
              if (guidance.isNotEmpty) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(left: 30, right: 8),
                  child: Text(
                    guidance.join(' '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LogoutOutcomeRow extends StatelessWidget {
  const _LogoutOutcomeRow({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.status,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String status;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label：$status',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 30, child: Icon(icon, size: 18, color: color)),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '$label：'),
                    TextSpan(
                      text: status,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
