import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/session.dart';

class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key, required this.session});
  final Session session;
  @override
  ConsumerState<AuditPage> createState() => _Audit();
}

class _Audit extends ConsumerState<AuditPage> {
  final actor = TextEditingController();
  final form = GlobalKey<FormState>();
  DateTimeRange? dates;
  Map<String, String> filters = {};
  final entries = <Map<String, dynamic>>[];
  String? cursor, error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    actor.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      if (!more) {
        entries.clear();
        cursor = null;
      }
    });
    try {
      final page = await ref.read(apiProvider).audit(widget.session.token, {
        ...filters,
        'limit': '20',
        if (more && cursor != null) 'cursor': cursor!,
      });
      if (!mounted) return;
      final list = (page['items'] as List)
          .cast<Map<String, dynamic>>()
          .toList();
      setState(() {
        entries.addAll(list);
        cursor = page['next_cursor'] as String?;
      });
    } catch (e) {
      if (!mounted) return;
      if (e is ApiFailure && e.status == 401) {
        ref.read(sessionProvider.notifier).clear();
        return;
      }
      setState(() => error = e is ApiFailure ? e.message : '无法读取审计记录');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pick() async {
    final now = DateTime.now();
    final d = await showDateRangePicker(
      context: context,
      initialDateRange: dates,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
    );
    if (mounted && d != null) setState(() => dates = d);
  }

  void apply() {
    if (!form.currentState!.validate()) return;
    final range = dates;
    filters = {
      if (actor.text.trim().isNotEmpty) 'actor_id': actor.text.trim(),
      if (range != null) ...{
        'from': range.start.toUtc().toIso8601String(),
        'until': DateTime(
          range.end.year,
          range.end.month,
          range.end.day + 1,
        ).toUtc().toIso8601String(),
      },
    };
    load();
  }

  String date(DateTime d) => d.toLocal().toString().substring(0, 10);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('操作审计', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text('按操作人和本地日期查询，最新记录在前。'),
        const SizedBox(height: 20),
        Form(
          key: form,
          child: TextFormField(
            controller: actor,
            decoration: const InputDecoration(
              labelText: '操作人 ID',
              hintText: '所有操作人，或输入完整 UUID',
            ),
            validator: (s) =>
                s == null ||
                    s.trim().isEmpty ||
                    RegExp(
                      r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
                    ).hasMatch(s.trim())
                ? null
                : '请输入完整 UUID',
            onFieldSubmitted: (_) {
              if (!busy) apply();
            },
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: busy ? null : pick,
              icon: const Icon(Icons.date_range_outlined),
              label: Text(
                dates == null
                    ? '选择日期范围'
                    : '${date(dates!.start)} 至 ${date(dates!.end)}',
              ),
            ),
            FilledButton(
              onPressed: busy ? null : apply,
              child: const Text('查询'),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () {
                      actor.clear();
                      setState(() => dates = null);
                      apply();
                    },
              child: const Text('重置'),
            ),
          ],
        ),
        const Divider(height: 32),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          ListTile(
            title: Text(error!),
            trailing: TextButton(
              onPressed: () => load(more: entries.isNotEmpty),
              child: const Text('重试'),
            ),
          ),
        if (!busy && error == null && entries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('没有符合条件的记录')),
          ),
        for (final e in entries) _Entry(e),
        if (cursor != null && error == null)
          TextButton(
            onPressed: busy ? null : () => load(more: true),
            child: const Text('加载更多'),
          ),
      ],
    );
  }
}

class _Entry extends StatelessWidget {
  const _Entry(this.e);
  final Map<String, dynamic> e;
  @override
  Widget build(BuildContext context) {
    final result = switch (e['result']) {
      'ok' => '成功',
      'denied' => '拒绝',
      _ => '失败',
    };
    final time = DateTime.parse(
      e['occurred_at'] as String,
    ).toLocal().toString().split('.').first;
    final actor = e['actor_id'] == '00000000-0000-0000-0000-000000000000'
        ? '系统或未认证'
        : e['actor_id'];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$result  ·  ${e['action']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(time),
            SelectableText('操作人：$actor\n对象：${e['target']}'),
          ],
        ),
      ),
    );
  }
}
