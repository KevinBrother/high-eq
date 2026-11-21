import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/transport.dart';
import '../contacts/models.dart';
import 'repository.dart';
import 'result.dart';
import 'result_cards.dart';

bool _terminalAnalysisFailure(ApiFailure failure) =>
    failure.status == 500 &&
    failure.code == 'internal_error' &&
    failure.retryable == false;

class ReplyPage extends StatefulWidget {
  const ReplyPage(
    this.repo, {
    super.key,
    this.sharedText,
    this.close,
    this.demo = false,
  });
  final ReplyRepository repo;
  final String? sharedText;
  final VoidCallback? close;
  final bool demo;
  @override
  State<ReplyPage> createState() => _ReplyPageState();
}

class _ReplyPageState extends State<ReplyPage> {
  late final chat = TextEditingController(text: widget.sharedText);
  final goal = TextEditingController();
  bool? allowed;
  bool busy = false;
  bool checkingConsent = false;
  bool mustEdit = false;
  String? error, contact;
  List<Contact>? people;
  bool contactError = false;
  Json? operation;
  ReplyResult? result;
  @override
  void initState() {
    super.initState();
    notice();
    loadPeople();
  }

  @override
  void dispose() {
    chat.dispose();
    goal.dispose();
    super.dispose();
  }

  Future<void> loadPeople() async {
    try {
      final items = await widget.repo.contacts();
      if (mounted) {
        setState(() {
          people = items;
          if (contact != null && !items.any((c) => c.id == contact)) {
            contact = null;
            operation = null;
          }
          contactError = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => contactError = true);
    }
  }

  Future<void> notice({bool grant = false}) async {
    setState(() {
      busy = true;
      checkingConsent = true;
      error = null;
    });
    try {
      if (grant) await widget.repo.grant();
      final ok = grant || await widget.repo.allowed();
      if (mounted) setState(() => allowed = ok);
    } catch (_) {
      if (mounted) setState(() => error = '未能确认导入授权，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          checkingConsent = false;
        });
      }
    }
  }

  void edited() {
    final current = _draft();
    final unchanged =
        operation != null &&
        operation!['chat_text'] == current['chat_text'] &&
        operation!['goal'] == current['goal'] &&
        operation!['contact_id'] == current['contact_id'];
    setState(() {
      if (!unchanged) {
        operation = null;
        result = null;
        error = null;
        mustEdit = false;
      }
    });
  }

  Json _draft() => {
    'chat_text': chat.text.trim(),
    if (goal.text.trim().isNotEmpty) 'goal': goal.text.trim(),
    'contact_id': ?contact,
  };

  String _quotaMessage(ReplyQuota quota) {
    final reset = quota.resetsAt.toLocal();
    final now = DateTime.now();
    final day = DateUtils.isSameDay(reset, now)
        ? '今天'
        : DateUtils.isSameDay(reset, now.add(const Duration(days: 1)))
        ? '明天'
        : '${reset.month}月${reset.day}日';
    final time =
        '${reset.hour.toString().padLeft(2, '0')}:${reset.minute.toString().padLeft(2, '0')}';
    final remaining = quota.remaining;
    return remaining == null
        ? '本次请求受额度限制，权益将在$day $time 重置。'
        : '今日回复次数已用完（剩余 $remaining 次），将在$day $time 重置。';
  }

