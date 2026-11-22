import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../contacts/models.dart' show newRequestId;
import '../contacts/scene.dart';
import 'book.dart';
import 'form.dart';
import 'model.dart';
import 'repository.dart';
import 'result.dart';

export 'model.dart' show ReviewPrefill;
export 'repository.dart' show ApiReviews, ReviewConsent, ReviewRepository;

class ReviewPage extends StatefulWidget {
  const ReviewPage(this.repo, {super.key, this.prefill});

  final ReviewRepository repo;
  final ReviewPrefill? prefill;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  final happened = TextEditingController();
  final myFeeling = TextEditingController();
  final theirFeeling = TextEditingController();
  final myAction = TextEditingController();
  final nextAction = TextEditingController();

  String requestId = newRequestId();
  String? markId;
  String? contactId;
  Scene? scene;
  DateTime? occurredAt;
  String? contactName;
  List<ReviewPerson> people = const [];
  String? actionError;
  String? draftError;
  ReviewDraft? draftConflict;
  ReviewAttempt? attempt;
  ReviewDraft? submittedDraft;
  int stage = 0;
  int tab = 0;
  bool loading = true;
  bool saving = false;
  bool submitting = false;
  bool confirming = false;
  bool canRetry = false;
  bool _draftSealed = false;
  int _editRevision = 0;
  int _pendingSaves = 0;
  List<ReviewDraft> _possibleAttempts = const [];
  int bookRevision = 0;
  Completer<void>? _saveSettled;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    happened.dispose();
    myFeeling.dispose();
    theirFeeling.dispose();
    myAction.dispose();
    nextAction.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    ReviewDraft? saved;
    String? warning;
    try {
      saved = await widget.repo.loadDraft();
    } catch (_) {
      warning = '上次草稿未能恢复，可以继续填写。';
    }
    if (!mounted) return;
    final prefill = widget.prefill;
    if (saved != null && prefill != null && saved.markId != prefill.markId) {
      setState(() {
        draftConflict = saved;
        loading = false;
        draftError = null;
      });
      _loadPeople();
      return;
    }
    _apply(saved ?? ReviewDraft.blank(requestId: requestId, prefill: prefill));
    setState(() {
      loading = false;
      draftError = warning;
    });
    _loadPeople();
    if (saved == null && prefill != null) await _save();
  }

  void _apply(ReviewDraft draft) {
    requestId = draft.requestId;
    markId = draft.markId;
    contactId = draft.contactId;
    scene = draft.scene;
    occurredAt = draft.occurredAt;
    happened.text = draft.happened;
    myFeeling.text = draft.myFeeling;
    theirFeeling.text = draft.theirFeeling;
    myAction.text = draft.myAction;
    nextAction.text = draft.nextAction;
    _possibleAttempts = draft.possibleAttempts;
    _editRevision++;
  }

  Future<void> _loadPeople() async {
    try {
      final rows = await widget.repo.people();
      if (!mounted) return;
      setState(() {
        people = rows;
        contactName = _nameOf(contactId);
      });
    } catch (_) {
      // A missing relation list must not block writing a review.
    }
  }

  String? _nameOf(String? id) {
    if (id == null) return null;
    for (final person in people) {
      if (person.id == id) return person.name;
    }
    return null;
  }

  ReviewDraft _draft() => ReviewDraft(
    requestId: requestId,
    happened: happened.text.trim(),
    myFeeling: myFeeling.text.trim(),
    theirFeeling: theirFeeling.text.trim(),
    myAction: myAction.text.trim(),
    nextAction: nextAction.text.trim(),
    possibleAttempts: _possibleAttempts,
    contactId: contactId,
    markId: markId,
    scene: scene,
    occurredAt: occurredAt,
  );

  bool get _complete => [
    happened.text,
    myFeeling.text,
    theirFeeling.text,
    myAction.text,
    nextAction.text,
  ].every((value) => value.trim().isNotEmpty);

  bool get _stageReady => switch (stage) {
    0 => happened.text.trim().isNotEmpty,
    1 =>
      myFeeling.text.trim().isNotEmpty && theirFeeling.text.trim().isNotEmpty,
    2 => myAction.text.trim().isNotEmpty,
    _ => nextAction.text.trim().isNotEmpty,
  };

  void _changed(String _) {
    setState(() {
      _editRevision++;
      submittedDraft = null;
      actionError = null;
      canRetry = false;
    });
    _save();
  }

  Future<bool> _save() {
    if (_draftSealed) return Future.value(false);
    return _persistDraft(_draft());
  }

  Future<bool> _persistDraft(ReviewDraft draft) async {
    _pendingSaves++;
    _saveSettled ??= Completer<void>();
    if (mounted) setState(() => saving = true);
    var saved = false;
    try {
      await widget.repo.saveDraft(draft);
      saved = true;
      if (mounted && !_draftSealed) setState(() => draftError = null);
    } catch (_) {
      if (mounted && !_draftSealed) {
        setState(() => draftError = '草稿暂时无法保存，请保持页面打开。');
      }
    } finally {
      _pendingSaves--;
      if (_pendingSaves == 0) {
        final settled = _saveSettled;
        _saveSettled = null;
        if (mounted) setState(() => saving = false);
        settled?.complete();
      }
    }
    return saved;
  }

  Future<void> _flushSaves() async {
    while (true) {
      final settled = _saveSettled;
      if (settled == null) return;
      await settled.future;
    }
  }

  Future<void> _next() async {
    if (!_stageReady || stage >= 3) return;
    FocusScope.of(context).unfocus();
    setState(() => stage++);
  }

  void _back() {
    FocusScope.of(context).unfocus();
    if (stage > 0) setState(() => stage--);
  }

  Future<void> _submit() async {
    if (submitting || confirming || !_complete) return;
    final revision = _editRevision;
    final draft = _draft();
    setState(() => confirming = true);
    try {
      if (!await _allow() || !mounted) return;
      if (revision != _editRevision) {
        setState(() => actionError = '内容已更新，请按当前内容重新提交。');
        return;
      }
      await _submitDraft(draft);
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  ReviewConsent? get _consent =>
      widget.repo is ReviewConsent ? widget.repo as ReviewConsent : null;

  Future<bool> _allow() async {
    final consent = _consent;
    if (consent == null) return true;
    try {
      if (await consent.allowed()) return true;
    } catch (_) {
      if (mounted) setState(() => actionError = '暂时无法确认复盘授权，请重试。');
      return false;
    }
    if (!mounted) return false;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提交前确认'),
        content: const Text(
          '这五段文字可能包含他人信息，会发送给服务器，用于生成 AI 复盘和评分。只有成功生成后才计一次；草稿和打开页面不扣次。服务器会加密保存，直到你删除该复盘或注销账号。请只填写你有权使用的信息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不提交'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('同意并提交'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return false;
    try {
      await consent.grant();
      return true;
    } catch (_) {
      if (mounted) setState(() => actionError = '授权未确认，请稍后重试。');
      return false;
    }
  }

  Future<void> _submitDraft(ReviewDraft draft) async {
    final previousAttempts = _possibleAttempts;
    ReviewDraft? matchingAttempt;
    for (final entry in previousAttempts.reversed) {
      if (entry.sameSubmission(draft)) {
        matchingAttempt = entry;
        break;
      }
    }
    final nextRequestId =
        matchingAttempt?.requestId ??
        (previousAttempts.any((entry) => entry.requestId == requestId)
            ? newRequestId()
            : requestId);
    final submitted = draft.copyWith(
      requestId: nextRequestId,
      possibleAttempts: const [],
    );
    final possibleAttempts = matchingAttempt == null
        ? [...previousAttempts, submitted]
        : previousAttempts;
    FocusScope.of(context).unfocus();
    setState(() {
      submitting = true;
      actionError = null;
      canRetry = false;
      submittedDraft = submitted;
      requestId = nextRequestId;
      _possibleAttempts = possibleAttempts;
      if (attempt is! ReviewProcessing) attempt = null;
    });
    try {
      // Write ahead of the final consent check: a restart after POST must
      // already have the key, with no save or other await between consent
      // and POST. Keep every prior possible request in this draft session.
      if (!await _persistDraft(_draft())) {
        _possibleAttempts = previousAttempts;
        if (mounted) setState(() => actionError = '草稿未能保存，暂未提交。');
        return;
      }
      if (!mounted) return;
      if (!await _isAllowedNow()) {
        if (!mounted) return;
        setState(() {
          canRetry = true;
          actionError = '复盘授权已撤回或暂时无法确认，未发送正文。请重新确认后重试。';
          _possibleAttempts = previousAttempts;
        });
        // Only undo this preparation. A retry of an already sent request
        // must keep its existing entry even when consent is now denied.
        if (matchingAttempt == null) await _save();
        return;
      }
      if (!mounted) return;
      final result = await widget.repo.submit(submitted);
      if (result is ReviewReady) {
        _draftSealed = true;
        await _flushSaves();
        try {
          await widget.repo.discardDraft(submitted);
        } catch (_) {
          // Keep the draft sealed so an older save cannot resurrect it.
        }
      }
      if (!mounted) return;
      setState(() {
        attempt = result;
        if (result is ReviewReady) bookRevision++;
      });
    } on ApiFailure catch (failure) {
      if (!mounted) return;
      final moderation =
          failure.status == 503 && failure.code == 'moderation_unavailable';
      setState(() {
        attempt = null;
        canRetry =
            moderation || (failure.retryable ?? false) || failure.status == 500;
        actionError = switch (failure.status) {
          503 when moderation => '服务暂不可用，可重试',
          403 => '复盘授权或关系人权限已变更，请检查后重试。',
          429 => '今日复盘次数已用完，请稍后再来。',
          409 => '这次请求与已提交内容不一致，请修改后再试。',
          500 => '暂时无法确认本次结果，可能已生成并计次。请用原请求查看结果。',
          _ => '连接未完成，可用原请求重试。',
        };
      });
    } on FormatException {
      if (mounted) {
        setState(() {
          attempt = null;
          canRetry = true;
          actionError = '复盘结果未完整返回，可用原请求重试。';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          attempt = null;
          canRetry = true;
          actionError = '连接未完成，可用原请求重试。';
        });
      }
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Future<bool> _isAllowedNow() async {
    final consent = _consent;
    if (consent == null) return true;
    try {
      return await consent.allowed();
    } catch (_) {
      return false;
    }
  }

  Future<void> _retry() async {
    final draft = submittedDraft;
    if (draft == null || submitting || confirming) return;
    final revision = _editRevision;
    setState(() => confirming = true);
    try {
      if (!await _allow() || !mounted) return;
      if (revision != _editRevision) {
        setState(() => actionError = '内容已更新，请按当前内容重新提交。');
        return;
      }
      await _submitDraft(draft);
    } finally {
      if (mounted) setState(() => confirming = false);
    }
  }

  void _rewrite() {
    setState(() {
      stage = 0;
      attempt = null;
      actionError = null;
      canRetry = false;
      requestId = newRequestId();
      _possibleAttempts = const [];
      submittedDraft = null;
      _draftSealed = false;
      _editRevision++;
    });
    _save();
  }

  void _continueSavedDraft() {
    final saved = draftConflict;
    if (saved == null) return;
    setState(() {
      _apply(saved);
      draftConflict = null;
      contactName = _nameOf(contactId);
      actionError = null;
      draftError = null;
    });
  }

  Future<void> _startFromMark() async {
    final prefill = widget.prefill;
    if (prefill == null) return;
    setState(() {
      _apply(ReviewDraft.blank(requestId: newRequestId(), prefill: prefill));
      draftConflict = null;
      contactName = _nameOf(contactId);
      actionError = null;
      draftError = null;
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('复盘与踩坑本')),
      body: SafeArea(
        child: Column(
          children: [
            _ModeTabs(
              tab: tab,
              onChanged: (value) => setState(() => tab = value),
            ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : IndexedStack(
                      index: tab,
                      children: [
                        if (draftConflict != null)
                          _DraftConflictPanel(
                            saved: draftConflict!,
                            incoming: widget.prefill!,
                            contactName: _nameOf(widget.prefill!.contactId),
                            onContinue: _continueSavedDraft,
                            onStartFresh: _startFromMark,
                          )
                        else if (attempt != null)
                          ReviewResultPanel(
                            attempt: attempt!,
                            onRewrite: _rewrite,
                            onRetry: _retry,
                            busy: submitting || confirming,
                          )
                        else
                          ReviewForm(
                            stage: stage,
                            happened: happened,
                            myFeeling: myFeeling,
                            theirFeeling: theirFeeling,
                            myAction: myAction,
                            nextAction: nextAction,
                            prefill: markId == null
                                ? null
                                : ReviewPrefill(
                                    markId: markId!,
                                    occurredAt: occurredAt,
                                    contactId: contactId,
                                    scene: scene,
                                  ),
                            contactName: contactName,
                            onChanged: _changed,
                            onNext: _stageReady && stage < 3 ? _next : null,
                            onBack: stage > 0 ? _back : null,
                            onSubmit: _complete && !canRetry ? _submit : null,
                            busy: submitting,
                            saving: saving,
                            error: actionError ?? draftError,
                            onRetry: canRetry ? _retry : null,
                          ),
                        ReviewBookView(
                          repo: widget.repo,
                          active: tab == 1,
                          revision: bookRevision,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DraftConflictPanel extends StatelessWidget {
  const _DraftConflictPanel({
    required this.saved,
    required this.incoming,
    required this.contactName,
    required this.onContinue,
    required this.onStartFresh,
  });

  final ReviewDraft saved;
  final ReviewPrefill incoming;
  final String? contactName;
  final VoidCallback onContinue;
  final VoidCallback onStartFresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final happened = saved.happened.trim();
    final at = incoming.occurredAt;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 36),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.history_toggle_off, size: 42, color: colors.primary),
              const SizedBox(height: 14),
              Text('发现一份未完成的草稿', style: theme.textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                '你刚从一条新标记进入，但本机还有另一份未提交的复盘。请明确选择要保留的内容；在你选择前不会覆盖任何草稿。',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 20),
              _ConflictCard(
                icon: Icons.edit_note_outlined,
                title: '上次草稿',
                detail: happened.isEmpty ? '还没有填写“发生了什么”' : happened,
                footnote: '请求编号 ${_shortId(saved.requestId)}',
              ),
              const SizedBox(height: 12),
              _ConflictCard(
                icon: Icons.bookmark_added_outlined,
                title: '这次标记',
                detail: at == null ? '时间未记录' : _stamp(at),
                footnote:
                    '${incoming.scene?.label ?? '未指定场景'} · ${contactName ?? (incoming.contactId == null ? '未关联对象' : '已关联对象')}',
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                key: const Key('review.conflict.continue'),
                onPressed: onContinue,
                icon: const Icon(Icons.restore),
                label: const Text('继续上次草稿'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('review.conflict.start'),
                onPressed: onStartFresh,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('从这次标记开始'),
              ),
              const SizedBox(height: 8),
              Text(
                '选择“从这次标记开始”会替换本机旧草稿；两边都不会上传录音，也不会扣次。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConflictCard extends StatelessWidget {
  const _ConflictCard({
    required this.icon,
    required this.title,
    required this.detail,
    required this.footnote,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: colors.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 5),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    footnote,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _shortId(String value) =>
    value.length <= 8 ? value : '${value.substring(0, 8)}…';

String _stamp(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _ModeTabs extends StatelessWidget {
  const _ModeTabs({required this.tab, required this.onChanged});
  final int tab;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  Expanded(
                    child: _TabButton(
                      key: const Key('review.tab.form'),
                      selected: tab == 0,
                      label: '写复盘',
                      icon: Icons.edit_note_outlined,
                      onTap: () => onChanged(0),
                    ),
                  ),
                  Expanded(
                    child: _TabButton(
                      key: const Key('review.tab.book'),
                      selected: tab == 1,
                      label: '踩坑本',
                      icon: Icons.menu_book_outlined,
                      onTap: () => onChanged(1),
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
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    super.key,
    required this.selected,
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colors.surface : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 18),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
