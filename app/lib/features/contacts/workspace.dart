import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/transport.dart';
import 'deletion.dart';
import 'forms.dart';
import 'inference.dart';
import 'models.dart';
import 'profile.dart';
import 'purpose.dart';
import 'repository.dart';
import 'scene.dart';

enum _View { list, detail, add, edit, chat, remove, choose }

enum _ConsentFence { current, changed, unconfirmed }

typedef _InferenceOperation = ({
  String contactId,
  String requestId,
  String text,
  ContactInferenceGrant authorization,
});

const _growthRecovery = '联网打开成长档案，刷新后可恢复离线记录。';

class ContactsWorkspace extends StatefulWidget {
  const ContactsWorkspace({
    required this.repo,
    required this.selection,
    this.demo = false,
    this.deletion,
    super.key,
  });
  final ContactsRepository repo;
  final SceneMemory selection;
  final bool demo;
  final ContactDeletion? deletion;
  @override
  State<ContactsWorkspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<ContactsWorkspace>
    with WidgetsBindingObserver {
  Book? book;
  String? id, message;
  bool busy = false;
  var view = _View.list;
  ContactPurpose? pending;
  List<Question> questions = [];
  Timer? expiry;
  bool needsRefresh = false;
  List<GrowthDeletion> _pendingDeletions = [];
  ContactInferenceGrant? _chatEntryGrant;
  _InferenceOperation? _inference;
  ProfileInferenceResult? _inferenceResult;
  final _verifiedPresent = <String, GrowthDeletion>{};
  bool _deletionRecordUnavailable = false;
  Contact? get current => book?.people.where((p) => p.id == id).firstOrNull;
  bool get _canCheckDeletion =>
      _pendingDeletions.isNotEmpty || _deletionRecordUnavailable;

  bool _needsDeletionCheck(String contactId) =>
      !_verifiedPresent.containsKey(contactId) &&
      _pendingDeletions.any((op) => op.contactId == contactId);
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
    await _syncDeletionRecords();
    if (!mounted) return;
    final next = await widget.repo.load();
    if (!mounted) return;
    book = next;
    final inference = _inference;
    if (inference != null) {
      final contact = next.people
          .where((person) => person.id == inference.contactId)
          .firstOrNull;
      if (contact == null || !next.usable(contact)) _clearInference();
    }
    expiry?.cancel();
    final until = next.expires;
    if (next.member && until != null) {
      expiry = Timer(until.difference(DateTime.now()), _refresh);
    }
    final priorView = view;
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
    if (view != priorView) pending = null;
  }

  // The input itself is never captured by an authorization callback. A missing
  // grant replaces the form; accepting later opens a fresh form, not a replay.
  Future<ContactConsentSnapshot?> _authorized(_View target) async {
    final consents = await widget.repo.currentConsents();
    if (!mounted) return null;
    view = target;
    pending = [
      ContactPurpose.contacts,
      if (target == _View.chat) ContactPurpose.chatImport,
    ].where((p) => !consents.allows(p)).firstOrNull;
    return pending == null ? consents : null;
  }

  Future<void> _enter(_View target) async {
    final consents = await _authorized(target);
    if (consents == null) return;
    if (target == _View.chat) {
      _chatEntryGrant = consents.inferenceGrant;
    }
    if (target == _View.add) questions = await widget.repo.questions();
  }

  void _clearInference() {
    _chatEntryGrant = null;
    _inference = null;
    _inferenceResult = null;
  }

  Future<_ConsentFence> _checkInferenceConsent(
    ContactInferenceGrant authorization,
  ) async {
    try {
      final current = await widget.repo.currentConsents();
      return current.inferenceGrant == authorization
          ? _ConsentFence.current
          : _ConsentFence.changed;
    } on SessionChanged {
      rethrow;
    } on ApiFailure catch (error) {
      if (error.status == 401 || error.status == 403 || error.status == 404) {
        rethrow;
      }
      return _ConsentFence.unconfirmed;
    } on Object {
      return _ConsentFence.unconfirmed;
    }
  }

  void _applyInferenceProfile(String contactId, Json profile) {
    final currentBook = book;
    if (currentBook == null) return;
    final people = [
      for (final contact in currentBook.people)
        if (contact.id == contactId)
          Contact.fromJson({
            'id': contact.id,
            'nickname': contact.name,
            'scene': contact.scene.name,
            'editable': contact.editable,
            'profile': profile,
          })
        else
          contact,
    ];
    book = Book(people, currentBook.rights);
  }

