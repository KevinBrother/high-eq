import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../contacts/models.dart';
import '../contacts/repository.dart';
import '../contacts/scene.dart';
import '../contacts/workspace.dart';
import 'delete_confirmation.dart';
import 'records_adapter.dart';
import 'store.dart';

class OwnedDataDeleteResult {
  const OwnedDataDeleteResult({required this.kind, required this.label});

  final OwnedDataKind kind;
  final String label;
}

enum _RecordsReadStatus { applied, failed, superseded, sessionLost }

/// Outcome of one first-page query. Only [applied] may prove that a
/// post-delete list read completed against the current account and query.
class _RecordsReadResult {
  const _RecordsReadResult(
    this.status, {
    required this.revision,
    required this.kind,
  });

  final _RecordsReadStatus status;
  final int revision;
  final OwnedDataKind kind;

  bool get applied => status == _RecordsReadStatus.applied;
}

class OwnedDataRecordsPage extends StatefulWidget {
  const OwnedDataRecordsPage(this.store, {super.key});

  final PrivacyStore store;

  @override
  State<OwnedDataRecordsPage> createState() => _OwnedDataRecordsPageState();
}

class _OwnedDataRecordsPageState extends State<OwnedDataRecordsPage> {
  late final OwnedDataRecordsAdapter _adapter;
  OwnedDataKind _kind = OwnedDataKind.assessments;
  List<OwnedDataRecord> _records = const [];
  OwnedDataRecord? _selected;
  OwnedDataRecord? _deleteReceipt;
  // Only a readback started after the receipt may prove this deletion.
  int _deleteReceiptGeneration = 0;
  String? _nextCursor;
  final _seenCursors = <String>{};
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _deleting = false;
  bool _sessionLost = false;
  int _revision = 0;

  bool get _busy => _loading || _loadingMore || _deleting;

