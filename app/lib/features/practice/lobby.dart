import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/transport.dart';
import '../contacts/models.dart';
import '../contacts/repository.dart';
import '../contacts/routes.dart';
import '../contacts/scene.dart';
import 'chat.dart';
import 'demo.dart';
import 'repository.dart';

final _repository = Provider((ref) {
  final api = ref.watch(apiProvider).requireValue;
  final space = ref.watch(
    contactSpaceProvider,
  ); // invalidated on identity change, including demo history
  return api.transport is ExampleTransport
      ? DemoPractice(contacts: space.repo)
      : ApiPractice(api, api.sessions.active!);
});

class PracticeRoute extends ConsumerWidget {
  const PracticeRoute({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(contactSpaceProvider);
    return PracticeLobby(
      repo: ref.watch(_repository),
      scene: space.scene,
      contacts: space.repo,
      demo: space.demo,
    );
  }
}

class PracticeLobby extends StatefulWidget {
  const PracticeLobby({
    required this.repo,
    required this.scene,
    this.contacts,
    this.demo = false,
    super.key,
  });
  final PracticeRepository repo;
  final SceneMemory scene;
  final ContactsRepository? contacts;
  final bool demo;
  @override
  State<PracticeLobby> createState() => _PracticeLobbyState();
}

class _PracticeLobbyState extends State<PracticeLobby> {
  // Launch parameters live in the authorized session detail response. The
  // lobby keeps no account-journal copy of custom text or a contact id.
  int? difficulty;
  final scenario = TextEditingController();
  final scroll = ScrollController();
  late Future<List<Json>> levels, history;
  late Future<Json?> pending;
  String? error;
  Contact? person;
  bool busy = false, quota = false;
  @override
  void initState() {
    super.initState();
    refresh();
    widget.scene.addListener(filter);
  }

  @override
  void dispose() {
    widget.scene.removeListener(filter);
    scenario.dispose();
    scroll.dispose();
    super.dispose();
  }

  void refresh() {
    levels = widget.repo.levels(widget.scene.value, difficulty)..ignore();
    // Lazy ListView children may attach their FutureBuilder after an error.
    history = widget.repo.history()..ignore();
    pending = widget.repo.read('creating')..ignore();
  }

  void filter() {
    setState(() {
      person = null;
      levels = widget.repo.levels(widget.scene.value, difficulty)..ignore();
    });
  }

