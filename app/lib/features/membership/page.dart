import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/transport.dart';
import '../onboarding/surface.dart';
import 'store.dart';

class MemberPage extends StatefulWidget {
  const MemberPage(this.store, {super.key, this.onOpenEmotion});
  final MemberStore store;
  final VoidCallback? onOpenEmotion;
  @override
  State<MemberPage> createState() => _MemberState();
}

class _MemberState extends State<MemberPage> with WidgetsBindingObserver {
  Json? rights;
  bool busy = false, conflict = false;
  String plan = 'monthly';
  String? message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    run(load);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed && !busy) run(load);
  }

  Future<void> load() async {
    rights = await widget.store.rights();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
      conflict = false;
    });
    try {
      await action();
    } catch (e) {
      if (e is ApiFailure && e.status == 409) {
        conflict = true;
        message = '交易属于其他账号。请验证并登录原购买账号，再恢复购买；权益不会转移。';
      } else {
        message = friendlyError(e);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> purchase(String channel, {bool restore = false}) async {
    final store = widget.store;
    if (channel == 'apple') {
      final found = await store.apple(plan: restore ? null : plan);
      message = found ? '交易已交由服务端核验，权益以查询结果为准。' : '没有找到可恢复的交易。';
    } else {
      await store.android(channel, plan);
      message = '已发起支付，返回后请刷新确认到账。';
    }
    await load();
  }

  @override
  Widget build(BuildContext context) {
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    final r = rights;
    final member =
        r?['tier'] == 'member' &&
        (DateTime.tryParse(r?['expires_at'] ?? '')?.isAfter(DateTime.now()) ??
            false);
    return FlowSurface(
      widget.store.port.demo ? '会员手记   /   契约模拟 · 不扣款' : '会员手记   /   跨平台权益',
      member ? '你的会员空间' : '让练习更贴近自己',
      busy: busy,
      message: message,
      [
        if (conflict)
          OutlinedButton(
            onPressed: () =>
                run(() => widget.store.api.logout(widget.store.scope)),
            child: const Text('退出并验证原账号'),
          ),
        const Text('免费也可使用自评与雷达、小练习、卡片、通用计划和 1 位关系人。手动标记和查看记录不扣 AI 次数。'),
        const Divider(height: 32),
        Text('今日额度', style: Theme.of(context).textTheme.titleLarge),
        if (r != null)
          for (final a in r['allowances']) QuotaLine(a),
        TextButton(onPressed: () => run(load), child: const Text('刷新权益')),
        const Divider(height: 32),
        Text('会员包含什么', style: Theme.of(context).textTheme.titleLarge),
        const Text(
          '不限次对练、回复助手和文字复盘，更多关系人、个性化计划、录音与心率对齐回放，以及按对象和场景汇总的情绪画像。使用传感器前另行征求同意。',
        ),
        if (widget.onOpenEmotion case final openEmotion?)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.insights_outlined),
            title: const Text('查看本人情绪汇总'),
            trailing: const Icon(Icons.chevron_right),
            onTap: openEmotion,
          ),
        const SizedBox(height: 18),
        Text(ios ? 'Apple 自动续期订阅，可在系统设置取消。' : '安卓月卡或年卡，一次性购买，不自动续费。'),
        Wrap(
          spacing: 10,
          children: [
            for (final (id, title) in [('monthly', '月度'), ('yearly', '年度')])
              ChoiceChip(
                label: Text(title),
                selected: plan == id,
                onSelected: (_) => setState(() => plan = id),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (r != null) ...[
          if (ios) ...[
            FilledButton(
              onPressed: () => run(() => purchase('apple')),
              child: const Text('通过 Apple 订阅'),
            ),
            OutlinedButton(
              onPressed: () => run(() => purchase('apple', restore: true)),
              child: const Text('恢复购买'),
            ),
          ] else ...[
            FilledButton(
              onPressed: () => run(() => purchase('wechat')),
              child: const Text('微信支付'),
            ),
            OutlinedButton(
              onPressed: () => run(() => purchase('alipay')),
              child: const Text('支付宝支付'),
            ),
            TextButton(onPressed: () => run(load), child: const Text('恢复账号权益')),
          ],
        ],
      ],
    );
  }
}

class QuotaLine extends StatelessWidget {
  const QuotaLine(this.row, {super.key});
  final Json row;
  @override
  Widget build(BuildContext context) {
    final name = const {
      'practice': '对练',
      'reply': '回复助手',
      'review': '文字复盘',
    }[row['feature']];
    final n = row['remaining'];
    final reset = DateTime.tryParse(row['resets_at'] ?? '')?.toLocal();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('$name · ${n == null ? '不限次' : '剩余 $n 次'}'),
      subtitle: n == 0
          ? Text(
              '今日限次已用尽。${reset == null ? '请在额度重置后再来' : '${reset.month} 月 ${reset.day} 日 ${reset.hour}:${reset.minute.toString().padLeft(2, '0')} 重置（本地时间）'}，也可选择会员。',
            )
          : null,
    );
  }
}
