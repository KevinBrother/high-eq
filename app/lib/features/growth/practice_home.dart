import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../home/shell.dart';
import 'models.dart';
import 'practice_home_actions.dart';
import 'reminder_boundary.dart';
import 'repository.dart';
import 'widgets.dart';

class PracticeHomeRoute extends ConsumerWidget {
  const PracticeHomeRoute({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repository = ref.watch(growthRepositoryProvider);
    return HomeShell(
      Section.practice,
      content: repository == null
          ? const SessionTransitionPane(label: '正在重新载入练习首页…')
          : PracticeHomePage(repository: repository),
    );
  }
}

class PracticeHomePage extends StatefulWidget {
  const PracticeHomePage({
    required this.repository,
    super.key,
    this.now = DateTime.now,
  });

  final GrowthRepository repository;
  final DateTime Function() now;

  @override
  State<PracticeHomePage> createState() => _PracticeHomePageState();
}

class _PracticeHomePageState extends State<PracticeHomePage> {
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
  void didUpdateWidget(covariant PracticeHomePage oldWidget) {
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
        // A corrupt or unavailable cache must not hide the retry path.
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

  Future<void> _openItem(PlanItemData item) async {
    if (item.completed) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这项今天已经完成了。')));
      return;
    }
    if (item.kind == PlanKind.level) {
      await Navigator.pushNamed(
        context,
        '/training',
        arguments: item.contentId,
      );
      if (mounted) await _load(showLoading: false);
      return;
    }
    final completion = await showModalBottomSheet<CompletionData>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FractionallySizedBox(
        heightFactor: item.kind == PlanKind.exercise ? .92 : .9,
        child: item.kind == PlanKind.exercise
            ? ExerciseSheet(repository: widget.repository, item: item)
            : CardSheet(
                repository: widget.repository,
                contentId: item.contentId,
                completionItemId: item.id,
                title: item.title,
              ),
      ),
    );
    if (completion != null && mounted) await _completed(item, completion);
  }

  Future<void> _completed(PlanItemData item, CompletionData result) async {
    final old = _snapshot;
    if (old == null) return;
    final repository = widget.repository;
    final generation = _generation;
    if (!_isCurrent(generation, repository)) return;
    final before = old.growth.achievements.toSet();
    final added = [
      for (final days in result.achievements)
        if (!before.contains(days)) days,
    ];
    final next = old.withCompletion(
      item.id,
      result.streak,
      result.achievements,
    );
    // A completion is newer than every read that was already in flight. Make
    // those reads stale before showing the authoritative completion state.
    _generation++;
    final completedGeneration = _generation;
    setState(() {
      _snapshot = next;
      _loading = false;
      _offline = false;
      _error = null;
    });
    try {
      await repository.saveCache(next);
    } catch (_) {
      // The server has accepted completion; a cache write failure must not
      // roll back the visible streak or achievement.
    }
    if (!mounted) return;
    if (!_isCurrent(completedGeneration, repository)) return;
    if (added.isNotEmpty) {
      await showAchievementDialog(context, added);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已打卡 · 连续 ${result.streak} 天')));
    }
  }

