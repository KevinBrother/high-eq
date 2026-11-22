import 'package:flutter/material.dart';

import 'model.dart';

class ReviewResultPanel extends StatelessWidget {
  const ReviewResultPanel({
    super.key,
    required this.attempt,
    required this.onRewrite,
    required this.onRetry,
    required this.busy,
  });

  final ReviewAttempt attempt;
  final VoidCallback onRewrite;
  final VoidCallback onRetry;
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
        children: switch (attempt) {
          ReviewReady(:final record) => [
            _ReadyResult(record: record, onRewrite: onRewrite),
          ],
          ReviewSafety(:final message) => [
            _SafetyResult(message: message, onRewrite: onRewrite),
          ],
          ReviewProcessing() => [
            _ProcessingResult(onRetry: onRetry, busy: busy),
          ],
        },
      ),
    ),
  );
}

class _ReadyResult extends StatelessWidget {
  const _ReadyResult({required this.record, required this.onRewrite});
  final ReviewRecord record;
  final VoidCallback onRewrite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final score = record.score;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.auto_awesome, color: colors.primary),
            const SizedBox(width: 8),
            Text('这次复盘', style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 22),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '${score.total}',
                  style: theme.textTheme.displayLarge?.copyWith(
                    color: colors.onPrimaryContainer,
                    fontWeight: FontWeight.w800,
                    height: 0.95,
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    '/ 100',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                Flexible(
                  flex: 2,
                  child: Text(
                    '不是给你下结论，只是看看哪一步还能更清楚。',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onPrimaryContainer,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        _SectionTitle('一句可以试着说的话'),
        const SizedBox(height: 10),
        SelectableText(
          record.repairPhrase,
          style: theme.textTheme.headlineSmall?.copyWith(height: 1.45),
        ),
        const SizedBox(height: 18),
        _SectionTitle('为什么这样说'),
        const SizedBox(height: 7),
        Text(
          score.whyBetter,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
        ),
        const SizedBox(height: 18),
        _SectionTitle('更完整的表达'),
        const SizedBox(height: 7),
        SelectableText(
          score.betterVersion,
          style: theme.textTheme.bodyLarge?.copyWith(height: 1.55),
        ),
        const SizedBox(height: 24),
        _SectionTitle('拆开看四步'),
        const SizedBox(height: 10),
        _ScoreRow(label: '观察', line: score.observation),
        _ScoreRow(label: '感受', line: score.feeling),
        _ScoreRow(label: '需要', line: score.need),
        _ScoreRow(label: '请求', line: score.request),
        const SizedBox(height: 20),
        _SectionTitle('关系中的三个提醒'),
        const SizedBox(height: 10),
        _LevelRow(label: '读懂对方', line: score.readOthers),
        _LevelRow(label: '照顾自己', line: score.selfManagement),
        _LevelRow(label: '修复关系', line: score.relationship),
        const SizedBox(height: 24),
        FilledButton.tonalIcon(
          onPressed: onRewrite,
          icon: const Icon(Icons.edit_note_outlined),
          label: const Text('再写一次'),
        ),
        const SizedBox(height: 8),
        Text(
          '这次复盘已保存到踩坑本。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _SafetyResult extends StatelessWidget {
  const _SafetyResult({required this.message, required this.onRewrite});
  final String message;
  final VoidCallback onRewrite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.errorContainer,
            borderRadius: BorderRadius.circular(26),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.favorite_outline, color: colors.onErrorContainer),
                const SizedBox(height: 18),
                Text(
                  '先照顾现在的安全',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    color: colors.onErrorContainer,
                  ),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  message,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.onErrorContainer,
                    height: 1.65,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          '这一次不会展示评分。如果你愿意，可以修改内容后重新写；也可以先联系身边可信任的人。',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.onSurfaceVariant,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: onRewrite,
          icon: const Icon(Icons.edit_note_outlined),
          label: const Text('重新写一次'),
        ),
      ],
    );
  }
}

class _ProcessingResult extends StatelessWidget {
  const _ProcessingResult({required this.onRetry, required this.busy});
  final VoidCallback onRetry;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 30),
        Icon(
          Icons.hourglass_top_rounded,
          size: 56,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 18),
        Text(
          'AI 仍在处理中',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 10),
        Text(
          '原请求已经保留。稍后查看结果会继续使用同一个请求编号，不会重复创建复盘。',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 22),
        FilledButton.tonal(
          onPressed: busy ? null : onRetry,
          child: const Text('查看原请求结果'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
  );
}

class _ScoreRow extends StatelessWidget {
  const _ScoreRow({required this.label, required this.line});
  final String label;
  final ScoreLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(label, style: theme.textTheme.labelLarge),
          ),
          SizedBox(
            width: 44,
            child: Text(
              '${line.score}',
              textAlign: TextAlign.right,
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(line.reason)),
        ],
      ),
    );
  }
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({required this.label, required this.line});
  final String label;
  final LevelLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.labelLarge)),
              Text('${line.level} / 5', style: theme.textTheme.labelMedium),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: line.level / 5,
              minHeight: 5,
              backgroundColor: colors.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 5),
          Text(line.reason, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