  Future<void> analyze() async {
    if (busy || allowed != true || mustEdit || chat.text.trim().isEmpty) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      checkingConsent = true;
      error = null;
      result = null;
    });
    try {
      final ok = await widget.repo.allowed();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          allowed = false;
          checkingConsent = false;
          error = '导入授权已撤回，请重新阅读说明并同意后再分析。';
        });
        return;
      }
      if (contact != null) {
        final selected = contact!;
        try {
          final items = await widget.repo.contacts();
          if (!mounted) return;
          if (!items.any((c) => c.id == selected)) {
            setState(() {
              people = items;
              contact = null;
              operation = null;
              mustEdit = true;
              error = '关系人权限已变更，请修改输入或取消关联后再分析。';
            });
            return;
          }
          setState(() => people = items);
        } catch (_) {
          if (!mounted) return;
          setState(() {
            if (operation == null) mustEdit = true;
            error = operation == null
                ? '暂时无法确认关系人权限，请修改输入后再分析。'
                : '暂时无法确认关系人权限，原请求已保留，请稍后重试。';
          });
          return;
        }
      }
      final input = operation ?? {'request_id': newRequestId(), ..._draft()};
      if (!replyInputFits(input)) {
        setState(() {
          allowed = true;
          checkingConsent = false;
          mustEdit = true;
          error = '内容过长，请删减对话或补充目的后重新分析。';
        });
        return;
      }
      operation ??= Map.unmodifiable(input);
      setState(() {
        allowed = true;
        checkingConsent = false;
      });
      final r = await widget.repo.analyze(operation!);
      if (mounted) setState(() => result = r);
    } on ReplyInputTooLarge {
      if (mounted) {
        setState(() {
          mustEdit = true;
          error = '内容过长，请删减对话或补充目的后重新分析。';
        });
      }
    } on ApiFailure catch (e) {
      if (!mounted) return;
      if (_terminalAnalysisFailure(e)) {
        setState(() => result = NoResult(terminal: true));
        return;
      }
      setState(() {
        error = switch (e.status) {
          503 when e.code == 'moderation_unavailable' => '服务暂不可用，可重试',
          403 => '授权或关系人权限已变更，请检查后重试。',
          429 => '今日回复次数已用完，请按会员页显示的重置时间后再试。',
          409 => '本次请求与原操作不一致，请修改输入后再分析。',
          400 => '请求内容不符合要求，请缩短或修改输入后再分析。',
          _ => '连接未完成，可用原请求重试。',
        };
        if (e.status == 400 || e.status == 409) mustEdit = true;
      });
      if (e.status == 429) {
        try {
          final quota = await widget.repo.quota();
          if (mounted && quota != null) {
            setState(() => error = _quotaMessage(quota));
          }
        } catch (_) {
          /* Keep the contract-backed fallback; never invent a reset time. */
        }
      }
      if (e.status == 403) {
        try {
          final ok = await widget.repo.allowed();
          if (mounted) setState(() => allowed = ok);
        } catch (_) {
          if (mounted) setState(() => allowed = null);
        }
        if (mounted) await loadPeople();
      }
    } on FormatException {
      if (mounted) setState(() => result = NoResult());
    } catch (_) {
      if (mounted) {
        setState(
          () => error = checkingConsent ? '未能确认导入授权，请重试。' : '连接未完成，可用原请求重试。',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          checkingConsent = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final type = Theme.of(context).textTheme;
    final r = result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('回复助手'),
        leading: widget.close == null
            ? null
            : CloseButton(onPressed: widget.close),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
          children: [
            Text('先听懂，再回应', style: type.headlineSmall),
            const SizedBox(height: 6),
            Text(widget.demo ? '契约模拟 · 不会发送数据' : '看看对方可能在意什么，再选适合自己的说法。'),
            if (widget.sharedText != null)
              const Text('文字来自系统分享。你可以删改草稿，再决定是否分析。'),
            const SizedBox(height: 20),
            TextField(
              controller: chat,
              enabled: !busy,
              enableIMEPersonalizedLearning: false,
              autocorrect: false,
              minLines: 3,
              maxLines: 7,
              onChanged: (_) => edited(),
              decoration: const InputDecoration(
                labelText: '对方说了什么',
                hintText: '粘贴对话，先删去姓名、联系方式等隐私信息',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: goal,
              enabled: !busy,
              onChanged: (_) => edited(),
              decoration: const InputDecoration(
                labelText: '希望达成什么（选填）',
                hintText: '例如：确认时间，又不显得催促',
              ),
            ),
            DropdownButtonFormField<String>(
              key: ValueKey(contact),
              initialValue: contact ?? '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '关系人（选填）'),
              items: [
                const DropdownMenuItem(value: '', child: Text('不关联关系人')),
                for (final c in people ?? <Contact>[])
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: busy
                  ? null
                  : (v) {
                      contact = v == '' ? null : v;
                      edited();
                    },
            ),
            if (contactError)
              TextButton(
                onPressed: loadPeople,
                child: const Text('关系人未载入 · 重试（也可不选）'),
              ),
            const SizedBox(height: 18),
            if (allowed == false)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('首次导入说明', style: type.titleMedium),
                      const Text(
                        '对话可能含他人信息。仅在你点「开始分析」后，才将所填内容发送至服务器生成建议；聊天原文在 24 小时内删除。请仅提交有权使用的文字。',
                      ),
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: busy
                                ? null
                                : (widget.close ??
                                      () => Navigator.maybePop(context)),
                            child: const Text('暂不导入'),
                          ),
                          FilledButton.tonal(
                            onPressed: busy ? null : () => notice(grant: true),
                            child: const Text('同意导入说明'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            if (allowed == null && !busy)
              TextButton(onPressed: notice, child: const Text('重新检查导入授权')),
            if (error != null) Semantics(liveRegion: true, child: Text(error!)),
            if (busy)
              Semantics(
                liveRegion: true,
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    Text(checkingConsent ? '正在确认导入授权…' : '正在分析，待整份审核完成后展示…'),
                  ],
                ),
              ),
            if (r is Processing) const Text('同一请求仍在处理中，稍后可查看结果。'),
            if (r is NoResult)
              Text(
                r.terminal
                    ? '本次分析已结束，没有可用建议。修改输入后可开始新的分析。'
                    : '暂无完整可用的建议。可检查输入后重试。',
              ),
            if (r is Crisis)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.support_outlined),
                  title: Text('先暂停练习，找人陪你'),
                  subtitle: Text('全国心理援助热线 12356；如有人身危险，请立即拨打 110 或 120。'),
                ),
              ),
            if (r is! Approved &&
                r is! Crisis &&
                !(r is NoResult && r.terminal))
              FilledButton(
                onPressed:
                    allowed == true &&
                        !busy &&
                        !mustEdit &&
                        chat.text.trim().isNotEmpty
                    ? analyze
                    : null,
                child: Text(
                  mustEdit
                      ? '请先修改输入'
                      : operation == null
                      ? '开始分析'
                      : r is Processing
                      ? '查看原请求结果'
                      : '重试原请求',
                ),
              ),
            if (r is Approved)
              ReplyCards(
                key: ObjectKey(r),
                answer: r,
                repo: widget.repo,
                contactId: operation?['contact_id'] as String?,
              ),
          ],
        ),
      ),
    );
  }
}
