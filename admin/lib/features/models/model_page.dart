import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import 'model_forms.dart';

class ModelPage extends ConsumerStatefulWidget {
  const ModelPage({super.key, required this.session});
  final Session session;
  @override
  ConsumerState<ModelPage> createState() => _Page();
}

class _Page extends ConsumerState<ModelPage> {
  static const labels = {
    'models': '模型',
    'routes': '任务路由',
    'admissions': '准入凭据',
  };
  String section = 'models';
  Map<String, List<RowData>>? data;
  RowData? edit;
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  void fail(Object e) {
    if (e is ApiFailure && e.status == 401) {
      ref.read(sessionProvider.notifier).clear();
      return;
    }
    setState(() => error = e is ApiFailure ? e.message : '无法读取或更新配置');
  }

  Future<void> load() async {
    setState(() {
      busy = true;
      error = null;
      data = null;
    });
    try {
      final api = ref.read(apiProvider);
      final lists = await Future.wait(
        labels.keys.map((s) => api.configurations(widget.session.token, s)),
      );
      if (mounted) setState(() => data = Map.fromIterables(labels.keys, lists));
    } catch (e) {
      if (mounted) fail(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> write(String method, String path, [RowData? body]) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref
          .read(apiProvider)
          .configure(widget.session.token, method, path, body);
      if (!mounted) return;
      setState(() => edit = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(path.endsWith('/test') ? '固定合成输入连通测试通过' : '配置已生效'),
        ),
      );
      await load();
    } catch (e) {
      if (mounted) fail(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void start(RowData value) => setState(() {
    edit = value;
    error = null;
  });
  Future<void> confirm(
    String title,
    String detail,
    String method,
    String path, [
    RowData? body,
  ]) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (mounted && yes == true) await write(method, path, body);
  }

  String modelName(dynamic id) =>
      data!['models']!.where((m) => m['id'] == id).firstOrNull?['name'] ??
      '未配置';
  Widget card(String title, String info, List<Widget> actions) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SelectableText(info),
          Wrap(spacing: 8, children: actions),
        ],
      ),
    ),
  );
  List<Widget> listing() {
    final rows = data![section]!;
    if (section == 'routes') {
      return [
        for (final t in tasks.entries)
          Builder(
            builder: (_) {
              final r = rows.where((m) => m['task'] == t.key).firstOrNull;
              return card(
                t.value,
                r == null
                    ? '尚未配置，任务不会分发'
                    : '主：${modelName(r['primary_model'])}　备：${modelName(r['fallback_model'])}\n审核：${modelName(r['moderation_model'])}　灰度：${r['canary_percent']}%',
                [
                  TextButton(
                    onPressed: () =>
                        start(r ?? {'task': t.key, 'canary_percent': 0}),
                    child: const Text('配置路由'),
                  ),
                ],
              );
            },
          ),
      ];
    }
    return [
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: section == 'models' && data!['admissions']!.isEmpty
              ? null
              : () => start({}),
          icon: const Icon(Icons.add),
          label: Text(section == 'models' ? '新增模型' : '登记准入凭据'),
        ),
      ),
      if (rows.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            section == 'models'
                ? '暂无模型。先登记独立核验的准入凭据，再添加模型。'
                : '暂无凭据。未经核验的端点不能启用或测试。',
          ),
        ),
      for (final r in rows)
        if (section == 'models')
          card(
            '${r['name']} · ${r['enabled'] ? '已启用' : '已停用'}',
            '${r['provider']} / ${r['model_name']} · ${r['kind'] == 'model' ? '生成' : '审核'}\n${r['endpoint']}\n密钥：${r['key_last_four'] == '' ? '末四位未登记' : '•••• ${r['key_last_four']}'}　输入 / 输出：${r['input_cny_per_million'] ?? '—'} / ${r['output_cny_per_million'] ?? '—'} 元 / 百万 token',
            [
              TextButton(onPressed: () => start(r), child: const Text('编辑')),
              TextButton(
                onPressed: r['enabled'] == true
                    ? () => write('POST', 'models/${r['id']}/test')
                    : null,
                child: const Text('测试连通'),
              ),
              if (r['enabled'] == true)
                TextButton(
                  onPressed: () => confirm(
                    '停用模型？',
                    '如有任务正在使用，请先切换其路由。',
                    'PATCH',
                    'models/${r['id']}',
                    {'enabled': false},
                  ),
                  child: const Text('停用'),
                ),
            ],
          )
        else
          card(
            '${r['provider']} · ${r['model_scope']}',
            '${r['purpose']} · ${r['endpoint']}\n凭据：${r['terms_evidence']}\n境内处理和存储 · 不出境 · 最长留存 ${r['max_retention_days']} 天\n删除：${r['deletion_method']}\n字段：${(r['sent_fields'] as List).join(', ')}',
            [
              TextButton(
                onPressed: () => confirm(
                  '撤销准入凭据？',
                  '相关模型将立即停用，使用它们的任务路由将被移除，须重新配置。',
                  'DELETE',
                  'admissions/${Uri.encodeComponent(r['ref'])}',
                ),
                child: const Text('撤销准入'),
              ),
            ],
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final item = edit;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('模型与路由', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            for (final e in labels.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: e.key == section,
                onSelected: busy || edit != null
                    ? null
                    : (_) => setState(() {
                        section = e.key;
                        error = null;
                      }),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              if (edit == null)
                TextButton(
                  onPressed: busy ? null : load,
                  child: const Text('重新加载'),
                ),
            ],
          ),
        if (data != null)
          AbsorbPointer(
            absorbing: busy,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: item == null
                  ? listing()
                  : [
                      ConfigEditor(
                        key: ObjectKey(item),
                        section: section,
                        item: item,
                        models: data!['models']!,
                        admissions: data!['admissions']!,
                        busy: busy,
                        cancel: () => setState(() => edit = null),
                        save: (body) => write(
                          section == 'routes'
                              ? 'PUT'
                              : item['id'] == null
                              ? 'POST'
                              : 'PATCH',
                          section == 'routes'
                              ? 'routes/${item['task']}'
                              : item['id'] == null
                              ? section
                              : 'models/${item['id']}',
                          body,
                        ),
                      ),
                    ],
            ),
          ),
      ],
    );
  }
}