  Future<void> _infer({
    required String contactId,
    String? text,
    _InferenceOperation? retry,
    ContactInferenceGrant? entryAuthorization,
  }) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final consents = await _authorized(_View.chat);
      if (consents == null) {
        if (!mounted) return;
        setState(_clearInference);
        return;
      }
      if (!mounted) return;
      final currentBook = book;
      final contact = currentBook?.people
          .where((person) => person.id == contactId)
          .firstOrNull;
      if (currentBook == null ||
          contact == null ||
          !currentBook.usable(contact)) {
        setState(() {
          _clearInference();
          view = _View.list;
          id = null;
        });
        _refresh();
        return;
      }
      final authorization = consents.inferenceGrant!;
      final expectedAuthorization = retry?.authorization ?? entryAuthorization;
      if (expectedAuthorization == null ||
          expectedAuthorization != authorization) {
        setState(() {
          _clearInference();
          view = _View.detail;
          pending = null;
          message = '授权记录已变化，已清除旧片段，请重新导入。';
        });
        return;
      }
      final operation =
          retry ??
          (
            contactId: contactId,
            requestId: newRequestId(),
            text: text!,
            authorization: authorization,
          );
      setState(() {
        _chatEntryGrant = null;
        _inference = operation;
        if (retry == null) _inferenceResult = null;
      });
      final result = await widget.repo.infer(
        operation.contactId,
        operation.requestId,
        operation.text,
        authorization: operation.authorization,
      );
      if (!mounted) return;
      final fence = await _checkInferenceConsent(operation.authorization);
      if (!mounted) return;
      if (fence != _ConsentFence.current) {
        setState(() {
          _clearInference();
          view = book == null ? _View.list : _View.detail;
          message = fence == _ConsentFence.changed
              ? '授权记录已变化，已清除旧片段，请重新导入。'
              : '授权状态未能确认，未展示结果，旧片段已清除。';
        });
        return;
      }
      setState(() {
        view = _View.detail;
        switch (result) {
          case ProfileInferenceProcessing():
            _inferenceResult = result;
          case ProfileInferenceCompleted(:final profile):
            _clearInference();
            _applyInferenceProfile(operation.contactId, profile);
            message = '画像已更新，仅供参考。';
          case ProfileInferenceSafety():
            _clearInference();
            message = profileInferenceSafetyMessage;
          case ProfileInferenceTerminal(:final status):
            _clearInference();
            message = status == 200
                ? '画像结果不完整，本次导入已结束。请刷新后核对。'
                : '服务返回了无法确认的状态，本次导入已结束。';
        }
      });
    } on ContactConsentChanged {
      if (!mounted) return;
      setState(() {
        _clearInference();
        view = book == null ? _View.list : _View.detail;
        pending = null;
        message = '授权记录已变化，已清除旧片段，请重新导入。';
      });
    } on ConsentUnconfirmed {
      if (!mounted) return;
      setState(() {
        _clearInference();
        view = book == null ? _View.list : _View.detail;
        pending = null;
        message = '授权状态未能确认，已清除旧片段，请重新导入。';
      });
    } on SessionChanged {
      if (!mounted) return;
      setState(() {
        _clearInference();
        pending = null;
        book = null;
        id = null;
        view = _View.list;
        message = '账号已切换，请重新打开关系人。';
      });
    } on ApiFailure catch (error) {
      if (!mounted) return;
      if (error.status == 403 || error.status == 404) {
        setState(() {
          _clearInference();
          id = null;
          view = _View.list;
        });
        try {
          await _load();
        } catch (_) {
          book = null;
        }
        if (!mounted) return;
        message = '权限或关系人已变更，请核对最新列表。';
      } else if (error.status == 401) {
        setState(() {
          _clearInference();
          pending = null;
          book = null;
          id = null;
          view = _View.list;
          message = '登录状态已变更，请重新登录。';
        });
      } else if (error.status == 400 || error.status == 409) {
        setState(() {
          _clearInference();
          view = book == null ? _View.list : _View.detail;
          message = error.status == 409
              ? '这次请求已失效，不能继续重试。请重新导入片段。'
              : '这次片段未能提交，不能继续重试。请重新导入片段。';
        });
      } else {
        setState(() {
          view = book == null ? _View.list : _View.detail;
          _inferenceResult = null;
          message = error.status == 503
              ? '服务暂不可用，可重试。本次未展示新的画像。'
              : '暂时无法确认结果，可用原请求重试。本次未展示新的画像。';
        });
      }
    } on FormatException {
      if (!mounted) return;
      setState(() {
        view = book == null ? _View.list : _View.detail;
        _inferenceResult = null;
        message = '画像结果未完整返回，可用原请求重试。';
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        view = book == null ? _View.list : _View.detail;
        _inferenceResult = null;
        message = '连接未完成，可用原请求重试。';
      });
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

  void _startInference(Contact contact, String text) {
    if (_inference != null) {
      setState(() => message = '还有一次导入结果待处理，请先完成原请求。');
      return;
    }
    _infer(
      contactId: contact.id,
      text: text,
      entryAuthorization: _chatEntryGrant,
    );
  }

  void _retryInference() {
    final operation = _inference;
    if (operation == null) return;
    final currentBook = book;
    final contact = currentBook?.people
        .where((person) => person.id == operation.contactId)
        .firstOrNull;
    if (currentBook == null ||
        contact == null ||
        !currentBook.usable(contact)) {
      setState(() {
        _clearInference();
        view = _View.list;
        id = null;
      });
      _refresh();
      return;
    }
    _infer(contactId: operation.contactId, retry: operation);
  }

  Widget _inferencePanel(BuildContext context) {
    final processing = _inferenceResult is ProfileInferenceProcessing;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            processing ? '画像仍在处理中，不是已更新。' : '本次导入结果尚未确认。',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            processing ? '可以使用原请求继续获取结果；这不会提交一段新的材料。' : '请使用原请求重试，不会再次提交新的材料。',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: busy ? null : _retryInference,
            child: const Text('重试获取结果'),
          ),
        ],
      ),
    );
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
      pending = null;
      if (e is DeletionNotSent) {
        view = _View.remove;
        message = '删除未发送。请检查本机存储，或返回列表核对上次的删除结果。';
      } else if (e is ConsentUnconfirmed) {
        view = id == null ? _View.list : _View.detail;
        message = '授权未能确认，请重新打开后再试。';
      } else if (e is ApiFailure && (e.status == 403 || e.status == 404)) {
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

  Future<void> _remove(Contact contact) async {
    String feedback;
    var cacheError = false;
    try {
      final deletion = widget.deletion;
      if (deletion == null) {
        await widget.repo.remove(contact.id);
      } else {
        await deletion.remove(contact.id, retry: _verifiedPresent[contact.id]);
      }
      feedback = '关系人已删除。';
    } on SessionChanged {
      return;
    } on DeletionNotSent {
      rethrow;
    } on DeletionCacheUnconfirmed {
      cacheError = true;
      feedback = '关系人已删除，但本机成长缓存暂未清理。';
    } on Object catch (error) {
      if (widget.deletion == null) rethrow;
      feedback =
          error is ApiFailure && (error.status == 403 || error.status == 404)
          ? '权限或关系人已变更，删除结果尚未确认。'
          : '暂时无法确认删除结果。';
    }
    await _reloadAfterDeletion();
    if (!mounted) return;
    message = [
      feedback,
      if (_canCheckDeletion) '请点「核对删除结果」。' else if (cacheError) _growthRecovery,
    ].join();
  }

  Future<void> _syncDeletionRecords() async {
    final deletion = widget.deletion;
    if (deletion == null) return;
    try {
      final operations = await deletion.pending();
      if (!mounted) return;
      _pendingDeletions = operations;
      _verifiedPresent.removeWhere((_, op) => !operations.contains(op));
      _deletionRecordUnavailable = false;
    } on Object {
      if (!mounted) return;
      _verifiedPresent.clear();
      _deletionRecordUnavailable = true;
    }
  }

  Future<void> _reloadAfterDeletion() async {
    if (!mounted) return;
    id = null;
    view = _View.list;
    try {
      await _load();
    } catch (_) {
      book = null;
    }
  }

  Future<void> _checkDeletions() async {
    final deletion = widget.deletion!;
    await _syncDeletionRecords();
    if (!mounted) return;
    var removed = 0;
    var cacheError = false;
    var failed = _deletionRecordUnavailable;
    _verifiedPresent.clear();
    for (final operation in _pendingDeletions) {
      try {
        final result = await deletion.check(operation);
        if (!mounted) return;
        if (result == DeletionCheck.present) {
          _verifiedPresent[operation.contactId] = operation;
        }
        if (result == DeletionCheck.absent) removed++;
      } on DeletionCacheUnconfirmed {
        removed++;
        cacheError = true;
      } on SessionChanged {
        return;
      } on Object {
        failed = true;
      }
      if (!mounted) return;
    }
    await _reloadAfterDeletion();
    if (!mounted) return;
    final canHandlePresent =
        book?.people.any(
          (contact) => _verifiedPresent.containsKey(contact.id),
        ) ??
        false;
    message = [
      if (removed > 0) '已核实 $removed 笔删除。',
      if (canHandlePresent)
        '核对时仍在的关系人可重新删除，也可放弃重试。'
      else if (_verifiedPresent.isNotEmpty)
        '核对时关系人仍在，请刷新列表后处理。',
      if (cacheError && _canCheckDeletion) '本机成长缓存暂未清理，请检查存储后重试。',
      if (failed) '部分记录暂未核对完成，请联网重试。',
      if (!_canCheckDeletion) _growthRecovery,
    ].join();
  }

  Future<void> _abandonDeletion(GrowthDeletion operation) async {
    _verifiedPresent.remove(operation.contactId);
    String feedback;
    try {
      final result = await widget.deletion!.check(operation, abandon: true);
      feedback = switch (result) {
        DeletionCheck.abandoned => '已放弃重试。核对时关系人仍在。',
        DeletionCheck.absent => '已核实关系人已删除。',
        _ => '删除记录已更新。',
      };
    } on DeletionCacheUnconfirmed {
      feedback = '已核实关系人已删除，但本机成长缓存暂未清理。';
    } on SessionChanged {
      return;
    } on Object {
      feedback = '暂时无法完成处理，请稍后重试。';
    }
    await _reloadAfterDeletion();
    if (!mounted) return;
    message = _canCheckDeletion ? feedback : '$feedback$_growthRecovery';
  }

  void _show(_View v) {
    setState(() {
      if (v != _View.chat) _chatEntryGrant = null;
      message = null;
      pending = null;
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
                  ? Column(
                      children: [
                        Expanded(
                          child: StatusPanel(
                            busy ? '正在翻开关系手记…' : message ?? '无法读取关系人',
                            retry: busy ? null : _refresh,
                          ),
                        ),
                        if (_canCheckDeletion)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: _checkDeletionButton(),
                          ),
                      ],
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

  Widget _checkDeletionButton() => OutlinedButton(
    onPressed: busy ? null : () => _run(_checkDeletions),
    child: const Text('核对删除结果'),
  );

  List<Widget> _content(BuildContext context, Book b, Contact? c) => [
    if (pending case final purpose?) ...[
      Text(
        purpose == ContactPurpose.contacts ? '允许建立关系人手记？' : '允许使用聊天片段推断画像？',
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 12),
      Text(
        purpose == ContactPurpose.contacts
            ? '称呼、交流场景和问答将用于建立关系人画像。$retention'
            : '$chatRetention 不导入也可以继续使用已有手记。',
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () => _run(() async {
          await widget.repo.grant(purpose);
          if (mounted) await _enter(view);
        }),
        child: const Text('同意并继续'),
      ),
      TextButton(onPressed: _back, child: const Text('暂不同意')),
    ] else if (view == _View.list) ...[
      Text('常联系的人', style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 8),
      if (_canCheckDeletion) ...[
        const Text('还有删除结果待处理。成长档案暂时无法使用离线记录。'),
        _checkDeletionButton(),
        const SizedBox(height: 12),
      ],
      Text(
        !b.consistent
            ? '可用名额尚未确认。请刷新后再操作。'
            : b.member
            ? '可用关系人可用于练习和反馈。'
            : '免费可用 1 位。到期后默认保留最近使用的人，也可以改选；续费后恢复。',
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: b.canAdd ? () => _run(() => _enter(_View.add)) : null,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('添加关系人'),
      ),
      if (b.people.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text('还没有关系人。从一个常交流的人开始吧。'),
        ),
      for (final p in b.people) ...[
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
        if (_verifiedPresent[p.id] case final operation?)
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton(
                onPressed: () {
                  id = p.id;
                  _show(_View.remove);
                },
                child: const Text('重新删除'),
              ),
              TextButton(
                onPressed: () => _run(() => _abandonDeletion(operation)),
                child: const Text('放弃重试'),
              ),
            ],
          ),
      ],
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
            if (await _authorized(view) == null) return;
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
        if (_inference?.contactId == c.id) _inferencePanel(context),
        if (b.usable(c)) ...[
          OutlinedButton(
            onPressed: () => _run(() => _enter(_View.edit)),
            child: const Text('编辑资料'),
          ),
          if (_inference == null)
            OutlinedButton(
              onPressed: () => _run(() => _enter(_View.chat)),
              child: const Text('导入聊天片段'),
            )
          else if (_inference?.contactId != c.id)
            const Text('还有一次导入结果待处理，请先回到对应关系人完成。'),
        ] else ...[
          const Text('只读 · 不能用于新练习、修改资料或接收反馈。'),
          if (b.canChoose(c))
            OutlinedButton(
              onPressed: () => _run(() => _enter(_View.choose)),
              child: const Text('改选为可用关系人'),
            ),
        ],
        TextButton(
          onPressed: _needsDeletionCheck(c.id)
              ? null
              : () => _show(_View.remove),
          child: const Text('删除关系人'),
        ),
        if (_needsDeletionCheck(c.id)) const Text('请返回关系人列表核对上次的删除结果。'),
      ],
      if (view == _View.choose) ...[
        Text('把唯一的可用名额改给「${c.name}」？原可用关系人会变为只读，已有记录不会删除。'),
        FilledButton(
          onPressed: !b.canChoose(c)
              ? null
              : () => _run(() async {
                  if (await _authorized(_View.choose) == null) return;
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
          onPressed: () => _run(() => _remove(c)),
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
            _startInference(c, text);
          },
        ),
    ],
  ];
}
