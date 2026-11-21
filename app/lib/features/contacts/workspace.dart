import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/theme.dart';
import 'forms.dart';
import 'models.dart';
import 'profile.dart';
import 'repository.dart';
import 'scene.dart';

enum _View { list, detail, add, edit, chat, remove, choose }

class ContactsWorkspace extends StatefulWidget {
  const ContactsWorkspace({
    required this.repo,
    required this.selection,
    this.demo = false,
    super.key,
  });
  final ContactsRepository repo;
  final SceneMemory selection;
  final bool demo;
  @override
  State<ContactsWorkspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<ContactsWorkspace>
    with WidgetsBindingObserver {
  Book? book;
  String? id, message;
  bool busy = false;
  var view = _View.list;
  List<Question> questions = [];
  Timer? expiry;
  bool needsRefresh = false;
  Contact? get current => book?.people.where((p) => p.id == id).firstOrNull;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _run(_load);
  }

  @override
  void dispose() {
    expiry?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  void _refresh() {
    if (!mounted) return;
    if (busy) {
      needsRefresh = true;
      return;
    }
    _run(_load);
  }

  Future<void> _load() async {
    book = null;
    final next = await widget.repo.load();
    if (!mounted) return;
    book = next;
    expiry?.cancel();
    final until = next.expires;
    if (next.member && until != null) {
      expiry = Timer(until.difference(DateTime.now()), _refresh);
    }
    final c = current;
    if (c == null && view != _View.add) {
      id = null;
      view = _View.list;
    }
    if (view == _View.add && !next.canAdd) view = _View.list;
    if (c != null &&
        (view == _View.edit || view == _View.chat) &&
        !next.usable(c)) {
      view = _View.detail;
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      if (e is ApiFailure && (e.status == 403 || e.status == 404)) {
        view = _View.list;
        id = null;
        try {
          await _load();
        } catch (_) {
          book = null;
        }
        message = '权限或关系人已变更，请核对最新列表。';
      } else if (e is ApiFailure && e.code == 'moderation_unavailable') {
        view = _View.detail;
        message = '服务暂不可用，可重试。本次未展示新的画像。';
      } else if (book == null) {
        message = '暂时无法读取关系人和名额，请检查网络后重试。';
      } else if (view == _View.list) {
        message = '暂时无法取得向导问题，请稍后再试。';
      } else {
        // A lost acknowledgement is not permission to repeat a mutation.
        view = _View.list;
        id = null;
        try {
          await _load();
        } catch (_) {
          book = null;
        }
        message = '暂时无法确认结果。请刷新列表核对，再决定是否重试。';
      }
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (needsRefresh) {
          needsRefresh = false;
          _refresh();
        }
      }
    }
  }

  void _show(_View v) {
    setState(() {
      message = null;
      view = v;
    });
  }

