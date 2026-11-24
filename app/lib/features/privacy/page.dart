import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/session.dart';
import '../onboarding/surface.dart';
import 'account_access.dart';
import 'export_card.dart';
import 'export_delivery.dart';
import 'export_flow.dart';
import 'store.dart';

class PrivacyPage extends StatefulWidget {
  const PrivacyPage(
    this.store, {
    super.key,
    required this.onClosureSubmitted,
    required this.onClosureUnconfirmed,
    required this.onClosureCancelled,
    required this.onExit,
    this.refreshOnEntry = true,
  });

  final PrivacyStore store;
  final ValueChanged<ClosureSubmission> onClosureSubmitted;
  final ValueChanged<bool> onClosureUnconfirmed;
  final VoidCallback onClosureCancelled;
  final VoidCallback onExit;
  final bool refreshOnEntry;

  @override
  State<PrivacyPage> createState() => _PrivacyPageState();
}

class _PrivacyPageState extends State<PrivacyPage> {
  final _timezone = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  String? _provider;
  String? _issuedTo;
  String? _error;
  String? _message;
  bool _showReadRetry = false;
  bool _busy = false;
  bool _ready = false;
  bool _departed = false;
  PrivacyExportPhase? _exportPhase;
  late final PrivacyExportFlow _exportFlow;

  AccountAccess get _admission => widget.store.admission;
  bool get _current =>
      mounted &&
      !_departed &&
      identical(widget.store.api.sessions.active, widget.store.scope);

  @override
  void initState() {
    super.initState();
    _exportFlow = PrivacyExportFlow(widget.store.api, widget.store.scope);
    scheduleMicrotask(() {
      if (!_current) return;
      unawaited(_run(() => _read(refresh: widget.refreshOnEntry)));
    });
  }

