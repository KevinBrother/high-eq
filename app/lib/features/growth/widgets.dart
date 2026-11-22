import 'package:flutter/material.dart';

import 'models.dart';

class GrowthSurface extends StatelessWidget {
  const GrowthSurface({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(20),
    this.color,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .6),
      ),
    ),
    child: Padding(padding: padding, child: child),
  );
}

bool useStackedLayout(
  BuildContext context,
  double width, {
  double minInlineWidth = 300,
}) =>
    width < minInlineWidth || MediaQuery.textScalerOf(context).scale(1) > 1.35;

class PageBrandLine extends StatelessWidget {
  const PageBrandLine({required this.icon, this.trailing, super.key});

  final IconData icon;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text('对话手记', style: theme.textTheme.titleSmall),
          ],
        ),
        ?trailing,
      ],
    );
  }
}

class SectionHeading extends StatelessWidget {
  const SectionHeading(this.title, {super.key, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleLarge),
        ),
        if (subtitle case final text?) ...[
          const SizedBox(height: 4),
          Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    final action = trailing;
    if (action == null) return heading;
    return LayoutBuilder(
      builder: (context, bounds) {
        if (useStackedLayout(context, bounds.maxWidth, minInlineWidth: 280)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child: action),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: heading),
            const SizedBox(width: 12),
            action,
          ],
        );
      },
    );
  }
}

class StreakBadge extends StatelessWidget {
  const StreakBadge(this.days, {super.key});
  final int days;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      label: '已连续练习 $days 天',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: c.tertiaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.local_fire_department,
                size: 18,
                color: c.onTertiaryContainer,
              ),
              const SizedBox(width: 6),
              Text(
                '连续 $days 天',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: c.onTertiaryContainer,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.onRetry});
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '当前显示这台设备上的离线数据，历史成就会保留。',
      child: GrowthSurface(
        color: c.secondaryContainer,
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: LayoutBuilder(
          builder: (context, bounds) {
            final message = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.cloud_off_outlined,
                    color: c.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ExcludeSemantics(
                    child: Text(
                      '当前显示这台设备上的离线数据，历史成就会保留。',
                      style: TextStyle(color: c.onSecondaryContainer),
                    ),
                  ),
                ),
              ],
            );
            final retry = onRetry == null
                ? null
                : TextButton(onPressed: onRetry, child: const Text('重试'));
            if (useStackedLayout(
              context,
              bounds.maxWidth,
              minInlineWidth: 250,
            )) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  message,
                  if (retry != null) ...[
                    const SizedBox(height: 4),
                    Align(alignment: Alignment.centerRight, child: retry),
                  ],
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: message),
                if (retry != null) ...[const SizedBox(width: 8), retry],
              ],
            );
          },
        ),
      ),
    );
  }
}

class ReminderBanner extends StatelessWidget {
  const ReminderBanner({
    required this.title,
    required this.message,
    super.key,
    this.actionLabel,
    this.onAction,
    this.icon = Icons.notifications_active_outlined,
  });

  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '$title。$message',
      child: GrowthSurface(
        color: c.primaryContainer,
        child: LayoutBuilder(
          builder: (context, bounds) {
            final copy = ExcludeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: c.onPrimaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: TextStyle(color: c.onPrimaryContainer, height: 1.45),
                  ),
                ],
              ),
            );
            final action = actionLabel != null && onAction != null
                ? TextButton(onPressed: onAction, child: Text(actionLabel!))
                : null;
            final stacked = useStackedLayout(
              context,
              bounds.maxWidth,
              minInlineWidth: 260,
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(icon, color: c.onPrimaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      copy,
                      if (action != null) ...[
                        const SizedBox(height: 10),
                        if (stacked)
                          Align(alignment: Alignment.centerLeft, child: action)
                        else
                          action,
                      ],
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class AchievementStrip extends StatelessWidget {
  const AchievementStrip(this.unlocked, {super.key, this.compact = false});

  final List<int> unlocked;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final days in achievementDays)
          Semantics(
            container: true,
            label: unlocked.contains(days)
                ? '成就，连续 $days 天，已达成'
                : '成就，连续 $days 天，未达成',
            child: ExcludeSemantics(
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 10 : 12,
                  vertical: compact ? 7 : 9,
                ),
                decoration: BoxDecoration(
                  color: unlocked.contains(days)
                      ? c.tertiaryContainer
                      : c.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      unlocked.contains(days)
                          ? Icons.workspace_premium
                          : Icons.lock_outline,
                      size: 18,
                      color: unlocked.contains(days)
                          ? c.onTertiaryContainer
                          : c.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$days 天',
                      style: TextStyle(
                        color: unlocked.contains(days)
                            ? c.onTertiaryContainer
                            : c.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    super.key,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GrowthSurface(
      child: Column(
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: 36, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 14), action!],
        ],
      ),
    );
  }
}

class FailurePane extends StatelessWidget {
  const FailurePane({required this.message, required this.onRetry, super.key});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          FilledButton.tonal(onPressed: onRetry, child: const Text('重新加载')),
        ],
      ),
    ),
  );
}

Future<void> showAchievementDialog(
  BuildContext context,
  List<int> newAchievements,
) {
  if (newAchievements.isEmpty) return Future.value();
  final days = newAchievements.reduce((a, b) => a > b ? a : b);
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.workspace_premium),
      title: const Text('新成就解锁'),
      content: Text('你已经连续练习 $days 天。把练习放进日常，比一次做很多更重要。'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('收下'),
        ),
      ],
    ),
  );
}
