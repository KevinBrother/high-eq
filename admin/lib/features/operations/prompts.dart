import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/tasks.dart';
import 'controls.dart';
import 'template_delta.dart';

class PromptPage extends ConsumerStatefulWidget {
  const PromptPage({super.key, required this.session});
  final Session session;
  @override
  ConsumerState<PromptPage> createState() => _Prompts();
}

class _Prompts extends ConsumerState<PromptPage> {
  String task = 'role_play';
  String? model, selected, compare, arm, error;
  int percent = 0;
  bool busy = true, ready = false;
  List<RowData> models = [], versions = [], releases = [];
  final editor = TextEditingController();
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    editor.dispose();
    super.dispose();
  }

  String get token => widget.session.token;
  RowData? get live => releases
      .where((r) => r['model_id'] == model && r['task'] == task)
      .firstOrNull;
  RowData? version(String? id) =>
      versions.where((r) => r['id'] == id).firstOrNull;
  String name(String? id) =>
      version(id) == null ? '未发布' : 'v${version(id)!['version']}';
  void resetRelease() {
    arm = live?['experiment_version_id'];
    percent = live?['experiment_percent'] ?? 0;
    if (arm == selected) {
      arm = null;
      percent = 0;
    }
  }

  Future<void> load({String? saved}) async {
    setState(() {
      busy = true;
      ready = false;
      error = null;
    });
    try {
      final api = ref.read(apiProvider);
      final result = await Future.wait([
        api.configurations(token, 'prompt-models'),
        api.configurations(token, 'prompt-versions', {'task': task}),
        api.configurations(token, 'prompt-releases'),
      ]);
      if (!mounted) return;
      setState(() {
        models = result[0];
        versions = result[1];
        releases = result[2];
        if (!models.any((m) => m['id'] == model)) {
          model = models.firstOrNull?['id'];
        }
        if (saved != null || version(selected) == null) {
          selected = saved ?? versions.firstOrNull?['id'];
          editor.text = version(selected)?['template'] ?? '';
        }
        compare = version(compare) != null
            ? compare
            : live?['primary_version_id'];
        compare ??= versions
            .where((r) => r['id'] != selected)
            .firstOrNull?['id'];
        resetRelease();
        ready = true;
      });
    } catch (e) {
      if (mounted) {
        final msg = failure(e, ref);
        if (mounted) setState(() => error = msg);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> write(bool draft, {String? rollback}) async {
    if (busy || !ready) return;
    final template = draft
        ? editor.text
        : version(rollback ?? selected)?['template'] as String?;
    final invalid = validateTaskTemplate(task, template ?? '');
    if (invalid != null) {
      setState(() => error = invalid);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final api = ref.read(apiProvider);
      String? saved;
      if (draft) {
        final result = await api.configure(token, 'POST', 'prompt-versions', {
          'task': task,
          'template': editor.text,
        });
        saved = result['id'] as String;
      } else {
        await api.configure(token, 'PUT', 'prompt-releases', {
          'task': task,
          'model_id': model,
          'primary_version_id': rollback ?? selected,
          'experiment_version_id': rollback == null ? arm : null,
          'experiment_percent': rollback == null && arm != null ? percent : 0,
        });
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            draft
                ? '已保存新版本，线上配置未变'
                : rollback != null
                ? '已回滚，并关闭实验分流'
                : '发布配置已更新',
          ),
        ),
      );
      await load(saved: saved);
    } catch (e) {
      if (mounted) {
        final msg = failure(e, ref);
        if (mounted) {
          setState(() {
            error = msg;
            busy = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final opts = {
      for (final v in versions) v['id'] as String: 'v${v['version']}',
    };
    final target = live?['primary_version_id'];
    final unsaved = editor.text != (version(selected)?['template'] ?? '');
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('提示词模板', style: Theme.of(context).textTheme.headlineMedium),
        const Text('保存只创建版本；发布按任务和生成模型生效。'),
        const SizedBox(height: 18),
        Choice(
          '任务',
          task,
          tasks,
          busy
              ? null
              : (v) {
                  setState(() {
                    task = v;
                    selected = null;
                    compare = null;
                    editor.clear();
                    error = null;
                  });
                  load();
                },
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
            label: const Text('刷新存量'),
          ),
        ),
        if (ready) ...[
          Section('版本编辑', [
            Choice(
              '基于版本',
              selected,
              opts,
              busy
                  ? null
                  : (v) => setState(() {
                      selected = v;
                      editor.text = version(v)!['template'];
                      if (arm == v) {
                        arm = null;
                        percent = 0;
                      }
                    }),
            ),
            TextField(
              controller: editor,
              onChanged: (_) => setState(() => error = null),
              enabled: !busy,
              minLines: 3,
              maxLines: 10,
              decoration: InputDecoration(
                labelText: '模板正文',
                helperText: '${taskVariableHint(task)}；不要粘贴真实对话。',
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        final invalid = validateTaskTemplate(task, editor.text);
                        if (invalid != null) {
                          setState(() => error = invalid);
                          return;
                        }
                        write(true);
                      },
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存为新版本'),
              ),
            ),
          ]),
          if (versions.length > 1)
            Section('版本比较', [
              Choice(
                '对照版本',
                compare,
                opts,
                busy ? null : (v) => setState(() => compare = v),
              ),
              if (compare != null && selected != null)
                TemplateDelta(
                  version(compare)!['template'],
                  version(selected)!['template'],
                  name(compare),
                  name(selected),
                ),
            ]),
          Section('发布与分流', [
            Choice(
              '目标模型',
              model,
              {
                for (final m in models)
                  m['id'] as String:
                      '${m['name']} · ${m['id']}${m['enabled'] == true ? '' : '（停用）'}',
              },
              busy
                  ? null
                  : (v) => setState(() {
                      model = v;
                      resetRelease();
                    }),
            ),
            if (models.isEmpty) const Text('没有生成模型，请联系超级管理员创建。'),
            Text(
              '线上主版本：${name(target)}   /   实验：${live?['experiment_version_id'] == null ? '关闭' : '${name(live?['experiment_version_id'])} · ${live?['experiment_percent']}%'}',
            ),
            Text(unsaved ? '正文有未保存的修改，请先保存为新版本。' : '待发布主版本：${name(selected)}'),
            Choice(
              '实验版本',
              arm ?? '',
              {'': '不分流', ...Map.of(opts)..remove(selected)},
              busy
                  ? null
                  : (v) => setState(() {
                      arm = v.isEmpty ? null : v;
                      percent = arm == null
                          ? 0
                          : percent == 0
                          ? 10
                          : percent;
                    }),
            ),
            if (arm != null) ...[
              Text('实验流量 $percent%'),
              Slider(
                value: percent.toDouble(),
                max: 100,
                divisions: 100,
                label: '$percent%',
                onChanged: busy
                    ? null
                    : (v) => setState(() => percent = v.round()),
              ),
            ],
            FilledButton(
              onPressed:
                  busy ||
                      unsaved ||
                      model == null ||
                      selected == null ||
                      arm == selected
                  ? null
                  : () => write(false),
              child: const Text('发布所选版本'),
            ),
          ]),
          if (target != null)
            Section('回滚到历史版本', [
              const Text('点选目标即切换主版本并关闭 A/B，不改写模板。'),
              for (final v in versions.where(
                (v) =>
                    v['id'] != target &&
                    (v['version'] as int) < (version(target)?['version'] ?? 0),
              ))
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => write(false, rollback: v['id']),
                    child: Text('回滚到 v${v['version']}'),
                  ),
                ),
            ]),
        ],
      ],
    );
  }
}