  @override
  void dispose() {
    _exportFlow.dispose();
    _timezone.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
      _showReadRetry = false;
    });
    try {
      await action();
    } on SessionChanged {
      // The account navigator is being replaced.
    } catch (error) {
      if (_current) {
        setState(() {
          _showReadRetry = true;
          _error = error is PrivacyFailure
              ? error.message
              : friendlyError(error);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _export() => _run(() async {
    try {
      await _exportFlow.run((phase) {
        if (_current) setState(() => _exportPhase = phase);
      });
      if (_current) setState(() => _message = '系统已完成保存或分享。');
    } on PrivacyExportDeliveryFailure catch (error) {
      if (_current) {
        setState(() {
          if (error.deliveryCode == 'cancelled') {
            _message = error.message;
          } else {
            _error = error.message;
          }
        });
      }
    } catch (error) {
      if (_current) setState(() => _error = friendlyError(error));
    } finally {
      if (_current) setState(() => _exportPhase = null);
    }
  });

  Future<void> _read({bool refresh = true}) async {
    final recovering = _admission.frozenUntil != null;
    final account = await (refresh
        ? _admission.refresh()
        : _admission.ensure());
    if (!_current) return;
    _showAccount(account);
    widget.onClosureUnconfirmed(false);
    if (recovering && !account.isFrozen) widget.onClosureCancelled();
  }

  void _showAccount(PrivacyAccount account) {
    setState(() {
      _ready = true;
      _timezone.text = account.timezone;
      if (!account.bindings.contains(_provider)) _provider = null;
    });
  }

  Future<void> _saveTimezone() => _run(() async {
    final account = await widget.store.updateTimezone(_timezone.text);
    if (!_current) return;
    _showAccount(account);
    setState(() => _message = '时区已更正');
  });

  Future<void> _requestCode() => _run(() async {
    final phone = widget.store.normalizePhone(_phone.text);
    await widget.store.requestPhoneCode(phone);
    if (!_current) return;
    setState(() {
      _issuedTo = phone;
      _message = '验证码已发送，请填写收到的六位数字。';
    });
  });

  Future<void> _requestClosure() async {
    final provider = _provider;
    if (provider == null || !_canEdit) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('申请注销账号？'),
        content: const Text(
          '$privacyAppleSubscriptionReminder。'
          '申请后账号进入 15 天冷静期，所有设备会退出。'
          '在期限内可重新登录后撤销。期满后不可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不注销'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('申请注销'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_current || !_canEdit) return;

    await _run(() async {
      final onSubmitted = widget.onClosureSubmitted;
      final onUnconfirmed = widget.onClosureUnconfirmed;
      final store = widget.store;
      try {
        final proof = provider == 'phone'
            ? store.phoneCredential(phone: _phone.text, code: _code.text)
            : await store.platformCredential(provider);
        try {
          onSubmitted(await store.freezeAccount(proof: proof));
        } on ClosureUnconfirmed {
          onUnconfirmed(true);
          await _checkUnconfirmedClosure();
        }
      } finally {
        if (_current && provider == 'phone') {
          setState(() {
            _code.clear();
            _issuedTo = null;
          });
        }
      }
    });
  }

  Future<Never> _checkUnconfirmedClosure() async {
    if (_current) {
      try {
        await _read();
      } catch (_) {
        // Keep the admission closed if the state still cannot be read.
      }
    }
    throw const PrivacyFailure('未收到注销确认。请核对账号状态，必要时重新登录。');
  }

  Future<void> _cancelClosure() => _run(() async {
    await widget.store.cancelClosure();
    await _read();
    if (_current && _admission.frozenUntil != null) {
      throw const PrivacyFailure('撤销结果未确认，请重试读取账号状态。');
    }
  });

  bool get _canEdit => _ready && !_busy && _admission.isOrdinary;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _admission,
    builder: (context, _) {
      final account = _admission.account;
      final deadline = _admission.frozenUntil;
      return PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) return;
          _departed = true;
          _exportFlow.dispose();
        },
        child: Scaffold(
          appBar: AppBar(title: const Text('隐私与个人数据')),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  children: [
                    if (_busy) const LinearProgressIndicator(),
                    if (_error != null || _message != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            (_error ?? _message)!,
                            style: TextStyle(
                              color: _error == null
                                  ? null
                                  : Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                        children: [
                          if (deadline != null) ...[
                            _ClosureCard(
                              deadline: deadline,
                              onCancel: _busy ? null : _cancelClosure,
                            ),
                            const SizedBox(height: 12),
                            TextButton(
                              onPressed: _busy ? null : widget.onExit,
                              child: const Text('退出账号'),
                            ),
                          ] else if (_ready && account != null) ...[
                            _AccountCard(
                              account: account,
                              timezone: _timezone,
                              onSave: _canEdit ? _saveTimezone : null,
                            ),
                            const SizedBox(height: 24),
                            PrivacyExportCard(
                              phase: _exportPhase,
                              onExport: _canEdit ? _export : null,
                              onCancel: switch (_exportPhase) {
                                PrivacyExportPhase.preparing ||
                                PrivacyExportPhase.downloading =>
                                  _exportFlow.cancel,
                                _ => null,
                              },
                            ),
                            const SizedBox(height: 24),
                            _closureForm(context, account.bindings),
                          ] else if (_error == null)
                            const Text('正在确认账号状态…'),
                          if (_showReadRetry && !_busy)
                            TextButton(
                              key: const Key('privacy-retry'),
                              onPressed: () => _run(_read),
                              child: const Text('重试读取账号状态'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _closureForm(BuildContext context, List<String> bindings) {
    final providers = bindings.where(_providerLabels.containsKey).toList();
    final phoneCanSubmit = _issuedTo != null && _issuedTo == _phone.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('注销与冷静期', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(privacyAppleSubscriptionReminder),
        const SizedBox(height: 12),
        _ProviderSelect(
          keyName: 'privacy-closure-provider',
          label: '注销前重新认证方式',
          hint: '选择当前绑定方式',
          value: providers.contains(_provider) ? _provider : null,
          providers: providers,
          enabled: _canEdit,
          onChanged: (value) => setState(() {
            _provider = value;
            _issuedTo = null;
            _code.clear();
          }),
        ),
        if (_provider == 'phone') ...[
          const SizedBox(height: 12),
          TextField(
            key: const Key('privacy-phone'),
            controller: _phone,
            enabled: _canEdit,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: '带国家区号的手机号'),
            onChanged: (_) => setState(() {
              _issuedTo = null;
              _code.clear();
            }),
          ),
          TextButton(
            key: const Key('privacy-phone-code-request'),
            onPressed: _canEdit ? _requestCode : null,
            child: const Text('获取验证码'),
          ),
          TextField(
            key: const Key('privacy-phone-code'),
            controller: _code,
            enabled: _canEdit && phoneCanSubmit,
            keyboardType: TextInputType.number,
            autofillHints: const [AutofillHints.oneTimeCode],
            decoration: const InputDecoration(labelText: '六位验证码'),
          ),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('privacy-freeze'),
          onPressed:
              _canEdit &&
                  _provider != null &&
                  (_provider != 'phone' || phoneCanSubmit)
              ? _requestClosure
              : null,
          icon: const Icon(Icons.lock_clock_outlined),
          label: const Text('申请注销（15 天冷静期）'),
        ),
      ],
    );
  }
}

const _providerLabels = {'apple': 'Apple', 'wechat': '微信', 'phone': '手机号'};

class _ProviderSelect extends StatelessWidget {
  const _ProviderSelect({
    required this.keyName,
    required this.label,
    required this.hint,
    required this.value,
    required this.providers,
    required this.enabled,
    required this.onChanged,
  });

  final String keyName;
  final String label;
  final String hint;
  final String? value;
  final List<String> providers;
  final bool enabled;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: Key(keyName),
        value: value,
        hint: Text(hint),
        isExpanded: true,
        items: [
          for (final provider in providers)
            DropdownMenuItem(
              value: provider,
              child: Text(_providerLabels[provider]!),
            ),
        ],
        onChanged: enabled ? onChanged : null,
      ),
    ),
  );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.timezone,
    required this.onSave,
  });

  final PrivacyAccount account;
  final TextEditingController timezone;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '账号 ${account.userId}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '已绑定方式：${account.bindings.map((value) => _providerLabels[value] ?? value).join('、')}',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('privacy-timezone'),
            controller: timezone,
            enabled: onSave != null,
            decoration: const InputDecoration(
              labelText: '时区',
              helperText: '例如 Asia/Shanghai',
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onSave, child: const Text('保存时区更正')),
        ],
      ),
    ),
  );
}

class _ClosureCard extends StatelessWidget {
  const _ClosureCard({required this.deadline, required this.onCancel});

  final DateTime deadline;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final local = deadline.toLocal();
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '注销冷静期 · 15 天',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '预计处理时间：${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}',
            ),
            const SizedBox(height: 12),
            const Text('重新登录不会自动撤销。请在期限内主动撤销以恢复账号。'),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('privacy-cancel-closure'),
              onPressed: onCancel,
              child: const Text('撤销注销申请'),
            ),
          ],
        ),
      ),
    );
  }
}
