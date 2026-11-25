import 'package:flutter/foundation.dart' show mapEquals;
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

class _ReplySubmissionChanged implements Exception {
  const _ReplySubmissionChanged();
}

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
  bool _recoveringDenial = false;
  bool consentWithdrawn = false;
  bool mustEdit = false;
  bool mustChooseContact = false;
  int _rosterLoad = 0;
  int _contactChoiceVersion = 0;
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
    final load = ++_rosterLoad;
    final choice = _contactChoiceVersion;
    try {
      final items = await widget.repo.contacts();
      if (!mounted || load != _rosterLoad || choice != _contactChoiceVersion) {
        return;
      }
      setState(() {
        people = items;
        if (contact != null && !items.any((c) => c.id == contact)) {
          contact = null;
          operation = null;
          mustEdit = false;
          mustChooseContact = true;
          error = '原关联关系人已不可用。草稿已保留，请改选关系人或取消关联后再分析。';
        }
        contactError = false;
      });
    } catch (_) {
      if (mounted && load == _rosterLoad && choice == _contactChoiceVersion) {
        setState(() => contactError = true);
      }
    }
  }

  Future<void> notice({bool grant = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      checkingConsent = true;
      error = null;
    });
    try {
      if (grant) await widget.repo.grant();
      final ok = grant || await widget.repo.allowed();
      if (mounted) {
        setState(() {
          allowed = ok;
          if (ok) consentWithdrawn = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = '未能确认本次回复授权，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          checkingConsent = false;
        });
      }
    }
  }

  void edited({bool contactChoice = false}) {
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
      if (contactChoice) {
        _contactChoiceVersion++;
        if (_recoveringDenial) error = null;
        mustChooseContact = false;
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

  void _requireContactChoice(String message, {List<Contact>? roster}) {
    _rosterLoad++;
    setState(() {
      people = roster ?? [];
      contact = null;
      operation = null;
      contactError = roster == null;
      mustEdit = false;
      mustChooseContact = true;
      error = message;
    });
  }

  void _contactConsentMissing() =>
      _requireContactChoice('关系人授权已失效。草稿已保留，请取消关联，或回关系人手记重新授权。', roster: []);

  Future<void> _refreshPeopleAfterDenied() async {
    final load = ++_rosterLoad;
    final choice = _contactChoiceVersion;
    final selected = contact;
    try {
      final items = await widget.repo.contacts(verifyConsent: selected != null);
      if (!mounted || load != _rosterLoad || choice != _contactChoiceVersion) {
        return;
      }
      setState(() {
        people = items;
        contactError = false;
        if (selected != null && !items.any((c) => c.id == selected)) {
          contact = null;
          operation = null;
          mustEdit = false;
          mustChooseContact = true;
          error = '原关联关系人已不可用。草稿已保留，请改选关系人或取消关联后再分析。';
        }
      });
    } on ReplyContactConsentMissing {
      if (mounted && load == _rosterLoad && choice == _contactChoiceVersion) {
        _contactConsentMissing();
      }
    } catch (_) {
      if (mounted && load == _rosterLoad && choice == _contactChoiceVersion) {
        setState(() {
          contactError = true;
          if (selected != null) {
            error = '暂时无法确认关系人权限，原请求已保留，请稍后重试。';
          }
        });
      }
    }
  }

  Future<void> _analysisDenied(ApiFailure failure) async {
    final repo = widget.repo;
    final choice = _contactChoiceVersion;
    final expired =
        failure.code == 'reply_consent_expired' && failure.retryable == false;
    setState(() {
      _recoveringDenial = true;
      if (expired) {
        operation = null;
      }
      error = expired ? '原请求的授权已失效。草稿已保留，请重新开始分析。' : '授权或关系人权限已变更，请检查后重试。';
    });
    bool sameChoice() =>
        mounted &&
        identical(widget.repo, repo) &&
        _contactChoiceVersion == choice;
    if (!expired) await _refreshPeopleAfterDenied();
    if (!sameChoice()) return;
    final selected = contact;
    final request = operation;
    final needsContact = mustChooseContact;
    final draft = _draft();
    bool isCurrent() =>
        sameChoice() &&
        selected == contact &&
        identical(operation, request) &&
        needsContact == mustChooseContact &&
        mapEquals(draft, _draft());
    try {
      final ok = await repo.allowed();
      if (!isCurrent()) return;
      setState(() {
        allowed = ok;
        consentWithdrawn = !ok;
        if (!ok) error = null;
      });
    } catch (_) {
      if (isCurrent()) setState(() => allowed = null);
    }
  }

  Future<void> analyze() async {
    if (busy ||
        allowed != true ||
        mustEdit ||
        mustChooseContact ||
        chat.text.trim().isEmpty) {
      return;
    }
    final repo = widget.repo;
    final selected = contact;
    final choice = _contactChoiceVersion;
    final draft = _draft();
    final previousOperation = operation;
    var expectedOperation = previousOperation;

    bool isCurrent(Json? expectedOperation) =>
        mounted &&
        identical(widget.repo, repo) &&
        allowed == true &&
        !mustEdit &&
        !mustChooseContact &&
        _contactChoiceVersion == choice &&
        identical(operation, expectedOperation) &&
        mapEquals(draft, _draft());

    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      checkingConsent = true;
      error = null;
      result = null;
    });
    try {
      final replyConsentId = await repo.replyConsentId();
      if (!isCurrent(expectedOperation)) return;
      if (replyConsentId == null) {
        setState(() {
          allowed = false;
          checkingConsent = false;
          consentWithdrawn = true;
        });
        return;
      }
      String? contactConsentId;
      if (selected != null) {
        try {
          final access = await repo.contactAccess();
          final items = access.people;
          if (!isCurrent(previousOperation)) return;
          if (!items.any((c) => c.id == selected)) {
            _requireContactChoice(
              '关系人权限已变更。草稿已保留，请改选关系人或取消关联后再分析。',
              roster: items,
            );
            return;
          }
          contactConsentId = access.consentId;
          setState(() => people = items);
        } on ReplyContactConsentMissing {
          if (isCurrent(previousOperation)) _contactConsentMissing();
          return;
        } catch (_) {
          if (!isCurrent(previousOperation)) return;
          setState(() {
            error = previousOperation == null
                ? '暂时无法确认关系人权限，草稿和关联已保留，请稍后重试。'
                : '暂时无法确认关系人权限，原请求已保留，请稍后重试。';
          });
          return;
        }
      }
      final input =
          previousOperation ?? {'request_id': newRequestId(), ...draft};
      if (!replyInputFits(input)) {
        setState(() {
          allowed = true;
          checkingConsent = false;
          mustEdit = true;
          error = '内容过长，请删减对话或补充目的后重新分析。';
        });
        return;
      }
      final request = operation ??= Map.unmodifiable(input);
      expectedOperation = request;
      setState(() {
        allowed = true;
        checkingConsent = false;
      });
      final r = await repo.analyze(
        request,
        authorization: (
          replyConsentId: replyConsentId,
          contactConsentId: contactConsentId,
        ),
        checkBeforeSend: () {
          if (!isCurrent(request)) throw const _ReplySubmissionChanged();
        },
      );
      if (isCurrent(request)) setState(() => result = r);
    } on _ReplySubmissionChanged {
      // A fresher page decision already controls the next explicit action.
    } on ReplyAuthorizationChanged catch (failure) {
      if (!isCurrent(expectedOperation)) return;
      if (failure.contact) {
        _requireContactChoice('原关系人授权或使用权限已变化。草稿已保留，请改选或取消关联后再分析。');
      } else {
        setState(() {
          operation = null;
          allowed = false;
          consentWithdrawn = false;
          error = '本次回复授权已变化。草稿已保留，请重新确认后再分析。';
        });
      }
    } on ReplyAuthorizationUnavailable catch (failure) {
      if (!isCurrent(expectedOperation)) return;
      setState(() {
        if (failure.contact) {
          error = '暂时无法确认关系人权限，原请求已保留，请稍后重试。';
        } else {
          allowed = false;
          consentWithdrawn = false;
          error = '暂时无法确认本次回复授权。草稿和原请求已保留，请重新确认后再分析。';
        }
      });
    } on ReplyInputTooLarge {
      if (isCurrent(expectedOperation)) {
        setState(() {
          mustEdit = true;
          error = '内容过长，请删减对话或补充目的后重新分析。';
        });
      }
    } on ApiFailure catch (e) {
      if (!isCurrent(expectedOperation)) return;
      if (checkingConsent) {
        setState(() => error = '未能确认本次回复授权，请重试。');
        return;
      }
      if (e.status == 403) {
        await _analysisDenied(e);
        return;
      }
      if (_terminalAnalysisFailure(e)) {
        setState(() => result = NoResult(terminal: true));
        return;
      }
      setState(() {
        error = switch (e.status) {
          503 => '服务暂不可用，可重试',
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
          if (isCurrent(expectedOperation) && quota != null) {
            setState(() => error = _quotaMessage(quota));
          }
        } catch (_) {
          /* Keep the contract-backed fallback; never invent a reset time. */
        }
      }
    } on FormatException {
      if (isCurrent(expectedOperation)) {
        setState(() {
          if (checkingConsent) {
            error = '未能确认本次回复授权，请重试。';
          } else {
            result = NoResult();
          }
        });
      }
    } catch (_) {
      if (isCurrent(expectedOperation)) {
        setState(
          () => error = checkingConsent ? '未能确认本次回复授权，请重试。' : '连接未完成，可用原请求重试。',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          checkingConsent = false;
          _recoveringDenial = false;
        });
      }
    }
  }

  Widget _bottomActions() {
    final label = mustChooseContact
        ? '请改选或取消关联'
        : mustEdit
        ? '请先修改输入'
        : operation == null
        ? '开始分析'
        : result is Processing
        ? '查看原请求结果'
        : '重试原请求';
    final enabled =
        allowed == true &&
        !busy &&
        !mustEdit &&
        !mustChooseContact &&
        chat.text.trim().isNotEmpty;
    final failure =
        error ??
        (allowed == false && consentWithdrawn
            ? '本次回复授权已撤回，请重新阅读说明并同意后再分析。'
            : null);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    failure,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            ),
          if (allowed == null && !busy)
            TextButton(onPressed: notice, child: const Text('重新检查本次授权')),
          if (allowed == false) ...[
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: const ValueKey('reply-defer-import'),
                    onPressed: busy
                        ? null
                        : (widget.close ?? () => Navigator.maybePop(context)),
                    child: const Text('暂不使用'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonal(
                    key: const ValueKey('reply-accept-import'),
                    onPressed: busy ? null : () => notice(grant: true),
                    child: const Text('同意本次说明'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('reply-analyze'),
              onPressed: enabled ? analyze : null,
              child: Text(label),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final r = result;
    return Scaffold(
      appBar: AppBar(
        title: const Text('回复助手'),
        leading: widget.close == null
            ? null
            : CloseButton(onPressed: widget.close),
      ),
      bottomNavigationBar:
          r is! Approved && r is! Crisis && !(r is NoResult && r.terminal)
          ? _bottomActions()
          : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 36),
          children: [
            if (allowed == false) ...[
              Card(
                key: const ValueKey('reply-import-notice'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('本次回复说明', style: type.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        '只有你点「开始分析」后，才会提交聊天文字和可选目的。所选关系人的画像摘要也会用于生成建议。请只提交你有权分享的文字。',
                        style: type.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('数据留存范围', style: type.labelLarge),
                            const SizedBox(height: 2),
                            Text(
                              '回复服务不保存提交的聊天原文和目的；会保存带密钥的输入摘要、授权与请求关联、审核后的加密建议和可选效果反馈。',
                              style: type.bodySmall,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '关系人入口的既有导入记录满 24 小时后尝试清除，故障时会重试。供应商、日志、备份或物理介质中的副本不保证同期删除。',
                              style: type.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
            Text('先听懂，再回应', style: type.headlineSmall),
            const SizedBox(height: 6),
            Text(widget.demo ? '契约模拟 · 不会发送数据' : '建议仅供参考，应用不会自动发给对方。'),
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
              onChanged: busy && !_recoveringDenial
                  ? null
                  : (v) {
                      contact = v == '' ? null : v;
                      edited(contactChoice: true);
                    },
            ),
            if (contactError)
              TextButton(
                onPressed: loadPeople,
                child: const Text('关系人未载入 · 重试（也可不选）'),
              ),
            if (mustChooseContact)
              TextButton(
                onPressed: busy && !_recoveringDenial
                    ? null
                    : () => edited(contactChoice: true),
                child: const Text('取消关联'),
              ),
            const SizedBox(height: 18),
            if (busy)
              Semantics(
                liveRegion: true,
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    Text(checkingConsent ? '正在确认本次授权…' : '正在分析，待整份审核完成后展示…'),
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