  Future<void> _openCard(KnowledgeCardData card) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(
      heightFactor: .86,
      child: CardSheet(
        repository: widget.repository,
        contentId: card.id,
        title: card.title,
      ),
    ),
  );

  Future<void> _go(String route) async {
    await Navigator.pushNamed(context, route);
    if (mounted && {'/assessment', '/training'}.contains(route)) {
      await _load(showLoading: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return ReminderBoundary(
      deadline: snapshot?.latestAssessment?.nextEligibleAt,
      now: widget.now,
      onDue: () {
        if (mounted) setState(() {});
      },
      child: RefreshIndicator(
        onRefresh: () => _load(showLoading: false),
        // The fallback actions must also remain discoverable after returning
        // from a paused assessment, even when they are below the fold.
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (snapshot == null)
                PracticeFallbackHeader(busy: _loading, now: widget.now)
              else
                _PracticeHeader(snapshot: snapshot, busy: _loading),
              const SizedBox(height: 16),
              if (snapshot != null) ...[
                if (_offline) ...[
                  OfflineBanner(onRetry: () => _load()),
                  const SizedBox(height: 14),
                ],
                _reminder(snapshot),
                const SizedBox(height: 16),
                _PlanCard(snapshot: snapshot, onOpen: _openItem),
                const SizedBox(height: 22),
                PracticeContinueActions(onGo: _go),
                const SizedBox(height: 26),
                SectionHeading(
                  '知识卡',
                  subtitle: '一张卡只练一个沟通动作，读完就能用。',
                  trailing: snapshot.cards.length > 2
                      ? TextButton(
                          onPressed: () => _go('/growth'),
                          child: const Text('看成长'),
                        )
                      : null,
                ),
                const SizedBox(height: 12),
                if (snapshot.cards.isEmpty)
                  const EmptyState(
                    icon: Icons.style_outlined,
                    title: '今天暂无知识卡',
                    message: '可以先完成一项小练习，新的卡片会出现在这里。',
                  )
                else
                  for (final card in snapshot.cards.take(2)) ...[
                    _KnowledgeCardTile(
                      card: card,
                      onTap: () => _openCard(card),
                    ),
                    const SizedBox(height: 10),
                  ],
                const SizedBox(height: 26),
                SectionHeading(
                  '坚持的痕迹',
                  subtitle: '连续完成任意一项计划即计为一天。',
                  trailing: TextButton(
                    onPressed: () => _go('/growth'),
                    child: const Text('成长档案'),
                  ),
                ),
                const SizedBox(height: 12),
                GrowthSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '连续 ${snapshot.growth.streak} 天',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      const Text('阶段成就不会因为断卡而清空。'),
                      const SizedBox(height: 14),
                      AchievementStrip(snapshot.growth.achievements),
                    ],
                  ),
                ),
              ] else ...[
                if (_loading)
                  SizedBox(
                    height: 120,
                    child: Center(
                      child: Semantics(
                        liveRegion: true,
                        label: '正在加载练习首页',
                        child: const CircularProgressIndicator(),
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: 280,
                    child: FailurePane(
                      message: growthProblem(_error ?? StateError('empty')),
                      onRetry: () => _load(),
                    ),
                  ),
                const SizedBox(height: 22),
                PracticeContinueActions(onGo: _go),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _reminder(GrowthSnapshot snapshot) {
    final latest = snapshot.latestAssessment;
    if (latest != null && !widget.now().isBefore(latest.nextEligibleAt)) {
      return ReminderBanner(
        title: '四周复测已到期',
        message: '可以重新看看此刻的自己。复测结果会与上次一起显示在雷达图上。',
        actionLabel: '去复测',
        onAction: () => _go('/assessment'),
        icon: Icons.radar,
      );
    }
    if (snapshot.plan.empty) {
      return ReminderBanner(
        title: '今天还没有练习安排',
        message: '先去对练或读一张知识卡，今天也能留下一点练习痕迹。',
        actionLabel: '去练习',
        onAction: () => _go('/training'),
        icon: Icons.wb_sunny_outlined,
      );
    }
    if (snapshot.plan.completed < snapshot.plan.items.length) {
      return ReminderBanner(
        title: '今天的小练习还在等你',
        message: '完成任意一项就会打卡，不必一次做完。',
        actionLabel: '先做一项',
        onAction: () {
          final next = snapshot.plan.items
              .where((item) => !item.completed)
              .firstOrNull;
          if (next != null) _openItem(next);
        },
      );
    }
    return const ReminderBanner(
      title: '今天的计划已完成',
      message: '可以提前休息，也可以再练一场。明天会继续为你安排。',
      icon: Icons.check_circle_outline,
    );
  }
}

class _PracticeHeader extends StatelessWidget {
  const _PracticeHeader({required this.snapshot, required this.busy});
  final GrowthSnapshot snapshot;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final day = DateTime.tryParse(snapshot.plan.day);
    final date = day == null ? '今天' : '${day.month} 月 ${day.day} 日';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageBrandLine(
          icon: Icons.forum_outlined,
          trailing: busy
              ? Semantics(
                  label: '正在刷新练习首页',
                  child: const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : StreakBadge(snapshot.growth.streak),
        ),
        const SizedBox(height: 18),
        Text(
          date,
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
          snapshot.plan.personalized
              ? '计划参考了你的当前测评。每项都能单独完成。'
              : '从通用练习开始，完成一项就算今天有进步。',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: c.onSurfaceVariant,
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({required this.snapshot, required this.onOpen});
  final GrowthSnapshot snapshot;
  final ValueChanged<PlanItemData> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final total = snapshot.plan.items.length;
    final done = snapshot.plan.completed;
    return GrowthSurface(
      color: c.primaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PlanHeading(
            done: done,
            total: total,
            personalized: snapshot.plan.personalized,
          ),
          const SizedBox(height: 12),
          Semantics(
            label: total == 0 ? '今日计划为空' : '今日计划，已完成 $done 项，共 $total 项',
            child: ExcludeSemantics(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  minHeight: 8,
                  value: total == 0 ? 0 : done / total,
                  backgroundColor: c.onPrimaryContainer.withValues(alpha: .12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (snapshot.plan.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '完成测评后会自动生成计划；也可以先自由练习。',
                style: TextStyle(color: c.onPrimaryContainer, height: 1.45),
              ),
            )
          else
            for (final item in snapshot.plan.items)
              _PlanTile(item: item, onTap: () => onOpen(item)),
        ],
      ),
    );
  }
}

class _PlanHeading extends StatelessWidget {
  const _PlanHeading({
    required this.done,
    required this.total,
    required this.personalized,
  });

  final int done;
  final int total;
  final bool personalized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final title = Row(
      children: [
        ExcludeSemantics(
          child: Icon(Icons.today_outlined, color: c.onPrimaryContainer),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '今日计划',
            style: theme.textTheme.titleLarge?.copyWith(
              color: c.onPrimaryContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
    final status = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _PlanTag(label: total == 0 ? '等待安排' : '$done / $total 已完成'),
        if (personalized) const _PlanTag(label: '按你的测评生成'),
      ],
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        if (useStackedLayout(context, bounds.maxWidth, minInlineWidth: 300)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [title, const SizedBox(height: 10), status],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: title),
            const SizedBox(width: 12),
            status,
          ],
        );
      },
    );
  }
}

class _PlanTag extends StatelessWidget {
  const _PlanTag({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.onPrimaryContainer.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: c.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({required this.item, required this.onTap});
  final PlanItemData item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final (icon, label) = switch (item.kind) {
      PlanKind.exercise => (Icons.psychology_alt_outlined, '读人小练习'),
      PlanKind.card => (Icons.style_outlined, '知识卡'),
      PlanKind.level => (Icons.forum_outlined, '对练关卡'),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: c.surface.withValues(alpha: .76),
        borderRadius: BorderRadius.circular(18),
        child: ListTile(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 4,
          ),
          leading: ExcludeSemantics(
            child: Icon(item.completed ? Icons.check_circle : icon),
          ),
          title: Text(
            item.title,
            style: TextStyle(
              decoration: item.completed ? TextDecoration.lineThrough : null,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(item.completed ? '$label · 已完成' : label),
          trailing: ExcludeSemantics(
            child: Icon(item.completed ? Icons.done : Icons.chevron_right),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _KnowledgeCardTile extends StatelessWidget {
  const _KnowledgeCardTile({required this.card, required this.onTap});
  final KnowledgeCardData card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    return GrowthSurface(
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(18, 12, 14, 12),
        leading: ExcludeSemantics(
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: c.secondaryContainer,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(Icons.lightbulb_outline, color: c.onSecondaryContainer),
          ),
        ),
        title: Text(
          card.title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${_sceneLabel(card.scene)} · ${card.body}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.arrow_forward_rounded),
        onTap: onTap,
      ),
    );
  }
}

class ExerciseSheet extends StatefulWidget {
  const ExerciseSheet({
    required this.repository,
    required this.item,
    super.key,
  });
  final GrowthRepository repository;
  final PlanItemData item;

  @override
  State<ExerciseSheet> createState() => _ExerciseSheetState();
}

class _ExerciseSheetState extends State<ExerciseSheet> {
  late Future<ExerciseData> _exercise;
  int? _choice;
  AnswerData? _answer;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _exercise = widget.repository.exercise(widget.item.contentId);
  }

  Future<void> _submit() async {
    final choice = _choice;
    if (choice == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final answer = await widget.repository.answer(
        widget.item.contentId,
        choice,
      );
      if (mounted) setState(() => _answer = answer);
    } catch (error) {
      if (mounted) setState(() => _error = growthProblem(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complete() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final completion = await widget.repository.complete(widget.item.id);
      if (!mounted) return;
      Navigator.pop(context, completion);
    } catch (error) {
      if (mounted) setState(() => _error = growthProblem(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('读人小练习')),
      body: FutureBuilder<ExerciseData>(
        future: _exercise,
        builder: (context, result) {
          if (result.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (result.hasError || result.data == null) {
            return FailurePane(
              message: growthProblem(result.error ?? StateError('empty')),
              onRetry: () => setState(() {
                _exercise = widget.repository.exercise(widget.item.contentId);
              }),
            );
          }
          final exercise = result.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Text(
                widget.item.title,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 10),
              Semantics(
                header: true,
                child: Text(
                  exercise.question,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 18),
              RadioGroup<int>(
                groupValue: _choice,
                onChanged: (value) {
                  if (_answer != null || _busy || value == null) return;
                  setState(() => _choice = value);
                },
                child: Column(
                  children: [
                    for (final (index, choice) in exercise.choices.indexed)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: RadioListTile<int>(
                          value: index,
                          enabled: _answer == null && !_busy,
                          title: Text(choice),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: BorderSide(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (_error case final text?) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    text,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
              if (_answer == null)
                FilledButton(
                  onPressed: _choice == null || _busy ? null : _submit,
                  child: Text(_busy ? '正在核对…' : '看看我读对了吗'),
                )
              else ...[
                Semantics(
                  liveRegion: true,
                  child: GrowthSurface(
                    color: _answer!.correct
                        ? theme.colorScheme.tertiaryContainer
                        : theme.colorScheme.secondaryContainer,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _answer!.correct ? '读到了' : '再换一个角度',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _answer!.explanation,
                          style: const TextStyle(height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _busy ? null : _complete,
                  icon: const Icon(Icons.check),
                  label: Text(_busy ? '正在打卡…' : '完成今日练习'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class CardSheet extends StatefulWidget {
  const CardSheet({
    required this.repository,
    required this.contentId,
    required this.title,
    super.key,
    this.completionItemId,
  });
  final GrowthRepository repository;
  final String contentId;
  final String title;
  final String? completionItemId;

  @override
  State<CardSheet> createState() => _CardSheetState();
}

class _CardSheetState extends State<CardSheet> {
  late Future<KnowledgeCardData> _card;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _card = widget.repository.card(widget.contentId);
  }

  Future<void> _complete() async {
    final id = widget.completionItemId;
    if (id == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final completion = await widget.repository.complete(id);
      if (mounted) Navigator.pop(context, completion);
    } catch (error) {
      if (mounted) setState(() => _error = growthProblem(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('知识卡')),
      body: FutureBuilder<KnowledgeCardData>(
        future: _card,
        builder: (context, result) {
          if (result.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (result.hasError || result.data == null) {
            return FailurePane(
              message: growthProblem(result.error ?? StateError('empty')),
              onRetry: () => setState(() {
                _card = widget.repository.card(widget.contentId);
              }),
            );
          }
          final card = result.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 32),
            children: [
              Text(
                _sceneLabel(card.scene),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                header: true,
                child: Text(card.title, style: theme.textTheme.headlineMedium),
              ),
              const SizedBox(height: 18),
              SelectableText(
                card.body,
                style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
              ),
              if (_error case final text?) ...[
                const SizedBox(height: 14),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    text,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
              if (widget.completionItemId != null) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _complete,
                  icon: const Icon(Icons.check),
                  label: Text(_busy ? '正在打卡…' : '读完了，记为完成'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

String _sceneLabel(String scene) => switch (scene) {
  'work' => '职场',
  'partner' => '伴侣',
  'family' => '家人',
  'friends' => '朋友',
  'social' => '陌生社交',
  _ => '日常沟通',
};
