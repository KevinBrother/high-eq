import 'package:flutter/material.dart';
import '../../core/transport.dart';
import 'repository.dart';

class PracticeResult extends StatelessWidget {
  const PracticeResult(
    this.session, {
    this.previous,
    this.repeat,
    this.compareUnavailable = false,
    super.key,
  });
  final Json session;
  final bool compareUnavailable;
  final Json? previous;
  final VoidCallback? repeat;
  @override
  Widget build(BuildContext context) {
    final result = session['result'] as Json,
        single = result['mode'] == 'single_skill';
    final details = (single ? result['progress'] : result['score']) as Json;
    final total = (single ? details['score'] : details['nvc']['total']) as int;
    final before = previous?['mode'] != result['mode']
        ? null
        : single
        ? (previous?['progress']?['target_item'] == details['target_item']
              ? previous?['progress']?['score']
              : null)
        : previous?['score']?['nvc']?['total'];
    final users = (session['messages'] as List)
        .where((m) => m['role'] == 'user')
        .toList();
    final turn = details['target_turn'] as int?;
    final theme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Text(
          single ? '${skills[details['target_item']]} · 单项反馈' : '整场反馈',
          style: theme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(
          '${single ? '目标项' : 'NVC 总分'} $total / ${single ? 25 : 100}',
          style: theme.titleLarge,
        ),
        Text(
          before is int
              ? '上次 $before → 本次 $total（${total > before ? '+' : ''}${total - before} 分）'
              : compareUnavailable
              ? '暂时无法读取上次成绩，可稍后从历史查看。'
              : '暂无可比的上次成绩',
        ),
        const Divider(height: 32),
        if (single) ...[
          Text(details['reason']),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.flag_outlined),
            title: Text(switch (details['next_action']) {
              'pass' => '本关已通过',
              'retry_in_three_days' => '建议三天后重练',
              _ => '建议现在重练',
            }),
          ),
        ] else ...[
          Text('表达中的亮点与问题', style: theme.titleMedium),
          for (final k in skills.keys)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${skills[k]} · ${details['nvc'][k]['score']} / 25'),
              subtitle: Text(details['nvc'][k]['reason']),
            ),
          const Divider(),
          Text('这次互动', style: theme.titleMedium),
          for (final (key, label) in [
            ('read_others', '读懂别人'),
            ('self_management', '自我管理'),
            ('relationship', '关系效果（预估）'),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('$label · ${details['emotion'][key]['level']} / 5'),
              subtitle: Text(details['emotion'][key]['reason']),
            ),
          const Divider(),
          Text('换个说法', style: theme.titleLarge),
          if (turn != null && turn > 0 && turn <= users.length) ...[
            Text('第 $turn 次用户发言'),
            Text('「${users[turn - 1]['text']}」'),
          ],
          const SizedBox(height: 12),
          SelectableText(details['better_version'], style: theme.titleMedium),
          Text(details['why_better']),
        ],
        const SizedBox(height: 20),
        Text(settlementLabel(result['settlement'])),
        if (repeat != null)
          FilledButton.icon(
            onPressed: repeat,
            icon: const Icon(Icons.replay),
            label: const Text('再练一次'),
          ),
      ],
    );
  }
}
