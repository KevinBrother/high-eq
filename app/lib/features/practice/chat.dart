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
    this.seed,
    this.compareUnavailable = false,
    super.key,
  });
  final PracticeRepository repo;
  final Json initial;
  final bool compareUnavailable;
  final Json? previous, seed;
  @override
  State<PracticeChat> createState() => _PracticeChatState();
}

class _PracticeChatState extends State<PracticeChat> {
  late final c = Conversation(widget.repo, widget.initial);
  final input = TextEditingController();
  @override
  void initState() {
    super.initState();
    c.recover();
  }

  @override
  void dispose() {
    c.dispose();
    input.dispose();
    super.dispose();
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
      final ready = c.active && !c.busy && !c.needsRead && c.command == null;
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
                onPressed: !c.busy || c.streaming ? confirmExit : null,
                child: const Text('主动退出'),
              ),
          ],
        ),
        body: SafeArea(
          child: done
              ? PracticeResult(
                  c.snapshot,
                  previous: widget.previous,
                  compareUnavailable: widget.compareUnavailable,
                  repeat: widget.seed == null
                      ? null
                      : () => Navigator.pop(context, c.snapshot['result']),
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
                                  widget.seed?['scenario'] ?? '试着说出你的第一句话。',
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
                              if (c.notice.isNotEmpty &&
                                  c.status != 'safety' &&
                                  c.status != 'moderation_unavailable')
                                _BannerText(c.notice),
                              if (!c.busy && (c.needsRead || !c.ledgerKnown))
                                OutlinedButton(
                                  onPressed: c.recover,
                                  child: const Text('恢复会话'),
                                ),
                              if (!c.busy &&
                                  !c.needsRead &&
                                  c.command != null &&
                                  (c.active ||
                                      c.status == 'moderation_unavailable'))
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
                                        enabled: ready,
                                        minLines: 1,
                                        maxLines: 3,
                                        decoration: const InputDecoration(
                                          labelText: '你的发言',
                                        ),
                                      ),
                                    ),
                                    IconButton.filled(
                                      tooltip: '发送',
                                      onPressed: !ready
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
                              if (ready &&
                                  c.rows.any((m) => m['role'] == 'assistant'))
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