  void _back() {
    if (busy) return;
    _show(
      view == _View.detail || view == _View.add ? _View.list : _View.detail,
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = book;
    final c = current;
    final title = switch (view) {
      _View.list => '关系人',
      _View.add => '添加关系人',
      _View.edit => '编辑资料',
      _View.chat => '导入聊天片段',
      _View.remove => '删除关系人',
      _View.choose => '改选名额',
      _View.detail => '关系人手记',
    };
    return PopScope(
      canPop: view == _View.list && !busy,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: view == _View.list
              ? null
              : BackButton(onPressed: busy ? null : _back),
          actions: [
            if (!busy && (view == _View.list || view == _View.detail))
              IconButton(
                onPressed: _refresh,
                tooltip: '刷新列表',
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 580),
              child: b == null
                  ? StatusPanel(
                      busy ? '正在翻开关系手记…' : message ?? '无法读取关系人',
                      retry: busy ? null : _refresh,
                    )
                  : ListView(
                      key: PageStorageKey(view),
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
                      children: [
                        if (widget.demo)
                          Text(
                            '模拟手记 · 不会发送数据',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                        if (busy) const LinearProgressIndicator(),
                        if (message != null)
                          Semantics(
                            liveRegion: true,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text(message!),
                            ),
                          ),
                        IgnorePointer(
                          ignoring: busy,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: _content(context, b, c),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, Book b, Contact? c) => [
    if (view == _View.list) ...[
      Text('常联系的人', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      Text(
        !b.consistent
            ? '可用名额尚未确认。请刷新后再操作。'
            : b.member
            ? '可用关系人可用于练习和反馈。'
            : '免费可用 1 位。到期后默认保留最近使用的人，也可以改选；续费后恢复。',
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: b.canAdd
            ? () => _run(() async {
                questions = await widget.repo.questions();
                if (mounted) view = _View.add;
              })
            : null,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('添加关系人'),
      ),
      if (b.people.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('还没有关系人。从一个常交流的人开始吧。'),
        ),
      for (final p in b.people)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(p.name),
          subtitle: Text('${p.scene.label} · ${b.usable(p) ? '可用' : '只读'}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            id = p.id;
            _show(_View.detail);
          },
        ),
    ] else if (view == _View.add || view == _View.edit)
      ContactForm(
        initialScene: widget.selection.value,
        contact: view == _View.edit ? c : null,
        questions: view == _View.add ? questions : const [],
        onSave: (input) {
          if (view == _View.add ? !b.canAdd : c == null || !b.usable(c)) {
            _refresh();
            return;
          }
          _run(() async {
            await widget.repo.save(input, id: view == _View.add ? null : c!.id);
            if (!mounted) return;
            view = _View.list;
            await _load();
            message = '关系人已保存。';
          });
        },
      )
    else if (c != null) ...[
      if (view == _View.detail) ...[
        ProfileView(c),
        if (b.usable(c)) ...[
          OutlinedButton(
            onPressed: () => _show(_View.edit),
            child: const Text('编辑资料'),
          ),
          OutlinedButton(
            onPressed: () => _show(_View.chat),
            child: const Text('导入聊天片段'),
          ),
        ] else ...[
          const Text('只读 · 不能用于新练习、修改资料或接收反馈。'),
          if (b.canChoose(c))
            OutlinedButton(
              onPressed: () => _show(_View.choose),
              child: const Text('改选为可用关系人'),
            ),
        ],
        TextButton(
          onPressed: () => _show(_View.remove),
          child: const Text('删除关系人'),
        ),
      ],
      if (view == _View.choose) ...[
        Text('把唯一的可用名额改给「${c.name}」？原可用关系人会变为只读，已有记录不会删除。'),
        FilledButton(
          onPressed: !b.canChoose(c)
              ? null
              : () => _run(() async {
                  await widget.repo.choose(c.id);
                  if (!mounted) return;
                  view = _View.detail;
                  await _load();
                }),
          child: const Text('确认改选'),
        ),
        TextButton(onPressed: _back, child: const Text('取消')),
      ],
      if (view == _View.remove) ...[
        Text('删除「${c.name}」及其画像、关联互动记录和评分副本？此操作不可撤销。'),
        FilledButton(
          onPressed: () => _run(() async {
            await widget.repo.remove(c.id);
            if (!mounted) return;
            id = null;
            view = _View.list;
            await _load();
            message = '关系人已删除。';
          }),
          child: const Text('确认删除'),
        ),
        TextButton(onPressed: _back, child: const Text('取消')),
      ],
      if (view == _View.chat)
        ChatForm(
          onSubmit: (text) {
            if (!b.usable(c)) {
              _refresh();
              return;
            }
            _run(() async {
              final result = await widget.repo.infer(
                c.id,
                newRequestId(),
                text,
              );
              if (!mounted) return;
              view = _View.detail;
              if (result['safety'] == true) {
                message = result['message'] as String;
                return;
              }
              await _load();
              message = '画像已更新，仅供参考。';
            });
          },
        ),
    ],
  ];
}
