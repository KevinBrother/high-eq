import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../home/shell.dart';
import '../onboarding/radar.dart';
import 'models.dart';
import 'reminder_boundary.dart';
import 'repository.dart';
import 'widgets.dart';

class GrowthRoute extends ConsumerWidget {
  const GrowthRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(growthRepositoryProvider);
    return HomeShell(
      Section.growth,
      content: repository == null
          ? const SessionTransitionPane(label: '正在重新载入成长档案…')
          : GrowthPage(repository: repository),
    );
  }
}

class GrowthPage extends StatefulWidget {
  const GrowthPage({
    required this.repository,
    super.key,
    this.now = DateTime.now,
  });

  final GrowthRepository repository;
  final DateTime Function() now;

  @override
  State<GrowthPage> createState() => _GrowthPageState();
}

class _GrowthPageState extends State<GrowthPage> {
  GrowthSnapshot? _snapshot;
  Object? _error;
  bool _loading = true;
  bool _offline = false;
  int _generation = 0;
  ValueListenable<int>? _invalidations;
  bool _suppressInvalidationReload = false;

  @override
  void initState() {
    super.initState();
    _listenForInvalidation();
    _load();
  }

  @override
  void didUpdateWidget(covariant GrowthPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.repository, widget.repository)) return;
    _stopListeningForInvalidation();
    _generation++;
    _snapshot = null;
    _error = null;
    _loading = true;
    _offline = false;
    _listenForInvalidation();
    _load();
  }

  @override
  void dispose() {
    _stopListeningForInvalidation();
    super.dispose();
  }

  void _listenForInvalidation() {
    final repository = widget.repository;
    if (repository is! GrowthInvalidationSource) return;
    _invalidations = (repository as GrowthInvalidationSource).invalidations;
    _invalidations!.addListener(_onInvalidated);
  }

  void _stopListeningForInvalidation() {
    _invalidations?.removeListener(_onInvalidated);
    _invalidations = null;
  }

  void _onInvalidated() {
    if (!mounted) return;
    // A cache clear for 401/403 belongs to the same denied request. Keep its
    // message, and do not let another retained page's clear start an auth loop.
    final reload = !_suppressInvalidationReload && !growthAccessDenied(_error);
    _generation++;
    setState(() {
      _snapshot = null;
      _loading = reload;
      _offline = false;
      if (reload) _error = null;
    });
    if (reload) unawaited(_load(showLoading: false));
  }

  bool _isCurrent(int generation, GrowthRepository repository) =>
      mounted &&
      generation == _generation &&
      identical(widget.repository, repository);

  Future<void> _load({bool showLoading = true}) async {
    final generation = ++_generation;
    final repository = widget.repository;
    if (showLoading && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final snapshot = await repository.load();
      if (!_isCurrent(generation, repository)) return;
      setState(() {
        _snapshot = snapshot;
        _loading = false;
        _offline = false;
        _error = null;
      });
    } on SessionChanged {
      if (!_isCurrent(generation, repository)) return;
      setState(() {
        _loading = false;
        _snapshot = null;
        _offline = false;
        _error = SessionChanged();
      });
    } catch (error) {
      if (growthAccessDenied(error)) {
        if (!_isCurrent(generation, repository)) return;
        setState(() {
          _loading = false;
          _snapshot = null;
          _offline = false;
          _error = error;
        });
        _suppressInvalidationReload = true;
        try {
          await repository.clearCache();
        } catch (_) {
          // The rejected response must never make stale data visible again.
        } finally {
          _suppressInvalidationReload = false;
        }
        return;
      }
      GrowthSnapshot? cached;
      try {
        cached = await repository.cached();
      } catch (_) {
        // Retry remains available even if the encrypted cache is unreadable.
      }
      if (!_isCurrent(generation, repository)) return;
      setState(() {
        _loading = false;
        if (cached != null) {
          _snapshot = cached;
          _offline = true;
          _error = null;
        } else if (_snapshot == null) {
          _error = error;
          _offline = false;
        } else {
          _offline = true;
          _error = null;
        }
      });
    }
  }

  Future<void> _go(String route) async {
    await Navigator.pushNamed(context, route);
    if (mounted && route == '/assessment') {
      await _load(showLoading: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _snapshot == null) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: '正在加载成长档案',
          child: const CircularProgressIndicator(),
        ),
      );
    }
    final snapshot = _snapshot;
    if (snapshot == null) {
      return FailurePane(
        message: growthProblem(_error ?? StateError('empty')),
        onRetry: () => _load(),
      );
    }
    final scores = snapshot.scoredSessions;
    return ReminderBoundary(
      deadline: snapshot.latestAssessment?.nextEligibleAt,
      now: widget.now,
      onDue: () {
        if (mounted) setState(() {});
      },
      child: RefreshIndicator(
        onRefresh: () => _load(showLoading: false),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
          children: [
            _GrowthHeader(growth: snapshot.growth),
            const SizedBox(height: 22),
            if (_offline) ...[
              OfflineBanner(onRetry: () => _load()),
              const SizedBox(height: 14),
            ],
            _RetestReminder(
              latest: snapshot.latestAssessment,
              now: widget.now(),
              onRetest: () => _go('/assessment'),
            ),
            const SizedBox(height: 18),
            _AssessmentSection(
              snapshot: snapshot,
              onAssess: () => _go('/assessment'),
            ),
            const SizedBox(height: 22),
            _TrainingReferenceCard(growth: snapshot.growth),
            const SizedBox(height: 26),
            const SectionHeading(
              '历次对练得分',
              subtitle: '整场对练与单项练习分开记录；这里没有推算的日期。',
            ),
            const SizedBox(height: 12),
            if (scores.isEmpty)
              const EmptyState(
                icon: Icons.forum_outlined,
                title: '还没有可展示的得分',
                message: '完成一次整场对练或单项练习后，分数会按最近一次到更早一次排列。',
              )
            else
              _ScoreHistory(scores: scores),
            const SizedBox(height: 26),
            const SectionHeading(
              '阶段成就',
              subtitle: '连续 3 / 7 / 30 天。已获得的成就会保留，不因断卡消失。',
            ),
            const SizedBox(height: 12),
            GrowthSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, bounds) {
                      final title = Text(
                        '当前连续 ${snapshot.growth.streak} 天',
                        style: Theme.of(context).textTheme.titleMedium,
                      );
                      final badge = StreakBadge(snapshot.growth.streak);
                      if (useStackedLayout(
                        context,
                        bounds.maxWidth,
                        minInlineWidth: 280,
                      )) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [title, const SizedBox(height: 10), badge],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: title),
                          const SizedBox(width: 12),
                          badge,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  AchievementStrip(snapshot.growth.achievements),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GrowthHeader extends StatelessWidget {
  const _GrowthHeader({required this.growth});
  final GrowthData growth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageBrandLine(
          icon: Icons.spa_outlined,
          trailing: Text('成长档案', style: theme.textTheme.labelLarge),
        ),
        const SizedBox(height: 28),
        Semantics(
          header: true,
          child: Text(
            '回头看，变化有了形状',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'WLEIS 是你对自己的四维自评，雷达只画这四维。训练参考分由最近一次 WLEIS 自评总分与近 30 天有效整场对练、完整复盘的评分均值各占一半；单项练习不参与。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: c.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

class _AssessmentSection extends StatelessWidget {
  const _AssessmentSection({required this.snapshot, required this.onAssess});
  final GrowthSnapshot snapshot;
  final VoidCallback onAssess;

  @override
  Widget build(BuildContext context) {
    final latest = snapshot.latestAssessment;
    if (latest == null) {
      return EmptyState(
        icon: Icons.radar,
        title: '还没有 WLEIS 四维记录',
        message: '完成首次自评后，这里会显示四维雷达；再次复测后会出现前后对比。',
        action: FilledButton(onPressed: onAssess, child: const Text('开始自评')),
      );
    }
    final previous = snapshot.previousAssessment;
    final theme = Theme.of(context);
    final delta = previous == null
        ? null
        : latest.totalPercent - previous.totalPercent;
    return GrowthSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeading(
            'WLEIS 四维变化',
            subtitle: '雷达图只画 WLEIS 四维，不混入训练行为分。',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _ComparePill(
                label: previous == null ? '最近一次' : '最近一次总分',
                value: '${latest.totalPercent.round()} / 100',
              ),
              if (previous != null)
                _ComparePill(
                  label: '更早一次',
                  value: '${previous.totalPercent.round()} / 100',
                ),
              if (delta != null)
                _ComparePill(
                  label: '变化',
                  value: '${delta >= 0 ? '+' : ''}${delta.round()}',
                  accent: delta >= 0,
                ),
            ],
          ),
          const SizedBox(height: 12),
          AssessmentRadar(
            percentages: latest.dimensions,
            beforePercentages: previous?.dimensions,
            title: '四维雷达',
            currentLabel: '最近一次',
            beforeLabel: '更早一次',
          ),
          const SizedBox(height: 6),
          Text(
            '这是一份自我报告，不是能力诊断，也不使用“你就是这样的人”一类定论。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _ComparePill extends StatelessWidget {
  const _ComparePill({
    required this.label,
    required this.value,
    this.accent = false,
  });
  final String label;
  final String value;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Semantics(
      label: '$label，$value',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: accent ? c.tertiaryContainer : c.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 2),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrainingReferenceCard extends StatelessWidget {
  const _TrainingReferenceCard({required this.growth});
  final GrowthData growth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final score = growth.trainingReference;
    if (score == null) {
      return GrowthSurface(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(child: Icon(Icons.lock_outline, color: c.primary)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '训练参考分 · 待解锁',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(unlockBehaviorCopy, style: TextStyle(height: 1.5)),
                  const SizedBox(height: 6),
                  Text(
                    '单项练习只记录过关进度，不会生成行为分。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: c.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return GrowthSurface(
      color: c.secondaryContainer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(Icons.insights_outlined, color: c.onSecondaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '训练参考分',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: c.onSecondaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Semantics(
                  label: '训练参考分 ${score.round()} 分，满分 100 分',
                  child: ExcludeSemantics(
                    child: Text(
                      '${score.round()} / 100',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: c.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '取最近一次 WLEIS 自评总分与近 30 天 ${growth.validBehaviorCount} 次有效整场对练、完整复盘的评分均值，各占一半；单项练习不参与。',
                  style: TextStyle(color: c.onSecondaryContainer, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RetestReminder extends StatelessWidget {
  const _RetestReminder({
    required this.latest,
    required this.now,
    required this.onRetest,
  });
  final AssessmentData? latest;
  final DateTime now;
  final VoidCallback onRetest;

  @override
  Widget build(BuildContext context) {
    final assessment = latest;
    if (assessment == null) return const SizedBox.shrink();
    if (!now.isBefore(assessment.nextEligibleAt)) {
      return ReminderBanner(
        title: '四周复测已到期',
        message: '新的自评会和上次一起显示在雷达图上，方便看变化而不是给自己下结论。',
        actionLabel: '去复测',
        onAction: onRetest,
        icon: Icons.radar,
      );
    }
    final seconds = assessment.nextEligibleAt.difference(now).inSeconds;
    final days = (seconds / Duration.secondsPerDay).ceil();
    final local = assessment.nextEligibleAt.toLocal();
    final date = '${local.month} 月 ${local.day} 日';
    return ReminderBanner(
      title: '四周复测提醒',
      message: '还有 ${days < 1 ? 1 : days} 天可以复测，预计 $date。现在先继续日常练习就好。',
      icon: Icons.event_available_outlined,
    );
  }
}

class _ScoreTile extends StatelessWidget {
  const _ScoreTile({required this.index, required this.score});
  final int index;
  final PracticeScoreData score;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = score.completedAt == null
        ? '完成时间未记录'
        : switch (index) {
            0 => '最近一次',
            1 => '更早一次',
            _ => '第 ${index + 1} 次记录',
          };
    final single = score.mode == 'single_skill';
    final title = single
        ? '$order · 单项练习${score.targetItem == null ? '' : ' · ${_skillLabel(score.targetItem!)}'}'
        : '$order · 整场对练';
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, bounds) {
              final titleWidget = Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              );
              final scoreWidget = Text(
                '${score.total} / ${score.maximum}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              );
              if (useStackedLayout(
                context,
                bounds.maxWidth,
                minInlineWidth: 260,
              )) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titleWidget,
                    const SizedBox(height: 4),
                    scoreWidget,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: titleWidget),
                  const SizedBox(width: 10),
                  scoreWidget,
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Semantics(
            label: '$title，${score.total} 分，满分 ${score.maximum} 分',
            child: ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 7,
                  value: score.total / score.maximum,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            single ? '只记录这一项目标的过关进度，不计入训练参考分。' : '完整行为记录，可作为训练参考分的来源。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreHistory extends StatelessWidget {
  const _ScoreHistory({required this.scores});

  final List<PracticeScoreData> scores;

  @override
  Widget build(BuildContext context) {
    return GrowthSurface(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (index, score) in scores.indexed) ...[
            _ScoreTile(index: index, score: score),
            if (index != scores.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }
}

String _skillLabel(String item) => switch (item) {
  'observation' => '观察',
  'feeling' => '感受',
  'need' => '需要',
  'request' => '请求',
  _ => item,
};
