import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/session.dart';
import '../contacts/profile.dart';
import 'account_access.dart';
import 'records_adapter.dart';
import 'store.dart';

/// Keeps the dialog open until the latest shared admission permits deletion.
/// The returned account is the one the adapter must synchronously revalidate
/// immediately before sending DELETE.
Future<PrivacyAccount?> showOwnedDataDeleteConfirmation(
  BuildContext context, {
  required PrivacyStore store,
  required OwnedDataRecord record,
  required String reference,
  String? contactName,
  String? contactId,
}) => showDialog<PrivacyAccount>(
  context: context,
  builder: (_) => _DeleteConfirmation(
    store: store,
    record: record,
    reference: reference,
    contactName: contactName,
    contactId: contactId,
  ),
);

class _DeleteConfirmation extends StatefulWidget {
  const _DeleteConfirmation({
    required this.store,
    required this.record,
    required this.reference,
    this.contactName,
    this.contactId,
  });

  final PrivacyStore store;
  final OwnedDataRecord record;
  final String reference;
  final String? contactName;
  final String? contactId;

  @override
  State<_DeleteConfirmation> createState() => _DeleteConfirmationState();
}

class _DeleteConfirmationState extends State<_DeleteConfirmation> {
  late final AccountAccess _admission = widget.store.admission;
  PrivacyAccount? _checked;
  String? _error;
  late bool _understood;
  bool _checking = true;

  bool get _contactCascade => widget.record.kind == OwnedDataKind.contacts;

  @override
  void initState() {
    super.initState();
    _understood = !_contactCascade;
    // AccountAccess.refresh synchronously notifies its listeners. Starting it
    // from initState would mark surrounding widgets dirty while the dialog is
    // still being mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refreshAdmission();
    });
  }

  Future<void> _refreshAdmission() async {
    if (mounted) {
      setState(() {
        _checking = true;
        _checked = null;
        _error = null;
      });
    }
    try {
      final account = await _admission.refresh();
      _admission.requireOrdinary(account);
      if (!mounted) return;
      setState(() {
        _checked = account;
        _checking = false;
      });
    } on SessionChanged {
      if (!mounted) return;
      setState(() => _checking = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = _admissionMessage(error);
      });
    }
  }

  Future<void> _confirm() async {
    final checked = _checked;
    if (checked == null || _checking || _error != null || !_understood) return;
    setState(() {
      _checking = true;
      _checked = null;
      _error = null;
    });
    try {
      final account = await _admission.refresh();
      _admission.requireOrdinary(account);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      Navigator.pop(context, account);
    } on SessionChanged {
      if (!mounted) return;
      setState(() => _checking = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = _admissionMessage(error);
      });
    }
  }

  String _admissionMessage(Object error) {
    if (_admission.account?.isFrozen == true ||
        error is AccountAdmissionRequired) {
      return '账号当前不可执行删除，且未发送删除请求。请稍后重试核对，或取消。';
    }
    if (error is ApiFailure && error.status == 401) {
      return ownedDataSessionLostMessage;
    }
    return '暂时无法核对账号状态，且未发送删除请求。请重试核对或取消。';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AccountScope?>(
      valueListenable: widget.store.api.sessions.identity,
      builder: (context, active, _) {
        if (!identical(active, widget.store.scope)) {
          return AlertDialog(
            title: const Text(ownedDataSessionLostMessage),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
            ],
          );
        }
        return _buildDialog(context);
      },
    );
  }

  Widget _buildDialog(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(
        _contactCascade ? '删除此关系人及其关联记录？' : '删除这条${widget.record.kind.label}？',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ConfirmationRecord(
            record: widget.record,
            reference: widget.reference,
            contactName: widget.contactName,
            contactId: widget.contactId,
          ),
          const SizedBox(height: 16),
          if (_contactCascade)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '高风险操作：${widget.record.kind.impact}',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            )
          else
            Text(widget.record.kind.impact),
          if (_contactCascade) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
              key: const Key('records-contact-understood'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _understood,
              onChanged: _checking
                  ? null
                  : (value) => setState(() => _understood = value ?? false),
              title: const Text('我已了解会同时删除该关系人的关联对练、复盘、回复、画像证据、标记和情绪事件。'),
            ),
          ],
          if (_contactCascade) ...[
            const SizedBox(height: 8),
            Text(
              '若无法确认，请取消并返回关系人手记，按编号重新选择。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (_checking) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
            const Text('正在核对账号状态…'),
          ] else if (_error case final error?) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                error,
                key: const Key('records-admission-error'),
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
          const SizedBox(height: 12),
          const Text('删除后不可恢复。'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (_error != null)
          OutlinedButton(
            onPressed: _refreshAdmission,
            child: const Text('重试核对'),
          ),
        FilledButton(
          key: const Key('records-confirm-delete'),
          style: _contactCascade
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          onPressed: !_checking && _checked != null && _understood
              ? _confirm
              : null,
          child: Text(
            _checking
                ? '正在核对…'
                : _contactCascade
                ? '仍要删除关系人'
                : '确认删除',
          ),
        ),
      ],
    );
  }
}

class _ConfirmationRecord extends StatelessWidget {
  const _ConfirmationRecord({
    required this.record,
    required this.reference,
    this.contactName,
    this.contactId,
  });

  final OwnedDataRecord record;
  final String reference;
  final String? contactName;
  final String? contactId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(contactName ?? record.label, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          if (contactName == null) Text(_recordTime(record)),
          const SizedBox(height: 2),
          Text(reference),
          if (contactId case final id?) ...[
            const SizedBox(height: 6),
            ContactReference(
              id: id,
              key: const Key('records-confirmation-contact-reference'),
            ),
          ],
        ],
      ),
    );
  }
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
