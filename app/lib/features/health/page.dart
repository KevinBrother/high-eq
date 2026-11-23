import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/session.dart';
import 'binding.dart';
import 'sync.dart';

class HealthPage extends ConsumerWidget {
  final AccountScope scope;
  const HealthPage(this.scope, {super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: const Text('健康数据')),
    body: SafeArea(
      child: ref
          .watch(healthProvider(scope))
          .when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => const Center(child: Text('无法打开本机设置，请稍后重试。')),
            data: (s) => s == null
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('当前为演示环境，不会申请权限或读取设备健康数据。'),
                    ),
                  )
                : _Controls(s),
          ),
    ),
  );
}

class _Controls extends StatefulWidget {
  final HealthSync sync;
  const _Controls(this.sync);
  @override
  State<_Controls> createState() => _ControlsState();
}

class _ControlsState extends State<_Controls> {
  String? mode, message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    widget.sync.mode.addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.sync.mode.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    try {
      final m = (await widget.sync.state())['mode'] as String;
      final available = m != 'off' || await widget.sync.port.source() != null;
      if (mounted) setState(() => mode = available ? m : 'unavailable');
    } catch (_) {
      if (mounted) setState(() => message = '无法读取设置，请返回后重试。');
    }
  }

  Future<void> change(bool enable) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      if (enable) {
        if (!await widget.sync.member()) {
          if (mounted) setState(() => message = '此功能需要有效会员。其他练习不受影响。');
          return;
        }
        if (!mounted) return;
        final choice = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('同意读取健康数据？'),
            scrollable: true,
            content: const Text(
              '心率、心率变异性（HRV）、步数、步频和训练状态属于敏感信息。为了建立你的个人基线，手机会将它们按 30 秒汇总，仅上传统计值、时间和运动标志，服务端加密保留 180 天。历史数据仅用于基线和事后复盘，不会触发当下提醒。\n\n下一步由系统询问读取权限；安卓还需允许运动识别。拒绝不影响其他练习。你可随时在这里撤回并清除未发窗口。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('暂不开启'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('单独同意并继续'),
              ),
            ],
          ),
        );
        if (choice != true || !mounted) return;
        await widget.sync.enable();
      } else {
        await widget.sync.withdraw();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              message = enable ? '未能开启，请检查会员、网络与系统健康权限。' : '未能确认服务端撤回，请联网后重试。',
        );
      }
    } finally {
      await load();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> resolveUnknown(bool withdraw) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.sync.resolveUnknown(withdraw: withdraw);
    } catch (_) {
      if (mounted) {
        setState(
          () => message = withdraw ? '未能确认撤回健康授权，请联网后重试。' : '未能更新本机状态，请稍后重试。',
        );
      }
    } finally {
      await load();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> confirmUnknownWithdrawal() async {
    if (busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认撤回健康授权？'),
        content: const Text(
          '本机无法确认上次是否已经撤回。只有你确认后，才会向服务端提交撤回；这不会重新开启健康授权，也不会补传旧窗口。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认撤回'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await resolveUnknown(true);
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Icon(
        Icons.monitor_heart_outlined,
        color: Theme.of(context).colorScheme.primary,
        size: 42,
      ),
      const SizedBox(height: 24),
      Text('个人健康基线', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 10),
      const Text('健康历史用于事后回顾，不作实时判断。手表数据可能延迟；没有 HRV 也能使用心率和步频。'),
      const Divider(height: 40),
      Text(switch (mode) {
        'on' => '已开启 · 仅同步系统可读的数据',
        'withdraw' => '本机已停止 · 待确认服务端撤回',
        'unknown' => '本机已停止 · 上次退出时无法确认健康授权状态，请由本人确认。',
        'off' => '尚未开启',
        'paused' => '授权或会员资格已变化，已停止同步。',
        'pending' => '已获系统许可 · 回到前台后完成校验。',
        'unavailable' => '此设备或发行渠道暂不支持健康历史。',
        _ => '正在读取设置…',
      }),
      if (mode == 'unknown')
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('在确认前，本机不会读取、上传或补传健康数据。你可以维持停止，或明确确认撤回。'),
        ),
      if (message != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(message!, semanticsLabel: message),
        ),
      const SizedBox(height: 20),
      if (mode == 'off' || mode == 'paused')
        FilledButton(
          onPressed: busy ? null : () => change(true),
          child: const Text('开启健康数据'),
        ),
      if (mode == 'unknown') ...[
        FilledButton(
          onPressed: busy ? null : () => resolveUnknown(false),
          child: const Text('维持停止，暂不撤回'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: busy ? null : confirmUnknownWithdrawal,
          child: const Text('确认撤回健康授权'),
        ),
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).maybePop(),
          child: const Text('稍后处理'),
        ),
      ],
      if (mode == 'on' ||
          mode == 'withdraw' ||
          mode == 'paused' ||
          mode == 'pending')
        OutlinedButton(
          onPressed: busy ? null : () => change(false),
          child: Text(mode == 'withdraw' ? '重试同步撤回' : '撤回同意并清除未发窗口'),
        ),
    ],
  );
}