  @override
  void initState() {
    super.initState();
    _adapter = OwnedDataRecordsAdapter(widget.store);
    widget.store.api.sessions.identity.addListener(_sessionChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    widget.store.api.sessions.identity.removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() {
    if (!_isCurrentSession) _loseSession();
  }

  bool get _isCurrentSession =>
      mounted &&
      identical(widget.store.scope, _adapter.scope) &&
      identical(widget.store.api.sessions.active, _adapter.scope);

  void _loseSession() {
    if (!mounted) return;
    setState(() {
      _records = const [];
      _selected = null;
      _deleteReceipt = null;
      _nextCursor = null;
      _seenCursors.clear();
      _error = null;
      _loading = false;
      _loadingMore = false;
      _deleting = false;
      _sessionLost = true;
    });
  }

  Future<_RecordsReadResult> _readFirstPage() async {
    final revision = ++_revision;
    final kind = _kind;
    final receiptGeneration = _deleteReceiptGeneration;
    if (mounted) {
      setState(() {
        _loading = true;
        _loadingMore = false;
        _error = null;
        _records = const [];
        _selected = null;
        _nextCursor = null;
        _seenCursors.clear();
      });
    }
    try {
      final page = await _adapter.loadPage(kind: kind);
      if (!mounted || revision != _revision) {
        return _RecordsReadResult(
          _RecordsReadStatus.superseded,
          revision: revision,
          kind: kind,
        );
      }
      if (!_isCurrentSession) {
        _loseSession();
        return _RecordsReadResult(
          _RecordsReadStatus.sessionLost,
          revision: revision,
          kind: kind,
        );
      }
      if (kind != _kind) {
        return _RecordsReadResult(
          _RecordsReadStatus.superseded,
          revision: revision,
          kind: kind,
        );
      }
      setState(() {
        _records = page.items;
        _nextCursor = page.nextCursor;
        if (page.nextCursor case final cursor?) _seenCursors.add(cursor);
        _loading = false;
      });
      final result = _RecordsReadResult(
        _RecordsReadStatus.applied,
        revision: revision,
        kind: kind,
      );
      _completeDeletionReadback(result, receiptGeneration: receiptGeneration);
      return result;
    } on SessionChanged {
      if (mounted && revision == _revision) _loseSession();
      return _RecordsReadResult(
        revision == _revision
            ? _RecordsReadStatus.sessionLost
            : _RecordsReadStatus.superseded,
        revision: revision,
        kind: kind,
      );
    } on OwnedDataRecordsFailure catch (error) {
      if (!mounted || revision != _revision) {
        return _RecordsReadResult(
          _RecordsReadStatus.superseded,
          revision: revision,
          kind: kind,
        );
      }
      if (error.status == 401 || !_isCurrentSession) {
        _loseSession();
        return _RecordsReadResult(
          _RecordsReadStatus.sessionLost,
          revision: revision,
          kind: kind,
        );
      }
      setState(() {
        _error = error.message;
        _loading = false;
      });
      return _RecordsReadResult(
        _RecordsReadStatus.failed,
        revision: revision,
        kind: kind,
      );
    } catch (_) {
      if (!mounted || revision != _revision) {
        return _RecordsReadResult(
          _RecordsReadStatus.superseded,
          revision: revision,
          kind: kind,
        );
      }
      if (!_isCurrentSession) {
        _loseSession();
        return _RecordsReadResult(
          _RecordsReadStatus.sessionLost,
          revision: revision,
          kind: kind,
        );
      }
      setState(() {
        _error = ownedDataListUnavailableMessage;
        _loading = false;
      });
      return _RecordsReadResult(
        _RecordsReadStatus.failed,
        revision: revision,
        kind: kind,
      );
    }
  }

  Future<void> _reload() async {
    await _readFirstPage();
  }

  Future<void> _loadMore() async {
    final cursor = _nextCursor;
    if (cursor == null || _busy || _sessionLost) return;
    final revision = _revision;
    setState(() {
      _loadingMore = true;
      _error = null;
    });
    try {
      final page = await _adapter.loadPage(kind: _kind, cursor: cursor);
      if (!mounted || revision != _revision) return;
      if (!_isCurrentSession) {
        _loseSession();
        return;
      }
      final next = page.nextCursor;
      if (next != null && (next == cursor || _seenCursors.contains(next))) {
        setState(() {
          _loadingMore = false;
          _nextCursor = null;
          _error = '分页游标异常，已停止继续读取。';
        });
        return;
      }
      final byKey = {for (final record in _records) record.stableKey: record};
      for (final record in page.items) {
        byKey.putIfAbsent(record.stableKey, () => record);
      }
      setState(() {
        _records = List.unmodifiable(byKey.values);
        _nextCursor = next;
        if (next != null) _seenCursors.add(next);
        _loadingMore = false;
      });
    } on SessionChanged {
      if (mounted && revision == _revision) _loseSession();
    } on OwnedDataRecordsFailure catch (error) {
      if (!mounted || revision != _revision) return;
      if (error.status == 401 || !_isCurrentSession) {
        _loseSession();
        return;
      }
      setState(() {
        _loadingMore = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted || revision != _revision) return;
      if (!_isCurrentSession) {
        _loseSession();
        return;
      }
      setState(() {
        _loadingMore = false;
        _error = ownedDataListUnavailableMessage;
      });
    }
  }

  void _selectKind(OwnedDataKind kind) {
    if (kind == _kind || _busy || _deleteReceipt != null) return;
    setState(() => _kind = kind);
    unawaited(_reload());
  }

  void _toggleSelection(OwnedDataRecord record) {
    if (_busy || _sessionLost) return;
    setState(() {
      _selected = _selected?.stableKey == record.stableKey ? null : record;
      _error = null;
    });
  }

  Future<void> _pickContact() async {
    if (!_isCurrentSession || _busy || _deleteReceipt != null) return;
    final api = widget.store.api;
    final repo = ApiContacts(MobileEndpoints(api), _adapter.scope);
    final scene = SceneMemory();
    final contact = await Navigator.of(context).push<Contact>(
      MaterialPageRoute(
        builder: (_) => ValueListenableBuilder(
          valueListenable: api.sessions.identity,
          builder: (context, active, _) => identical(active, _adapter.scope)
              ? ContactsWorkspace(
                  repo: repo,
                  selection: scene,
                  onSelectForDeletion: (contact) =>
                      Navigator.pop(context, contact),
                )
              : Scaffold(
                  appBar: AppBar(title: const Text('关系人手记')),
                  body: _SessionLost(onBack: () => Navigator.pop(context)),
                ),
        ),
      ),
    );
    if (contact == null || !_isCurrentSession) return;
    late final OwnedDataRecord record;
    try {
      record = OwnedDataRecord.fromJson({
        'kind': 'contacts',
        'id': contact.id,
        'label': OwnedDataKind.contacts.label,
        'recorded_at': null,
      }, expectedKind: OwnedDataKind.contacts);
    } on FormatException {
      setState(() => _error = ownedDataInvalidPageMessage);
      return;
    }
    await _delete(
      record,
      reference: contact.scene.label,
      contactName: contact.name,
      contactId: contact.id,
    );
  }

  Future<void> _delete(
    OwnedDataRecord record, {
    required String reference,
    String? contactName,
    String? contactId,
  }) async {
    if (_busy || _sessionLost || _deleteReceipt != null) return;
    final admitted = await showOwnedDataDeleteConfirmation(
      context,
      store: widget.store,
      record: record,
      reference: reference,
      contactName: contactName,
      contactId: contactId,
    );
    if (admitted == null || !mounted) return;
    if (!_isCurrentSession) {
      _loseSession();
      return;
    }
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await _adapter.delete(record, verifiedAdmission: admitted);
      if (!_isCurrentSession) return;
      setState(() {
        _deleteReceipt = record;
        _deleteReceiptGeneration++;
        _deleting = false;
      });
      await _refreshAfterDelete();
    } on SessionChanged {
      _loseSession();
    } on OwnedDataRecordsFailure catch (error) {
      if (!mounted) return;
      if (error.status == 401 || !_isCurrentSession) {
        _loseSession();
        return;
      }
      setState(() {
        _deleting = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      if (!_isCurrentSession) {
        _loseSession();
        return;
      }
      setState(() {
        _deleting = false;
        _error = ownedDataDeleteUnavailableMessage;
      });
    }
  }

  Future<void> _refreshAfterDelete() async {
    if (_deleteReceipt == null) return;
    await _readFirstPage();
  }

  void _completeDeletionReadback(
    _RecordsReadResult result, {
    required int receiptGeneration,
  }) {
    final deleted = _deleteReceipt;
    if (deleted == null ||
        receiptGeneration != _deleteReceiptGeneration ||
        !result.applied ||
        !_isCurrentSession ||
        result.revision != _revision ||
        result.kind != deleted.kind ||
        _kind != deleted.kind) {
      return;
    }
    if (_records.any((item) => item.stableKey == deleted.stableKey)) {
      setState(() => _error = '列表仍显示该记录，请重试刷新。');
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != true) return;
    Navigator.pop(
      context,
      OwnedDataDeleteResult(kind: deleted.kind, label: deleted.label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selected;
    final deletionConfirmed = _deleteReceipt != null;
    final Future<void> Function() retry = deletionConfirmed
        ? _refreshAfterDelete
        : _reload;
    final Future<void> Function() refresh = retry;
    final references = <String>{};
    final collisions = <String>{};
    for (final record in _records) {
      if (record.id != null && !references.add(record.shortReference)) {
        collisions.add(record.shortReference);
      }
    }
    String referenceFor(OwnedDataRecord record) =>
        collisions.contains(record.shortReference)
        ? record.id!
        : record.shortReference;

    return Scaffold(
      key: const Key('owned-records-page'),
      appBar: AppBar(title: const Text('我的记录')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              children: [
                SizedBox(
                  height: 3,
                  child: _busy ? const LinearProgressIndicator() : null,
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: refresh,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      children: [
                        Text(
                          '我的  /  隐私与个人数据',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Semantics(
                          header: true,
                          child: Text(
                            '浏览我的记录',
                            style: theme.textTheme.headlineMedium,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text('仅显示定位所需的最小字段；不显示正文、昵称、音频或转写。'),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final kind in OwnedDataKind.values)
                              ChoiceChip(
                                key: Key('records-kind-${kind.wireName}'),
                                label: Text(kind.label),
                                selected: kind == _kind,
                                onSelected:
                                    _busy || _sessionLost || deletionConfirmed
                                    ? null
                                    : (_) => _selectKind(kind),
                              ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '${_kind.label}：${_kind.impact}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (deletionConfirmed)
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              _loading ? '已删除所选记录。正在刷新记录列表…' : '已删除所选记录。',
                            ),
                          ),
                        if (_sessionLost)
                          _SessionLost(onBack: () => Navigator.pop(context))
                        else if (_loading && _records.isEmpty)
                          _LoadingState(kind: _kind)
                        else if (_error != null && _records.isEmpty)
                          _ErrorState(
                            message: _error!,
                            onRetry: retry,
                            retryLabel: deletionConfirmed ? '重试读取' : '重试',
                          )
                        else ...[
                          if (_error case final message?)
                            _InlineError(
                              message: message,
                              onRetry: retry,
                              retryLabel: deletionConfirmed ? '重试读取' : '重试',
                            ),
                          if (deletionConfirmed)
                            const SizedBox.shrink()
                          else if (_records.isEmpty)
                            _EmptyState(kind: _kind)
                          else if (_kind == OwnedDataKind.contacts)
                            OutlinedButton.icon(
                              key: const Key('records-open-contact-book'),
                              onPressed: _busy ? null : _pickContact,
                              icon: const Icon(Icons.people_outline),
                              label: Text(_deleting ? '正在删除…' : '在关系人手记中选择'),
                            )
                          else ...[
                            for (final record in _records)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _RecordCard(
                                  record: record,
                                  reference: referenceFor(record),
                                  selected:
                                      selected?.stableKey == record.stableKey,
                                  enabled: !_busy,
                                  onTap: () => _toggleSelection(record),
                                ),
                              ),
                            if (_nextCursor != null)
                              OutlinedButton.icon(
                                key: const Key('records-load-more'),
                                onPressed: _busy ? null : _loadMore,
                                icon: _loadingMore
                                    ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.expand_more),
                                label: Text(_loadingMore ? '正在加载…' : '加载更多'),
                              )
                            else
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Center(child: Text('已显示全部记录')),
                              ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 160),
                  child: selected == null || _sessionLost
                      ? const SizedBox.shrink()
                      : _SelectionBar(
                          record: selected,
                          reference: referenceFor(selected),
                          deleting: _deleting,
                          onDelete: () => _delete(
                            selected,
                            reference: referenceFor(selected),
                          ),
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

class _RecordCard extends StatelessWidget {
  const _RecordCard({
    required this.record,
    required this.reference,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final OwnedDataRecord record;
  final String reference;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      color: selected ? theme.colorScheme.secondaryContainer : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        key: ValueKey('owned-record-${record.stableKey}'),
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(record.label, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(_recordTime(record)),
                    const SizedBox(height: 2),
                    Text(
                      reference,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                selected ? '已选择' : '选择',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.record,
    required this.reference,
    required this.deleting,
    required this.onDelete,
  });

  final OwnedDataRecord record;
  final String reference;
  final bool deleting;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '已选择：${record.label} · ${_recordTime(record)} · $reference',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('records-delete-selected'),
                onPressed: deleting ? null : onDelete,
                icon: deleting
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_outline),
                label: Text(deleting ? '正在删除…' : '删除所选记录'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.kind});

  final OwnedDataKind kind;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Column(
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 12),
        Text('正在读取${kind.label}记录…'),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.kind});

  final OwnedDataKind kind;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 12),
    child: Column(
      children: [
        Icon(
          Icons.inbox_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 12),
        Text('没有可删除的${kind.label}记录。', textAlign: TextAlign.center),
        if (kind == OwnedDataKind.signalWindows) ...[
          const SizedBox(height: 8),
          const Text('本机录音仍只在语音入口查看和删除。', textAlign: TextAlign.center),
        ],
      ],
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({
    required this.message,
    required this.onRetry,
    this.retryLabel = '重试',
  });

  final String message;
  final Future<void> Function() onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('records-retry'),
            onPressed: onRetry,
            child: Text(retryLabel),
          ),
        ],
      ),
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({
    required this.message,
    required this.onRetry,
    this.retryLabel = '重试',
  });

  final String message;
  final Future<void> Function() onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Card(
      margin: EdgeInsets.zero,
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
            TextButton(
              key: const Key('records-retry'),
              onPressed: onRetry,
              child: Text(retryLabel),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SessionLost extends StatelessWidget {
  const _SessionLost({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    color: Theme.of(context).colorScheme.errorContainer,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ownedDataSessionLostMessage,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onBack, child: const Text('返回隐私页')),
        ],
      ),
    ),
  );
}

String _recordTime(OwnedDataRecord record) {
  final value = record.recordedAt;
  if (value == null) return '无记录时间';
  final local = value.toLocal();
  String two(int part) => part.toString().padLeft(2, '0');
  final wire = record.recordedAtIso!;
  final fraction = wire[19] == '.'
      ? wire.substring(19, wire.indexOf(RegExp(r'[Z+-]'), 20))
      : '';
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}$fraction';
}
