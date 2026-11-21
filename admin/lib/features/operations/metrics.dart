import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/tasks.dart';
import 'controls.dart';

class MetricsPage extends ConsumerStatefulWidget {
  const MetricsPage({super.key, required this.session});
  final Session session;
  @override
  ConsumerState<MetricsPage> createState() => _Metrics();
}

class _Metrics extends ConsumerState<MetricsPage> {
  String days = '1', task = '', model = '', version = '';
  bool loading = false;
  String? error, next;
  Map<String, String> query = {};
  List<RowData> rows = [];
  final form = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool append = false}) async {
    if (loading) return;
    if (!append && form.currentState?.validate() == false) return;
    if (!append) {
      final end = DateTime.now().toUtc();
      query = {
        'from': end.subtract(Duration(days: int.parse(days))).toIso8601String(),
        'until': end.toIso8601String(),
        if (task.isNotEmpty) 'task': task,
        if (model.isNotEmpty) 'model_id': model,
        if (version.isNotEmpty) 'prompt_version_id': version,
        'limit': '20',
      };
      rows = [];
      next = null;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await ref.read(apiProvider).metrics(widget.session.token, {
        ...query,
        if (append) 'cursor': next!,
      });
      if (!mounted) return;
      setState(() {
        rows = [...rows, ...(page['items'] as List).cast<RowData>()];
        next = page['next_cursor'];
      });
    } catch (e) {
      if (mounted) {
        final msg = failure(e, ref);
        if (mounted) setState(() => error = msg);
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Widget uuidField(String label, ValueChanged<String> change) => TextFormField(
    enabled: !loading,
    decoration: InputDecoration(labelText: label, hintText: '留空表示全部'),
    onChanged: (v) => change(v.trim()),
    validator: (v) =>
        v == null ||
            v.trim().isEmpty ||
            RegExp(
              r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
            ).hasMatch(v.trim())
        ? null
        : '请输入完整 UUID',
  );
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Text('调用监控', style: Theme.of(context).textTheme.headlineMedium),
      const Text('按实际尝试计数，含审核、失败与备用调用。金额只累计已知成本。'),
      const SizedBox(height: 16),
      Form(
        key: form,
        child: Section('查询范围', [
          Choice('时间范围', days, {
            '1': '近 24 小时',
            '7': '近 7 天',
            '30': '近 30 天',
          }, loading ? null : (v) => setState(() => days = v)),
          Choice('任务', task, {
            '': '全部任务',
            ...tasks,
          }, loading ? null : (v) => setState(() => task = v)),
          ExpansionTile(
            title: const Text('精确筛选'),
            children: [
              uuidField('模型 UUID', (v) => model = v),
              const SizedBox(height: 8),
              uuidField('模板版本 UUID', (v) => version = v),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: loading ? null : load,
              icon: const Icon(Icons.search),
              label: const Text('查询调用'),
            ),
          ),
        ]),
      ),
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      if (!loading && error == null && rows.isEmpty)
        const Section('没有调用记录', [Text('此时间段或筛选条件下没有匹配尝试。')]),
      for (final row in rows) _Group(row),
      if (next != null)
        OutlinedButton(
          onPressed: loading ? null : () => load(append: true),
          child: const Text('加载更多分组'),
        ),
    ],
  );
}

class _Group extends StatelessWidget {
  const _Group(this.r);
  final RowData r;
  @override
  Widget build(BuildContext context) {
    final bins = (r['score_distribution'] as List).cast<RowData>();
    final peak = bins.fold<int>(0, (a, b) => math.max(a, b['count'] as int));
    final cost = r['cost_cny'] as num;
    return Section(tasks[r['task']] ?? r['task'], [
      SelectableText(
        '模型 ${r['model_id']}\n模板 ${r['prompt_version_id'] ?? '无版本关联'}',
      ),
      Wrap(
        spacing: 22,
        runSpacing: 10,
        children: [
          Text('调用 ${r['calls']} 次'),
          Text('平均 ${(r['mean_latency_ms'] as num).toStringAsFixed(1)} ms'),
          Text(
            '失败 ${r['failures']} 次 · ${((r['failure_rate'] as num) * 100).toStringAsFixed(1)}%',
          ),
        ],
      ),
      Text(
        '已知成本 ¥${cost.toStringAsFixed(8)}  ·  未知成本 ${r['unpriced_calls']} 次',
      ),
      if (r['task'] == 'scoring') ...[
        const Divider(),
        const Text('NVC 总分分布 · 按关联评分去重'),
        if (bins.isEmpty) const Text('没有可用的数值样本'),
        for (final b in bins)
          Row(
            children: [
              SizedBox(width: 55, child: Text('${b['nvc_total']} 分')),
              Expanded(
                child: LinearProgressIndicator(
                  value: (b['count'] as int) / peak,
                ),
              ),
              const SizedBox(width: 12),
              Text('${b['count']} 份'),
            ],
          ),
        if (r['missing_score_values'] != 0)
          Text('尚无数值投影：${r['missing_score_values']} 份（不计入分布）'),
      ],
    ]);
  }
}
