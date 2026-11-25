import 'package:flutter/material.dart';

import 'model.dart';

class ReviewForm extends StatelessWidget {
  const ReviewForm({
    super.key,
    required this.stage,
    required this.happened,
    required this.myFeeling,
    required this.theirFeeling,
    required this.myAction,
    required this.nextAction,
    required this.prefill,
    required this.contactName,
    required this.onChanged,
    required this.onNext,
    required this.onBack,
    required this.onSubmit,
    required this.busy,
    required this.saving,
    required this.error,
    required this.onRetry,
    this.onViewQuota,
  });

  final int stage;
  final TextEditingController happened;
  final TextEditingController myFeeling;
  final TextEditingController theirFeeling;
  final TextEditingController myAction;
  final TextEditingController nextAction;
  final ReviewPrefill? prefill;
  final String? contactName;
  final ValueChanged<String> onChanged;
  final VoidCallback? onNext;
  final VoidCallback? onBack;
  final VoidCallback? onSubmit;
  final bool busy;
  final bool saving;
  final String? error;
  final VoidCallback? onRetry;
  final VoidCallback? onViewQuota;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
          children: [
            Text('把刚才的对话，慢慢拆开看。', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '按四步写完再提交。草稿只保存在本机；打开页面或保存草稿不扣次。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.55,
              ),
            ),
            if (prefill != null) ...[
              const SizedBox(height: 18),
              _PrefillNote(prefill: prefill!, contactName: contactName),
            ],
            const SizedBox(height: 22),
            _StepRail(stage: stage),
            const SizedBox(height: 18),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: switch (stage) {
                    0 => _stageOne(context),
                    1 => _stageTwo(context),
                    2 => _stageThree(context),
                    _ => _stageFour(context),
                  },
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 14),
              _RetryNotice(message: error!, onRetry: onRetry),
            ],
            if (onViewQuota != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onViewQuota,
                  child: const Text('查看额度与重置时间'),
                ),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  saving ? Icons.sync : Icons.lock_outline,
                  size: 17,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    saving ? '正在保存草稿…' : '草稿已加密保存在本机',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stageOne(BuildContext context) => _stage(
    context,
    key: const ValueKey(0),
    eyebrow: '01 · 发生了什么',
    title: '发生了什么',
    hint: '只写你亲眼看到、亲耳听到的行动，不急着解释谁对谁错。',
    children: [
      _field(
        key: 'review.happened',
        controller: happened,
        label: '当时的经过',
        hint: '例如：同事在我汇报时打断了我。',
        minLines: 4,
      ),
      _nextButton(),
    ],
  );

  Widget _stageTwo(BuildContext context) => _stage(
    context,
    key: const ValueKey(1),
    eyebrow: '02 · 感受',
    title: '你和他，各自可能有什么感受？',
    hint: '先照顾自己的感受，再给对方的感受留一个“可能”。',
    children: [
      _field(
        key: 'review.myFeeling',
        controller: myFeeling,
        label: '我的感受',
        hint: '例如：着急、难堪、委屈。',
        minLines: 3,
      ),
      const SizedBox(height: 12),
      _field(
        key: 'review.theirFeeling',
        controller: theirFeeling,
        label: '对方可能的感受',
        hint: '只写推测，不把它当成事实。',
        minLines: 3,
      ),
      _nextButton(),
    ],
  );

  Widget _stageThree(BuildContext context) => _stage(
    context,
    key: const ValueKey(2),
    eyebrow: '03 · 我的行动',
    title: '我当时具体做了什么？',
    hint: '这一句会成为评分重点：写清你实际说出的话或做出的动作。',
    children: [
      _field(
        key: 'review.myAction',
        controller: myAction,
        label: '我的行动',
        hint: '例如：我提高声音说：你先听我说完。',
        minLines: 4,
      ),
      _nextButton(),
    ],
  );

  Widget _stageFour(BuildContext context) => _stage(
    context,
    key: const ValueKey(3),
    eyebrow: '04 · 下一次',
    title: '下次可以怎么做？',
    hint: '写一个下次真的能做到的小动作，不必一次解决所有问题。',
    children: [
      _field(
        key: 'review.nextAction',
        controller: nextAction,
        label: '下一次的做法',
        hint: '例如：先停一下，问对方想补充什么。',
        minLines: 4,
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: busy ? null : onSubmit,
        icon: Icon(
          busy ? Icons.hourglass_top_rounded : Icons.auto_awesome_outlined,
        ),
        label: Text(busy ? '正在提交…' : '提交 AI 复盘'),
      ),
      const SizedBox(height: 6),
      Text(
        '只提交这五段文字；不会上传录音。成功生成后才计一次。',
        style: Theme.of(context).textTheme.bodySmall,
        textAlign: TextAlign.center,
      ),
    ],
  );

  Widget _stage(
    BuildContext context, {
    required Key key,
    required String eyebrow,
    required String title,
    required String hint,
    required List<Widget> children,
  }) {
    final theme = Theme.of(context);
    return Column(
      key: key,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          eyebrow,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.primary,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          hint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        ...children,
        if (stage > 0) ...[
          const SizedBox(height: 4),
          TextButton(onPressed: busy ? null : onBack, child: const Text('上一步')),
        ],
      ],
    );
  }

  Widget _field({
    required String key,
    required TextEditingController controller,
    required String label,
    required String hint,
    required int minLines,
  }) => TextField(
    key: Key(key),
    controller: controller,
    enabled: !busy,
    minLines: minLines,
    maxLines: minLines + 3,
    textInputAction: TextInputAction.newline,
    enableIMEPersonalizedLearning: false,
    onChanged: onChanged,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      alignLabelWithHint: true,
      border: const OutlineInputBorder(),
    ),
  );

  Widget _nextButton() => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Align(
      alignment: Alignment.centerRight,
      child: FilledButton.tonal(
        onPressed: busy ? null : onNext,
        child: const Text('下一步'),
      ),
    ),
  );
}

class _StepRail extends StatelessWidget {
  const _StepRail({required this.stage});
  final int stage;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const labels = ['经过', '感受', '行动', '下一次'];
    return Semantics(
      label: '复盘进度，第 ${stage + 1} 步，共 4 步',
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            Expanded(
              child: Column(
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 4,
                    decoration: BoxDecoration(
                      color: i <= stage
                          ? colors.primary
                          : colors.outlineVariant,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    labels[i],
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: i == stage
                          ? colors.primary
                          : colors.onSurfaceVariant,
                      fontWeight: i == stage ? FontWeight.w700 : null,
                    ),
                  ),
                ],
              ),
            ),
            if (i != labels.length - 1) const SizedBox(width: 7),
          ],
        ],
      ),
    );
  }
}

class _PrefillNote extends StatelessWidget {
  const _PrefillNote({required this.prefill, required this.contactName});
  final ReviewPrefill prefill;
  final String? contactName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final at = prefill.occurredAt;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bookmark_added_outlined, color: colors.primary),
                const SizedBox(width: 8),
                Text('从标记开始', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [
                if (at != null) Text(_stamp(at)),
                Text(
                  '对象：${contactName ?? (prefill.contactId == null ? '未关联' : '已关联对象')}',
                ),
                Text('场景：${prefill.scene?.label ?? '未指定'}'),
              ],
            ),
            const SizedBox(height: 8),
            Text('已带上时间、对象和场景；不会读取或上传录音。', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _RetryNotice extends StatelessWidget {
  const _RetryNotice({required this.message, required this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('重试原请求')),
          ],
        ),
      ),
    );
  }
}

String _stamp(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
