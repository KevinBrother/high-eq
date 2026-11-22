import 'package:flutter/material.dart';
import '../contacts/scene.dart';
import 'book.dart';

String stamp(BuildContext context, DateTime at) {
  final local = at.toLocal();
  final fmt = MaterialLocalizations.of(context);
  return '${fmt.formatMediumDate(local)} · ${fmt.formatTimeOfDay(TimeOfDay.fromDateTime(local), alwaysUse24HourFormat: true)}';
}

class MarkEditor extends StatefulWidget {
  const MarkEditor(this.mark, this.book, {super.key});
  final Mark mark;
  final MarkBook book;
  @override
  State<MarkEditor> createState() => _Editor();
}

class _Editor extends State<MarkEditor> {
  late String person = widget.mark.contact ?? '';
  late String scene = widget.mark.scene?.name ?? '';
  late Future<Map<String, String>> names = widget.book.people();
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('补充标记'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FutureBuilder(
            future: names,
            builder: (context, s) {
              final options = {
                '': '不指定对象',
                if (widget.mark.contact != null) widget.mark.contact!: '原标记对象',
                ...?s.data,
              };
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: person,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '对象'),
                    items: [
                      for (final x in options.entries)
                        DropdownMenuItem(
                          value: x.key,
                          child: Text(x.value, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => person = v!),
                  ),
                  if (s.hasError)
                    TextButton(
                      onPressed: () =>
                          setState(() => names = widget.book.people()),
                      child: const Text('对象列表暂不可用 · 重试'),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: scene,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '场景'),
            items: [
              const DropdownMenuItem(value: '', child: Text('不指定场景')),
              for (final x in Scene.values)
                DropdownMenuItem(value: x.name, child: Text(x.label)),
            ],
            onChanged: (v) => setState(() => scene = v!),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, <String, dynamic>{
          if (person != (widget.mark.contact ?? ''))
            'contact_id': person.isEmpty ? null : person,
          if (scene != (widget.mark.scene?.name ?? ''))
            'scene': scene.isEmpty ? null : scene,
        }),
        child: const Text('保存'),
      ),
    ],
  );
}

class MarkReviewDraft extends StatefulWidget {
  const MarkReviewDraft(this.book, this.mark, {super.key});
  final MarkBook book;
  final Mark mark;
  @override
  State<MarkReviewDraft> createState() => _Draft();
}

class _Draft extends State<MarkReviewDraft> {
  bool busy = true, saved = false;
  String? error;
  late final Future<Map<String, String>> people = widget.mark.contact == null
      ? Future.value({})
      : widget.book.people();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      saved = await widget.book.bookmarked(widget.mark);
    } catch (_) {
      error = '暂时无法读取草稿';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.mark;
    return Scaffold(
      appBar: AppBar(title: const Text('文字复盘')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('从这一刻开始', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 16),
            Text(stamp(context, m.at)),
            Text('场景：${m.scene?.label ?? '未指定'}'),
            FutureBuilder(
              future: people,
              builder: (c, s) => Text(
                '对象：${m.contact == null ? '未指定' : (s.data?[m.contact] ?? '已关联对象')}',
              ),
            ),
            const Divider(height: 40),
            const Text('可以先把这条标记留作复盘起点。只保存在本机，不提交 AI，也不消耗次数。'),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: busy || saved
                  ? null
                  : () async {
                      setState(() => busy = true);
                      try {
                        await widget.book.bookmark(m);
                        saved = true;
                        error = null;
                      } catch (_) {
                        error = '保存失败，请重试';
                      }
                      if (mounted) setState(() => busy = false);
                    },
              child: Text(saved ? '已保存复盘起点' : '保存草稿起点'),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
    );
  }
}
