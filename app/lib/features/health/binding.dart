import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/providers.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../privacy/account_access.dart';
import 'huawei.dart';
import 'platform.dart';
import 'sync.dart';

const t28HuaweiHealthApproved = bool.fromEnvironment(
  'T28_HUAWEI_HEALTH_APPROVED',
  defaultValue: false,
);

enum HealthLifecycleAction { resumed, inactive, suspended }

HealthLifecycleAction healthLifecycleAction(AppLifecycleState state) =>
    switch (state) {
      AppLifecycleState.resumed => HealthLifecycleAction.resumed,
      AppLifecycleState.inactive => HealthLifecycleAction.inactive,
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => HealthLifecycleAction.suspended,
    };

/// Resolve the native source before constructing a vendor adapter. Huawei
/// approval is a build-time release decision, not a runtime toggle.
Future<HealthPort> selectHealthPort({
  required HealthPort platform,
  bool huaweiApproved = t28HuaweiHealthApproved,
  HuaweiHealthSdk Function()? huaweiSdk,
}) async {
  String? source;
  try {
    source = await platform.source();
  } on Object {
    return const _UnavailableHealthPort();
  }
  if (source == 'apple_history' || source == 'health_connect') return platform;
  if (source != 'huawei_history' || !huaweiApproved) {
    return const _UnavailableHealthPort();
  }
  return HuaweiHealthPort(
    huaweiSdk?.call() ?? MethodChannelHuaweiHealthSdk(),
    approved: true,
  );
}

class _UnavailableHealthPort implements HealthPort {
  const _UnavailableHealthPort();

  @override
  Future<String?> source() async => null;
  @override
  Future<bool> request({void Function()? onSystemPrompt}) async => false;
  @override
  Future<bool> queryable() async => false;
  @override
  Future<List<List>> read(int from, int to) async => const [];
  @override
  Future<void> stop() async {}
}

final healthProvider = FutureProvider.autoDispose
    .family<HealthSync?, AccountScope>((ref, scope) async {
      final api = await ref.watch(apiProvider.future);
      if (api.transport is ExampleTransport) {
        return null; // No native access in contract/demo builds.
      }
      if (!ref.mounted) return null;
      final gate = await ref.watch(consentProvider.future);
      if (!ref.mounted) return null;
      final port = await selectHealthPort(platform: DeviceHealth());
      if (!ref.mounted) return null;
      final sync = HealthSync(api, scope, gate, port);
      ref.onDispose(sync.close);
      return sync;
    });

class HealthForeground extends ConsumerStatefulWidget {
  final AccountScope scope;
  final Widget child;
  final AccountAccess? admission;
  const HealthForeground(this.scope, this.child, {super.key, this.admission});
  @override
  ConsumerState<HealthForeground> createState() => _Foreground();
}

class _Foreground extends ConsumerState<HealthForeground>
    with WidgetsBindingObserver {
  Timer? timer;
  HealthSync? current;
  bool get active =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.admission?.addListener(_admissionChanged);
    timer = Timer.periodic(const Duration(seconds: 30), (_) => run());
  }

  void run() {
    if (active && widget.admission?.isOrdinary != false) {
      unawaited(
        current?.tick().catchError((_) {
          /* retry only through the full gate */
        }),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (healthLifecycleAction(state)) {
      case HealthLifecycleAction.resumed:
        current?.resume();
        run();
      case HealthLifecycleAction.inactive:
        current?.inactive();
      case HealthLifecycleAction.suspended:
        current?.suspend();
    }
  }

  void _admissionChanged() {
    if (widget.admission?.isOrdinary == false) {
      current?.suspend();
      current = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant HealthForeground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.admission == widget.admission) return;
    oldWidget.admission?.removeListener(_admissionChanged);
    widget.admission?.addListener(_admissionChanged);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.admission?.isOrdinary != false) {
      final next = ref.watch(healthProvider(widget.scope)).value;
      if (active && !identical(current, next)) next?.resume();
      current = next;
    }
    return widget.child;
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.admission?.removeListener(_admissionChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
