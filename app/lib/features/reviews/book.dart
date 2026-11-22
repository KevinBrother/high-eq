import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../contacts/scene.dart';
import 'model.dart';
import 'repository.dart';

class ReviewBookView extends StatefulWidget {
  const ReviewBookView({
    super.key,
    required this.repo,
    required this.active,
    required this.revision,
  });

  final ReviewRepository repo;
  final bool active;
  final int revision;

  @override
  State<ReviewBookView> createState() => _ReviewBookViewState();
}

class _ReviewBookViewState extends State<ReviewBookView> {
  final items = <ReviewRecord>[];
  List<ReviewPerson> people = const [];
  Scene? scene;
  String? contactId;
  String? cursor;
  String? error;
  bool loading = false;
  bool _peopleLoaded = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) _activate();
  }

  @override
  void didUpdateWidget(covariant ReviewBookView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        (!oldWidget.active || widget.revision != oldWidget.revision)) {
      _activate();
    }
  }

  Future<void> _activate() async {
    final loadPeople = !_peopleLoaded;
    _peopleLoaded = true;
    await Future.wait([if (loadPeople) _loadPeople(), _load()]);
  }

  Future<void> _loadPeople() async {
    try {
      final rows = await widget.repo.people();
      if (mounted) setState(() => people = rows);
    } catch (_) {
      // The history remains usable without the optional name filter.
    }
  }

  Future<void> _load({bool more = false}) async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.repo.history(
        cursor: more ? cursor : null,
        scene: scene,
        contactId: contactId,
      );
      if (!mounted || request != generation) return;
      setState(() {
        if (more) {
          items.addAll(page.items);
        } else {
          items
            ..clear()
            ..addAll(page.items);
        }
        cursor = page.next;
      });
    } on ApiFailure catch (failure) {
      if (!mounted || request != generation) return;
      setState(
        () => error = failure.status == 503 ? '服务暂不可用，可重试' : '暂时无法读取踩坑本',
      );
    } catch (_) {
      if (!mounted || request != generation) return;
      setState(() => error = '暂时无法读取踩坑本');
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  Future<void> _sceneChanged(Scene? value) async {
    setState(() {
      scene = value;
      cursor = null;
      items.clear();
    });
    await _load();
  }

  Future<void> _contactChanged(String? value) async {
    setState(() {
      contactId = value;
      cursor = null;
      items.clear();
    });
    await _load();
  }

  String? _contactName(String? id) {
    if (id == null) return null;
    for (final person in people) {
      if (person.id == id) return person.name;
    }
    return null;
  }

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
            Text('踩坑本', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text(
              '不是失败清单，是下次可以少走一点弯路的记录。',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<Scene?>(
                    key: const Key('review.filter.scene'),
                    initialValue: scene,
                    decoration: const InputDecoration(
                      labelText: '场景',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<Scene?>(
                        value: null,
                        child: Text('全部场景'),
                      ),
                      for (final value in Scene.values)
                        DropdownMenuItem<Scene?>(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: loading ? null : _sceneChanged,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    key: const Key('review.filter.contact'),
                    initialValue: contactId,
                    decoration: const InputDecoration(
                      labelText: '关系人',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('全部关系人'),
                      ),
                      for (final person in people)
                        DropdownMenuItem<String?>(
                          value: person.id,
                          child: Text(person.name),
                        ),
                    ],
                    onChanged: loading ? null : _contactChanged,
                  ),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 14),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.errorContainer,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(child: Text(error!)),
                      TextButton(
                        onPressed: loading ? null : () => _load(),
                        child: const Text('重新加载'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (loading && items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 42),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (!loading && items.isEmpty && error == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 44),
                child: Text(
                  scene == null && contactId == null
                      ? '还没有复盘记录。完成一次 AI 复盘后，会出现在这里。'
                      : '没有符合筛选的复盘。可以换个条件，或先写一次新的复盘。',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              )
            else
              for (final record in items) ...[
                const SizedBox(height: 14),
                _HistoryEntry(
                  key: ValueKey('review.history.${record.id}'),
                  record: record,
                  contactName: _contactName(record.submitted.contactId),
                ),
              ],
            if (cursor != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(
                onPressed: loading ? null : () => _load(more: true),
                child: const Text('加载更早复盘'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HistoryEntry extends StatelessWidget {
  const _HistoryEntry({
    super.key,
    required this.record,
    required this.contactName,
  });
  final ReviewRecord record;
  final String? contactName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final submitted = record.submitted;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.primary, width: 4)),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(18)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _stamp(submitted.occurredAt),
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Text(
                  '${record.score.total} 分',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              submitted.happened,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
            ),
            const SizedBox(height: 8),
            Text(
              [
                submitted.scene?.label ?? '未补场景',
                contactName ??
                    (submitted.contactId == null ? '未关联对象' : '已关联对象'),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              record.repairPhrase,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.primary,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _stamp(DateTime? value) {
  if (value == null) return '时间未记录';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
