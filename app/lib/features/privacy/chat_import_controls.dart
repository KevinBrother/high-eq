import 'package:flutter/material.dart';

import '../../core/app_op.g.dart';
import '../../core/chat_import_consent.dart';
import '../../core/session.dart';
import 'store.dart';

class ChatImportControls extends StatefulWidget {
  const ChatImportControls({
    super.key,
    required this.store,
    required this.enabled,
  });

  final PrivacyStore store;
  final bool enabled;

  @override
  State<ChatImportControls> createState() => _ChatImportControlsState();
}

class _ChatImportControlsState extends State<ChatImportControls> {
  Map<ChatImportConsent, String>? _grants;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _run(_read);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on SessionChanged {
      // The account navigator removes this page.
    } catch (_) {
      if (mounted) {
        setState(() {
          _grants = null;
          _message = '未能确认聊天导入授权状态，请重试读取。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read() async {
    final admission = widget.store.admission;
    final account = admission.requireOrdinary();
    final grants = <ChatImportConsent, String>{};
    final seen = <String>{};
    String? cursor;
    do {
      final page = await admission.ordinaryJson(
        AppOp.listConsents,
        account,
        query: {'cursor': ?cursor},
      );
      for (final row in page['items'] as List) {
        for (final purpose in ChatImportConsent.values) {
          if (row['purpose'] == purpose.purpose && row['granted'] == true) {
            final version = row['version'] as String;
            grants[purpose] = version;
          }
        }
      }
      cursor = page['next_cursor'] as String?;
      if (cursor != null && !seen.add(cursor)) throw const FormatException();
    } while (cursor != null);
    admission.requireOrdinary(account);
    if (mounted) setState(() => _grants = grants);
  }

  Future<void> _withdraw(ChatImportConsent purpose, String version) =>
      _run(() async {
        final admission = widget.store.admission;
        final account = admission.requireOrdinary();
        final receipt = await admission.ordinaryJson(
          AppOp.setConsent,
          account,
          path: {'purpose': purpose.purpose},
          body: {'version': version, 'granted': false},
        );
        if (receipt['purpose'] != purpose.purpose ||
            receipt['version'] != version ||
            receipt['granted'] != false) {
          throw const FormatException();
        }
        await _read();
        if (mounted && _grants?[purpose] == null) {
          setState(() => _message = '已撤回${_label(purpose)}授权。');
        }
      });

  Future<void> _open(ChatImportConsent purpose) async {
    await Navigator.pushNamed(context, switch (purpose) {
      ChatImportConsent.reply => '/replies',
      ChatImportConsent.contact => '/contacts',
    });
    if (mounted) await _run(_read);
  }

  String _label(ChatImportConsent purpose) => switch (purpose) {
    ChatImportConsent.reply => '回复助手聊天分析',
    ChatImportConsent.contact => '关系人聊天导入',
  };

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('聊天导入授权', style: Theme.of(context).textTheme.titleLarge),
        if (_busy) const LinearProgressIndicator(),
        if (_message case final message?)
          Semantics(liveRegion: true, child: Text(message)),
        if (_grants case final grants?)
          for (final purpose in ChatImportConsent.values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_label(purpose)),
              subtitle: Text(switch (grants[purpose]) {
                null => '当前未授权',
                final version when version != purpose.version => '旧版授权',
                _ => '已授权',
              }),
              trailing: switch (grants[purpose]) {
                final version? => TextButton(
                  key: ValueKey('withdraw-${purpose.purpose}'),
                  onPressed: enabled ? () => _withdraw(purpose, version) : null,
                  child: const Text('撤回'),
                ),
                null => TextButton(
                  onPressed: enabled ? () => _open(purpose) : null,
                  child: const Text('前往入口'),
                ),
              },
            )
        else if (!_busy)
          TextButton(
            onPressed: enabled ? () => _run(_read) : null,
            child: const Text('重试读取授权'),
          ),
      ],
    );
  }
}