  Future<void> run(Future<void> Function() f) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      quota = false;
    });
    try {
      await f();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = problem(e);
          quota = e is ApiFailure && e.status == 429;
          pending = widget.repo.read('creating')..ignore();
        });
        FocusManager.instance.primaryFocus?.unfocus();
        if (scroll.hasClients) scroll.jumpTo(0);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> choose() async {
    final book = await widget.contacts!.load();
    if (!mounted) return;
    final people = book.people.where(
      (p) => book.usable(p) && p.scene == widget.scene.value,
    );
    final id = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('不指定关系人'),
              onTap: () => Navigator.pop(context, ''),
            ),
            if (people.isEmpty)
              const ListTile(subtitle: Text('这个场景没有可用于练习的关系人。')),
            for (final p in people)
              ListTile(
                title: Text(p.name),
                onTap: () => Navigator.pop(context, p.id),
              ),
          ],
        ),
      ),
    );
    if (mounted && id != null) {
      setState(() => person = people.where((p) => p.id == id).firstOrNull);
    }
  }

  Future<void> start(Json input) async {
    final existing = await widget.repo.read('creating');
    if (existing != null) {
      throw const ApiFailure(409, 'conflict', '请先恢复或放弃上次创建请求。', false);
    }
    await create({
      'input': {...input, 'request_id': newRequestId()},
    });
  }

  // Every creation path, including replay and repeat, must re-read the T05
  // purpose grant. A local notice or an old draft is not consent.
  Future<bool> ensurePracticeConsent() async {
    if (widget.demo) return true;
    final granted = await widget.repo.practiceConsent();
    if (!mounted) return false;
    if (granted) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开始前，先了解记录方式'),
        content: const Text(
          '对话和评分反馈可能含有你或他人的信息。内容会加密保存，直到删除这场练习、相关关系人或注销账号。请不要填写真实姓名等不必要的信息。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('暂不开始'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('了解，继续练习'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return false;
    await widget.repo.grantPracticeConsent();
    final confirmed = await widget.repo.practiceConsent();
    if (!mounted) return false;
    if (!confirmed) {
      throw const ApiFailure(403, 'forbidden', '练习授权未生效，请重试。', true);
    }
    return true;
  }

  Future<void> create(Json intent) async {
    if (!await ensurePracticeConsent()) return;
    final input = intent['input'] as Json;
    final body = {
      ...input,
      if (intent['previous_id'] != null) 'previous_id': intent['previous_id'],
    };
    // Fail closed for deleted / newly read-only contacts (also on replay).
    if (body['contact_id'] != null) {
      final book = await widget.contacts!.load();
      if (!book.people.any(
        (p) => p.id == body['contact_id'] && book.usable(p),
      )) {
        throw const ApiFailure(403, 'forbidden', '关系人已不可用，请重新选择。', false);
      }
    }
    await widget.repo.remember('creating', intent);
    final s = await widget.repo.create(body);
    if (s['session_id'] != body['request_id']) throw const FormatException();
    await widget.repo.remember('creating', null);
    if (!mounted) return;
    await open(s, input, priorId: intent['previous_id']);
  }

  Future<void> open(Json s, Json? seed, {String? priorId}) async {
    final id = s['session_id'];
    Json? original;
    if (seed == null) {
      try {
        final detail = await widget.repo.get(id);
        if (detail['session_id'] != id) throw const FormatException();
        s = detail;
        original = detail['setup'] as Json?;
      } catch (_) {
        // Missing detail must not block read-only recovery from list history.
      }
    }
    if (original != null) {
      // GET returns a flat CreateSessionInput, not the old local journal envelope.
      seed = {
        for (final key in ['level_id', 'contact_id', 'scene', 'scenario'])
          if (original[key] is String) key: original[key],
      };
    }
    final level = s['level_id'] ?? seed?['level_id'];
    priorId ??= original?['previous_id'];
    Json? previous;
    bool compareUnavailable = false;
    try {
      if (priorId != null) {
        previous = (await widget.repo.get(priorId))['result'];
      } else if (level != null) {
        final list = await history;
        final index = list.indexWhere((r) => r['session_id'] == id);
        previous = list
            .skip(index + 1)
            .where(
              (r) =>
                  r['level_id'] == level &&
                  r['mode'] == s['mode'] &&
                  r['status'] == 'complete',
            )
            .firstOrNull?['result'];
      }
    } catch (_) {
      compareUnavailable = true;
    } // Missing comparison must not prevent recovery.
    if (!mounted) return;
    final repeat = await Navigator.push<Json>(
      context,
      MaterialPageRoute(
        builder: (_) => PracticeChat(
          repo: widget.repo,
          initial: s,
          seed: seed,
          previous: previous,
          previousId: priorId,
          compareUnavailable: compareUnavailable,
        ),
      ),
    );
    if (!mounted) return;
    final input = repeat?['input'];
    if (input is Json) {
      await create({
        'input': {...input, 'request_id': newRequestId()},
        'previous_id': id,
      });
    } else {
      setState(refresh);
    }
  }

  Widget items(
    Future<List<Json>> f,
    String empty,
    Widget Function(Json) tile,
  ) => FutureBuilder<List<Json>>(
    future: f,
    builder: (context, s) {
      if (s.connectionState != ConnectionState.done) {
        return const LinearProgressIndicator();
      }
      if (s.hasError) {
        return TextButton(
          onPressed: () => setState(refresh),
          child: const Text('读取失败，重新加载'),
        );
      }
      final rows = s.requireData;
      return rows.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(empty),
            )
          : Column(children: rows.map(tile).toList());
    },
  );
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('对练与预演')),
      body: SafeArea(
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            if (widget.demo) const Text('离线演示 · 示例反馈不会计入真实额度'),
            if (busy) Semantics(liveRegion: true, child: const Text('正在处理…')),
            if (error != null) Text(error!, semanticsLabel: error),
            if (quota)
              TextButton(
                onPressed: () => Navigator.pushNamed(context, '/membership'),
                child: const Text('查看额度与重置时间'),
              ),
            FutureBuilder<Json?>(
              future: pending,
              builder: (context, s) {
                if (s.hasError) {
                  return TextButton(
                    onPressed: () => setState(refresh),
                    child: const Text('本机续练记录读取失败，重试'),
                  );
                }
                if (s.data == null) return const SizedBox.shrink();
                return Wrap(
                  children: [
                    FilledButton(
                      onPressed: busy ? null : () => run(() => create(s.data!)),
                      child: const Text('恢复上次创建'),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => run(() async {
                              await widget.repo.remember('creating', null);
                              if (mounted) setState(refresh);
                            }),
                      child: const Text('放弃创建请求'),
                    ),
                  ],
                );
              },
            ),
            Text('选一个练习场景', style: theme.titleLarge),
            GlobalScenePicker(widget.scene),
            if (widget.contacts != null)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(person?.name ?? '不指定关系人'),
                subtitle: const Text('可选 · 只显示可用于当前场景的人'),
                trailing: const Icon(Icons.unfold_more),
                onTap: busy ? null : () => run(choose),
              ),
            const Divider(height: 28),
            Text('关卡练习', style: theme.titleLarge),
            Wrap(
              spacing: 8,
              children: [
                for (final d in <int?>[null, 1, 2, 3])
                  ChoiceChip(
                    label: Text(d == null ? '全部难度' : '难度 $d'),
                    selected: difficulty == d,
                    onSelected: busy
                        ? null
                        : (_) {
                            setState(() {
                              difficulty = d;
                              levels = widget.repo.levels(
                                widget.scene.value,
                                difficulty,
                              )..ignore();
                            });
                          },
                  ),
              ],
            ),
            items(
              levels,
              '这个条件下还没有关卡，试试其他难度。',
              (l) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l['title']),
                subtitle: Text(
                  '难度 ${l['difficulty']} · ${skills[l['target_item']] ?? '整场表达'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: busy
                    ? null
                    : () => run(
                        () => start({
                          'level_id': l['id'],
                          if (person != null) 'contact_id': person!.id,
                        }),
                      ),
              ),
            ),
            const Divider(height: 28),
            Text('预演自己的情境', style: theme.titleLarge),
            TextField(
              controller: scenario,
              minLines: 1,
              maxLines: 3,
              enabled: !busy,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: '你想和对方谈什么？'),
            ),
            FilledButton(
              onPressed: busy || scenario.text.trim().isEmpty
                  ? null
                  : () => run(
                      () => start({
                        'scenario': scenario.text.trim(),
                        'scene': widget.scene.value.name,
                        if (person != null) 'contact_id': person!.id,
                      }),
                    ),
              child: const Text('开始预演'),
            ),
            const Divider(height: 28),
            Text('最近的练习', style: theme.titleLarge),
            items(history, '还没有练习记录。', (s) {
              final rows = s['messages'] as List;
              final title = rows
                  .where((m) => m['role'] == 'user')
                  .firstOrNull?['text'];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  title ?? '尚未发言的练习',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(switch (s['status']) {
                  'complete' => '查看结算',
                  'failed' => '查看退次结果',
                  'exited' => '已主动退出',
                  'safety' => '已停止练习',
                  'moderation_unavailable' => '审核暂不可用',
                  _ => '继续本场',
                }),
                onTap: busy ? null : () => run(() => open(s, null)),
              );
            }),
          ],
        ),
      ),
    );
  }
}
