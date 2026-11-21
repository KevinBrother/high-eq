import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api.dart';
import 'repository.dart';
import 'result.dart';

class ReplyCards extends StatefulWidget {
  const ReplyCards({
    super.key,
    required this.answer,
    required this.repo,
    this.contactId,
  });
  final Approved answer;
  final ReplyRepository repo;
  final String? contactId;
  @override
  State<ReplyCards> createState() => _ReplyCardsState();
}

class _ReplyCardsState extends State<ReplyCards> {
  final outcome = TextEditingController();
  int? choice;
  String? selfReport;
  bool busy = false, saved = false;
  bool? permitted;
  String? error;
  @override
  void initState() {
    super.initState();
    if (widget.contactId == null) {
      permitted = true;
    } else {
      _refreshPermission();
    }
  }

  @override
  void dispose() {
    outcome.dispose();
    super.dispose();
  }

  Future<bool> _refreshPermission() async {
    if (widget.contactId == null) {
      if (mounted) setState(() => permitted = true);
      return true;
    }
    try {
      final people = await widget.repo.contacts();
      final ok = people.any((c) => c.id == widget.contactId);
      if (mounted) setState(() => permitted = ok);
      return ok;
    } catch (_) {
      if (mounted) {
        setState(() {
          permitted = false;
          error = '暂时无法确认关系人权限，反馈入口已关闭。';
        });
      }
      return false;
    }
  }

  Future<void> submit() async {
    if (busy ||
        saved ||
        choice == null ||
        outcome.text.trim().isEmpty ||
        permitted != true) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!await _refreshPermission()) return;
      await widget.repo.feedback(
        widget.answer.id,
        choice!,
        outcome.text.trim(),
        selfReport,
      );
      if (mounted) setState(() => saved = true);
    } on ApiFailure catch (e) {
      if (mounted) {
        setState(() {
          if (e.status == 403) {
            permitted = false;
            error = '关系人权限已变更，反馈未提交。';
          } else if (e.status == 409) {
            saved = true;
            error = '该回复已有反馈记录，不能再次提交。';
          } else {
            error = '反馈未确认，可重试。';
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '反馈未确认，可重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> copy(String text) async {
    var message = '已复制这条建议';
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (_) {
      message = '未能复制，请重试。';
    }
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.answer;
    final type = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('先理解对方', style: type.titleLarge),
        Text('可能的情绪：${a.feeling}'),
        Text('可能的需要：${a.need}'),
        const SizedBox(height: 16),
        for (final (i, s) in a.suggestions.indexed)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${i + 1} · ${s.style}', style: type.titleMedium),
                  const SizedBox(height: 8),
                  Text(s.text),
                  const Divider(),
                  Text('为什么这样说：${s.reason}'),
                  Wrap(
                    children: [
                      TextButton.icon(
                        onPressed: () => copy(s.text),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制建议'),
                      ),
                      TextButton(
                        onPressed: busy || saved || permitted != true
                            ? null
                            : () => setState(() {
                                choice = i;
                                error = null;
                              }),
                        child: Text(choice == i ? '已选择这条' : '我用了这条'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (saved)
          Text(error ?? '已记录本次效果。')
        else if (permitted == null)
          const Text('正在确认关联关系人权限…')
        else if (permitted == false) ...[
          const Text('关联关系人当前为只读，不能提交效果反馈；仍可复制建议。'),
          if (error != null) Text(error!),
          TextButton(
            onPressed: busy ? null : _refreshPermission,
            child: const Text('重新检查权限'),
          ),
        ] else if (choice != null) ...[
          TextField(
            controller: outcome,
            enabled: !busy,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: '第 ${choice! + 1} 条效果如何？'),
          ),
          const SizedBox(height: 10),
          const Text('本人当时的状态（可选，不会从效果文字推断）'),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('不填写'),
                selected: selfReport == null,
                onSelected: busy
                    ? null
                    : (_) => setState(() => selfReport = null),
              ),
              ChoiceChip(
                label: const Text('本人当时上头'),
                selected: selfReport == 'overwhelmed',
                onSelected: busy
                    ? null
                    : (_) => setState(() => selfReport = 'overwhelmed'),
              ),
              ChoiceChip(
                label: const Text('本人当时没有上头'),
                selected: selfReport == 'not_overwhelmed',
                onSelected: busy
                    ? null
                    : (_) => setState(() => selfReport = 'not_overwhelmed'),
              ),
            ],
          ),
          if (error != null) Text(error!),
          FilledButton.tonal(
            onPressed: !busy && outcome.text.trim().isNotEmpty ? submit : null,
            child: const Text('提交效果反馈'),
          ),
        ],
      ],
    );
  }
}
