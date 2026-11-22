import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/transport.dart';
import 'conversation.dart';
import 'repository.dart';
import 'result.dart';

class PracticeChat extends StatefulWidget {
  const PracticeChat({
    required this.repo,
    required this.initial,
    this.previous,
    this.previousId,
    this.seed,
    this.compareUnavailable = false,
    super.key,
  });
  final PracticeRepository repo;
  final Json initial;
  final bool compareUnavailable;
  final Json? previous, seed;
  final String? previousId;
  @override
  State<PracticeChat> createState() => _PracticeChatState();
}

class _PracticeChatState extends State<PracticeChat> {
  late Conversation c;
  final input = TextEditingController();
  Json? seed, previous;
  String? explicitPrior;
  bool compareUnavailable = false;
  int lifecycleEpoch = 0, contextEpoch = 0;

  @override
  void initState() {
    super.initState();
    _resetConversation();
    unawaited(_recover());
  }

  @override
  void didUpdateWidget(PracticeChat oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.repo, widget.repo) ||
        oldWidget.initial['session_id'] != widget.initial['session_id']) {
      final old = c;
      input.clear();
      _resetConversation();
      old.dispose();
      unawaited(_recover());
    }
  }

  @override
  void dispose() {
    lifecycleEpoch++;
    contextEpoch++;
    c.dispose();
    input.dispose();
    super.dispose();
  }

  void _resetConversation() {
    lifecycleEpoch++;
    contextEpoch++;
    c = Conversation(widget.repo, widget.initial);
    seed = widget.seed?.isEmpty == true ? null : widget.seed;
    previous = widget.previous;
    explicitPrior = widget.previousId;
    compareUnavailable = widget.compareUnavailable;
  }

  bool _stillCurrent(int lifecycle, int context) =>
      mounted &&
      lifecycle == lifecycleEpoch &&
      context == contextEpoch &&
      c.id == widget.initial['session_id'];

  Future<void> _recover() async {
    final conversation = c;
    final lifecycle = lifecycleEpoch;
    await conversation.recover();
    if (!mounted ||
        lifecycle != lifecycleEpoch ||
        !identical(conversation, c) ||
        !conversation.ledgerKnown) {
      return;
    }
    await _restoreContext(conversation, lifecycle);
  }

  Future<void> _restoreContext(Conversation conversation, int lifecycle) async {
    final setup = conversation.snapshot['setup'];
    if (setup is! Json) return;

    final context = ++contextEpoch;
    final restoredSeed = <String, dynamic>{
      for (final key in ['level_id', 'contact_id', 'scene', 'scenario'])
        if (setup[key] is String) key: setup[key],
    };
    final nextSeed = restoredSeed.isEmpty ? null : restoredSeed;
    final prior = setup['previous_id'];
    final same = prior is String && prior == explicitPrior;
    setState(() {
      seed = nextSeed;
      // Explicit chains are owner-validated by the detail endpoint. Discard a
      // score when that particular predecessor is no longer linked; preserve
      // a level-history comparison when there never was an explicit chain.
      if (!same && (prior is String || explicitPrior != null)) {
        previous = null;
        compareUnavailable = false;
      }
      explicitPrior = prior is String ? prior : null;
    });
    if (prior is! String || (same && previous != null)) return;
    try {
      final detail = await widget.repo.get(prior);
      if (detail['session_id'] != prior || detail['result'] is! Json) {
        throw const FormatException();
      }
      if (!_stillCurrent(lifecycle, context)) return;
      setState(() {
        previous = detail['result'] as Json;
        compareUnavailable = false;
      });
    } catch (_) {
      if (!_stillCurrent(lifecycle, context)) return;
      setState(() {
        compareUnavailable = true;
      });
    }
  }

  Future<void> confirmExit() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束并退出，不评分？'),
        content: const Text('仅想稍后继续，请返回练习列表。主动退出后将按已保存的回复结算。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续练习'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认退出'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) await c.exit();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final done = c.status == 'complete' && c.snapshot['result'] != null;
      final send = c.command?['body'];
      final bubbles = <Widget>[
        for (final m in c.rows) _Bubble(m['text'], user: m['role'] == 'user'),
        if (send != null &&
            c.active &&
            !c.rows.any(
              (m) => m['client_message_id'] == send['client_message_id'],
            ))
          _Bubble(send['text'], user: true),
        if (c.fragment.isNotEmpty) _Bubble(c.fragment, user: false),
      ];
      return Scaffold(
        appBar: AppBar(
          title: Text(
            done
                ? '练习回顾'
                : c.snapshot['mode'] == 'single_skill'
                ? '${skills[c.snapshot['target_item']]}练习'
                : '情景预演',
          ),
          actions: [
            if (c.active)
              TextButton(
                onPressed: c.canExit ? confirmExit : null,
                child: const Text('主动退出'),
              ),
          ],
        ),
        body: SafeArea(
          child: done
              ? PracticeResult(
                  c.snapshot,
                  previous: previous,
                  compareUnavailable: compareUnavailable,
                  repeat: seed == null
                      ? null
                      : () => Navigator.pop(context, {'input': seed}),
                )
              : LayoutBuilder(
                  builder: (context, bounds) => Column(
                    children: [
                      Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            settlementLabel(
                              c.ledgerKnown ? c.snapshot['settlement'] : null,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: bubbles.isEmpty
                            ? Center(
                                child: Text(
                                  seed?['scenario'] ?? '试着说出你的第一句话。',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView(
                                reverse: true,
                                padding: const EdgeInsets.all(16),
                                children: bubbles.reversed.toList(),
                              ),
                      ),
                      if (c.busy) const LinearProgressIndicator(),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: bounds.maxHeight * .6,
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (c.status == 'safety')
                                const _BannerText(safetyHelp)
                              else if (c.status == 'moderation_unavailable')
                                const _BannerText(moderationHelp)
                              else if (c.status == 'failed')
                                const _BannerText('本场未取得评分。')
                              else if (c.status == 'exited')
                                const _BannerText('本场已主动退出。'),
                              if (c.status == 'capped')
                                _BannerText(
                                  c.hasSavedReply
                                      ? '本场已达长度上限，已保留完整对话，可以结束并评分。'
                                      : '本场已达长度上限，没有可评分内容。',
                                ),
                              if (c.notice.isNotEmpty &&
                                  c.status != 'safety' &&
                                  c.status != 'moderation_unavailable')
                                _BannerText(c.notice),
                              if (c.canRecover)
                                OutlinedButton(
                                  onPressed: _recover,
                                  child: const Text('恢复会话'),
                                ),
                              if (c.canRetry)
                                OutlinedButton(
                                  onPressed: c.retry,
                                  child: Text(switch (c.command!['kind']) {
                                    'send' => '重试原发言',
                                    'finish' => '重试原评分',
                                    _ => '重试原退出',
                                  }),
                                ),
                              if (c.active && c.command == null)
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: input,
                                        enabled: c.canSend,
                                        minLines: 1,
                                        maxLines: 3,
                                        decoration: const InputDecoration(
                                          labelText: '你的发言',
                                        ),
                                      ),
                                    ),
                                    IconButton.filled(
                                      tooltip: '发送',
                                      onPressed: !c.canSend
                                          ? null
                                          : () {
                                              final text = input.text.trim();
                                              if (text.isEmpty) return;
                                              input.clear();
                                              c.send(text);
                                            },
                                      icon: const Icon(Icons.arrow_upward),
                                    ),
                                  ],
                                ),
                              if (c.canScore)
                                TextButton(
                                  onPressed: c.finish,
                                  child: const Text('结束并评分'),
                                ),
                              if (c.notice.startsWith('今日对练剩余'))
                                TextButton(
                                  onPressed: () => Navigator.pushNamed(
                                    context,
                                    '/membership',
                                  ),
                                  child: const Text('查看额度与重置时间'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      );
    },
  );
}

class _BannerText extends StatelessWidget {
  const _BannerText(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(padding: const EdgeInsets.all(8), child: Text(label)),
  );
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.text, {required this.user});
  final String text;
  final bool user;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        margin: EdgeInsets.only(
          left: user ? 32 : 0,
          right: user ? 0 : 32,
          bottom: 10,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: user ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              user ? '我' : '对练伙伴',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            Text(text),
          ],
        ),
      ),
    );
  }
}
