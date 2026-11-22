import 'package:flutter/material.dart';

import 'widgets.dart';

class PracticeFallbackHeader extends StatelessWidget {
  const PracticeFallbackHeader({
    required this.busy,
    required this.now,
    super.key,
  });

  final bool busy;
  final DateTime Function() now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final day = now().toLocal();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageBrandLine(
          icon: Icons.forum_outlined,
          trailing: busy
              ? Semantics(
                  label: '正在加载练习首页',
                  child: const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
        ),
        const SizedBox(height: 18),
        Text(
          '${day.month} 月 ${day.day} 日',
          style: theme.textTheme.labelLarge?.copyWith(color: c.primary),
        ),
        const SizedBox(height: 6),
        Semantics(
          header: true,
          child: Text(
            '今天，练一件小事',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '今日数据暂时无法显示，自评、对练和场景切换仍可直接进入。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: c.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class PracticeContinueActions extends StatelessWidget {
  const PracticeContinueActions({required this.onGo, super.key});

  final Future<void> Function(String route) onGo;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeading('继续练习', subtitle: '这些入口不依赖今日数据，随时可以进入。'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, bounds) {
            final singleColumn =
                bounds.maxWidth < 380 ||
                MediaQuery.textScalerOf(context).scale(1) > 1.35;
            final width = singleColumn
                ? bounds.maxWidth
                : (bounds.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(
                  width: width,
                  child: _ActionButton(
                    icon: Icons.forum_outlined,
                    title: '对练与预演',
                    onTap: () => onGo('/training'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ActionButton(
                    icon: Icons.edit_note_rounded,
                    title: '本次自评与续答',
                    onTap: () => onGo('/assessment'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ActionButton(
                    icon: Icons.bookmark_add_outlined,
                    title: '手动标记',
                    onTap: () => onGo('/marks'),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: _ActionButton(
                    icon: Icons.tune_rounded,
                    title: '切换练习场景',
                    onTap: () => onGo('/scene'),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return Semantics(
      button: true,
      label: title,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Material(
          color: c.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: c.outlineVariant.withValues(alpha: .65)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 20, color: c.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.chevron_right,
                      size: 20,
                      color: c.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
