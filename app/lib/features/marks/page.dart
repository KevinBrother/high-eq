import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/transport.dart';
import '../contacts/models.dart' show newRequestId;
import 'book.dart';
import 'forms.dart';
export 'book.dart' show Mark, MarkBook;
export 'forms.dart' show MarkReviewDraft;

class MarksPage extends StatefulWidget {
  const MarksPage(this.book, {this.quick = false, super.key});
  final MarkBook book;
  final bool quick;
  @override
  State<MarksPage> createState() => _Marks();
}

class _Marks extends State<MarksPage> {
  List<Mark> items = [];
  String? cursor, pending, message;
  bool busy = true, loadError = false, running = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (widget.quick && !widget.book.demo) {
        await record();
      }
      if (mounted) await history();
    });
  }

  Future<void> run(Future<void> Function() action) async {
    if (running) return;
    running = true;
    setState(() => busy = true);
    try {
      await action();
    } on ApiFailure catch (e) {
      if (mounted) setState(() => message = e.message);
    } catch (_) {
      if (mounted) setState(() => message = '暂时无法完成，请重试');
    } finally {
      running = false;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> history({bool more = false}) => run(() async {
    loadError = true;
    final page = await widget.book.history(more ? cursor : null);
    if (!mounted) return;
    setState(() {
      items = more ? [...items, ...page.items] : page.items;
      cursor = page.next;
      loadError = false;
    });
  });
  Future<bool> allowWrite(String action) async {
    if (!await widget.book.consented()) {
      if (!mounted) return false;
      final yes = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('只记下这一刻'),
          content: const Text(
            '用于查看自己的标记和回顾对话。时间、可选对象与场景会加密保存 180 天，你也可以提前删除。不会录音或读取健康数据。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('暂不记录'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(action),
            ),
          ],
        ),
      );
      if (yes != true || !mounted) return false;
      await widget.book.grant();
    }
    return mounted;
  }

  Future<void> record() => run(() async {
    if (!await allowWrite('同意并标记')) return;
    pending ??= newRequestId();
    late final Mark m;
    try {
      m = await widget.book.create(pending!);
    } on ApiFailure catch (e) {
      // A deleted request ID is permanently rejected. Other failures keep the
      // same ID so a lost response can still be reconciled by the server.
      if (e.status == 409) {
        pending = null;
      }
      rethrow;
    }
    pending = null;
    if (!mounted) return;
    setState(() {
      items = [m, ...items.where((x) => x.id != m.id)];
      message = '已记下 · 一分钟内的点击合为一条';
    });
  });
  Future<void> edit(Mark m) => run(() async {
    final patch = await showDialog<Json>(
      context: context,
      builder: (_) => MarkEditor(m, widget.book),
    );
    if (patch == null || patch.isEmpty || !mounted) return;
    if (!await allowWrite('同意并保存')) return;
    final out = await widget.book.edit(m.id, patch);
    if (!mounted) return;
    setState(() {
      items = [for (final x in items) x.id == m.id ? out : x];
      message = '补充已保存';
    });
  });
  Future<void> remove(Mark m) => run(() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除这条标记？'),
        content: const Text('删除后将不再出现在历史中。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('保留'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    await widget.book.remove(m.id);
    if (!mounted) return;
    setState(() {
      items.removeWhere((x) => x.id == m.id);
      message = '标记已删除';
    });
  });
  @override
  Widget build(BuildContext context) {
    final demo = widget.book.demo;
    return Scaffold(
      appBar: AppBar(title: const Text('手动标记')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          children: [
            Text(
              '先记下，不急着解释。',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy || demo ? null : record,
              icon: const Icon(Icons.bookmark_add_outlined),
              label: Text(pending == null ? '我上头了' : '重试本次标记'),
            ),
            if (demo) const Text('契约预览 · 请连接真实服务后记录'),
            if (busy) const Text('正在处理…'),
            if (message != null)
              Semantics(liveRegion: true, child: Text(message!)),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '我的标记',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '刷新历史',
                  onPressed: busy ? null : history,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (loadError && !busy)
              TextButton(onPressed: history, child: const Text('重新加载历史')),
            if (!busy && !loadError && items.isEmpty)
              const Text('还没有标记。下次想暂停一下时，点上方按钮就好。'),
            for (final m in items)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stamp(context, m.at),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '${m.scene?.label ?? '未补场景'} · ${m.contact == null ? '未补对象' : '已关联对象'}',
                      ),
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: busy || demo ? null : () => edit(m),
                            child: const Text('补充信息'),
                          ),
                          TextButton(
                            onPressed: busy || demo
                                ? null
                                : () => Navigator.pushNamed(
                                    context,
                                    '/marks/review',
                                    arguments: m.review,
                                  ),
                            child: const Text('写复盘'),
                          ),
                          IconButton(
                            tooltip: '删除标记',
                            onPressed: busy || demo ? null : () => remove(m),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (cursor != null)
              TextButton(
                onPressed: busy ? null : () => history(more: true),
                child: const Text('加载更早标记'),
              ),
          ],
        ),
      ),
    );
  }
}
