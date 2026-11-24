import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/transport.dart';
import '../contacts/models.dart';
import '../contacts/repository.dart';
import '../contacts/routes.dart';
import '../contacts/scene.dart';
import '../home/shell.dart';
import 'chat.dart';
import 'providers.dart';
import 'repository.dart';

class PracticeRoute extends ConsumerWidget {
  const PracticeRoute({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(contactSpaceProvider);
    final argument = ModalRoute.of(context)?.settings.arguments;
    final repository = ref.watch(practiceRepositoryProvider);
    if (repository == null) {
      return const HomeShell(
        Section.practice,
        content: SessionTransitionPane(label: '正在重新载入练习空间…'),
      );
    }
    return PracticeLobby(
      key: ValueKey((repository, argument is String ? argument : null)),
      repo: repository,
      scene: space.scene,
      contacts: space.repo,
      demo: space.demo,
      targetLevelId: argument is String ? argument : null,
    );
  }
}

class PracticeLobby extends StatefulWidget {
  const PracticeLobby({
    required this.repo,
    required this.scene,
    this.contacts,
    this.demo = false,
    this.targetLevelId,
    super.key,
  });
  final PracticeRepository repo;
  final SceneMemory scene;
  final ContactsRepository? contacts;
  final bool demo;
  final String? targetLevelId;
  @override
  State<PracticeLobby> createState() => _PracticeLobbyState();
}

enum _PendingPhase { reading, ready, readFailed, abandoning, abandonFailed }

enum _PendingPlan { none, openAfterRead, conflict }

class _PendingCreation {
  const _PendingCreation(
    this.phase, {
    this.intent,
    this.plan = _PendingPlan.none,
  });

  final _PendingPhase phase;
  final Json? intent;
  final _PendingPlan plan;
}

class _PracticeLobbyState extends State<PracticeLobby> {
  // Launch parameters live in the authorized session detail response. The
  // lobby keeps no account-journal copy of custom text or a contact id.
  int? difficulty;
  final scenario = TextEditingController();
  final scroll = ScrollController();
  late Future<List<Json>> levels, history;
  var _pending = const _PendingCreation(_PendingPhase.reading);
  String? error;
  Contact? person;
  bool _operationInFlight = false, quota = false;
  bool get busy =>
      _operationInFlight || _pending.phase == _PendingPhase.abandoning;
  bool get _canStart =>
      _pending.phase == _PendingPhase.ready &&
      _pending.plan != _PendingPlan.conflict;
  String? _targetLevelId;
  bool _targetHandled = false,
      _targetQueryInFlight = false,
      _targetRetryUsed = false,
      targetRetryAvailable = false,
      resolvingTarget = false,
      targetUnavailable = false;
  bool _routeExited = false;
  int _targetGeneration = 0;
  @override
  void initState() {
    super.initState();
    widget.scene.addListener(filter);
    _initialize();
  }

  @override
  void didUpdateWidget(covariant PracticeLobby oldWidget) {
    super.didUpdateWidget(oldWidget);
    final workspaceChanged =
        !identical(oldWidget.repo, widget.repo) ||
        oldWidget.scene != widget.scene;
    if (oldWidget.scene != widget.scene) {
      oldWidget.scene.removeListener(filter);
      widget.scene.addListener(filter);
    }
    if (!workspaceChanged && oldWidget.targetLevelId == widget.targetLevelId) {
      return;
    }

    // Invalidate any pending lookup before wiring the new account or target.
    _targetGeneration++;
    _initialize();
  }

  void _initialize() {
    final target = widget.targetLevelId?.trim();
    _targetLevelId = target == null || target.isEmpty ? null : target;
    _targetHandled = false;
    _targetQueryInFlight = false;
    _targetRetryUsed = false;
    _operationInFlight = false;
    targetRetryAvailable = false;
    resolvingTarget = _targetLevelId != null;
    targetUnavailable = false;
    error = null;
    quota = false;
    _pending = const _PendingCreation(_PendingPhase.reading);
    refresh();
    final isCurrent = _currentAttempt();
    final plan = _targetLevelId == null
        ? _PendingPlan.none
        : _PendingPlan.openAfterRead;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isCurrent()) _loadPending(plan);
    });
  }

  @override
  void dispose() {
    _routeExited = true;
    _targetGeneration++;
    widget.scene.removeListener(filter);
    scenario.dispose();
    scroll.dispose();
    super.dispose();
  }

  void refresh() {
    _refreshLevels();
    _refreshHistory();
  }

  void _refreshLevels() {
    levels = widget.repo.levels(widget.scene.value, difficulty)..ignore();
  }

  void _refreshHistory() {
    // Lazy ListView children may attach their FutureBuilder after an error.
    history = widget.repo.history()..ignore();
  }

  void filter() {
    setState(() {
      person = null;
      _refreshLevels();
    });
  }

  bool _targetFailureCanRetry(Object error) =>
      error is! ApiFailure ||
      (error.status != 429 && (error.retryable == true || error.status >= 500));

  bool get _routeIsActive {
    if (!mounted || _routeExited) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isActive;
  }

  void _markRouteExited() {
    if (_routeExited) return;
    _routeExited = true;
    _targetGeneration++;
  }

  bool _targetAttemptCurrent(int generation, PracticeRepository repo) =>
      _routeIsActive &&
      generation == _targetGeneration &&
      identical(widget.repo, repo);

  bool Function() _currentAttempt() {
    final generation = _targetGeneration;
    final repo = widget.repo;
    return () => _targetAttemptCurrent(generation, repo);
  }

  Future<void> _loadPending(_PendingPlan plan) async {
    final isCurrent = _currentAttempt();
    final openPlan = plan == _PendingPlan.openAfterRead;
    setState(() {
      _pending = _PendingCreation(_PendingPhase.reading, plan: plan);
      resolvingTarget = openPlan;
      error = null;
      quota = false;
    });
    final Json? intent;
    try {
      intent = await widget.repo.read('creating');
    } catch (_) {
      if (isCurrent()) {
        setState(() {
          _pending = _PendingCreation(_PendingPhase.readFailed, plan: plan);
          resolvingTarget = false;
        });
      }
      return;
    }
    if (!isCurrent()) return;
    setState(() {
      _pending = _PendingCreation(
        _PendingPhase.ready,
        intent: intent,
        plan: intent != null && plan == _PendingPlan.conflict
            ? plan
            : _PendingPlan.none,
      );
    });
    if (openPlan) {
      _targetHandled = false;
      await _openTargetLevel();
    }
  }

  void _retryPendingRead() {
    if (!_routeIsActive || busy || _pending.phase != _PendingPhase.readFailed) {
      return;
    }
    _loadPending(_pending.plan);
  }

  Future<void> _retryTargetLevel() async {
    if (_targetRetryUsed ||
        !targetRetryAvailable ||
        busy ||
        !_canStart ||
        _targetQueryInFlight ||
        !_routeIsActive) {
      return;
    }
    _targetRetryUsed = true;
    await _openTargetLevel();
  }

  Future<void> _openTargetLevel() async {
    final target = _targetLevelId;
    if (!_routeIsActive ||
        target == null ||
        _targetHandled ||
        _targetQueryInFlight) {
      return;
    }
    final generation = ++_targetGeneration;
    final repo = widget.repo;
    _targetQueryInFlight = true;
    setState(() {
      resolvingTarget = true;
      targetRetryAvailable = false;
      targetUnavailable = false;
      error = null;
      quota = false;
    });
    try {
      final level = await repo.findLevel(target);
      if (!_targetAttemptCurrent(generation, repo)) return;
      if (level == null) {
        setState(() {
          _targetQueryInFlight = false;
          _targetHandled = true;
          resolvingTarget = false;
          targetUnavailable = true;
        });
        return;
      }
      _targetQueryInFlight = false;
      setState(() {
        _targetHandled = true;
        resolvingTarget = false;
        targetRetryAvailable = false;
        targetUnavailable = false;
      });
      await run(
        () => start(
          {'level_id': target},
          plannedTarget: true,
          stillCurrent: () => _targetAttemptCurrent(generation, repo),
        ),
      );
    } catch (error) {
      if (!_targetAttemptCurrent(generation, repo)) return;
      final retry = !_targetRetryUsed && _targetFailureCanRetry(error);
      final quotaFailure = error is ApiFailure && error.status == 429;
      final exhaustedTemporary =
          !retry &&
          !quotaFailure &&
          (error is! ApiFailure ||
              error.retryable == true ||
              error.status >= 500);
      setState(() {
        _targetQueryInFlight = false;
        _targetHandled = !retry;
        targetRetryAvailable = retry;
        resolvingTarget = false;
        this.error = exhaustedTemporary
            ? '暂时无法打开计划中的对练，请返回今日计划稍后再试。'
            : problem(error);
        quota = quotaFailure;
      });
    } finally {
      if (mounted && generation == _targetGeneration) {
        _targetQueryInFlight = false;
      }
    }
  }

  Future<void> run(Future<void> Function() f) async {
    if (busy || resolvingTarget || !_routeIsActive) return;
    final isCurrent = _currentAttempt();
    setState(() {
      _operationInFlight = true;
      error = null;
      quota = false;
    });
    try {
      await f();
    } catch (e) {
      if (isCurrent()) {
        setState(() {
          error = problem(e);
          quota = e is ApiFailure && e.status == 429;
        });
        _scrollToFeedback();
      }
    } finally {
      if (isCurrent()) setState(() => _operationInFlight = false);
    }
  }

  void _scrollToFeedback() {
    FocusManager.instance.primaryFocus?.unfocus();
    if (scroll.hasClients) scroll.jumpTo(0);
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

  Future<void> _abandonPending() async {
    if (busy ||
        resolvingTarget ||
        !_routeIsActive ||
        (_pending.phase != _PendingPhase.abandonFailed &&
            (_pending.phase != _PendingPhase.ready ||
                _pending.intent == null))) {
      return;
    }
    final repo = widget.repo;
    final isCurrent = _currentAttempt();
    final plan = _pending.plan;
    setState(() {
      _pending = _PendingCreation(_PendingPhase.abandoning, plan: plan);
      error = null;
      quota = false;
    });
    try {
      await repo.remember('creating', null);
      if (!isCurrent()) return;
      // The confirmation also supplies the lobby's new pending state.
      final remaining = await repo.read('creating');
      if (!isCurrent()) return;
      if (remaining != null) throw StateError('pending still present');
    } catch (e) {
      if (isCurrent()) {
        setState(() {
          _pending = _PendingCreation(_PendingPhase.abandonFailed, plan: plan);
          error = e is ApiFailure ? problem(e) : '未能确认上次创建请求已放弃，请重试。';
          quota = e is ApiFailure && e.status == 429;
        });
        _scrollToFeedback();
      }
      return;
    }

    setState(() => _pending = const _PendingCreation(_PendingPhase.ready));
    if (plan == _PendingPlan.conflict) {
      _targetHandled = false;
      await _openTargetLevel();
    }
  }

  Future<void> _resumePending() async {
    final intent = _pending.intent;
    if (_pending.phase != _PendingPhase.ready || intent == null) return;
    final isCurrent = _currentAttempt();
    await run(() => create(intent, stillCurrent: isCurrent));
  }

  Future<void> start(
    Json input, {
    bool Function()? stillCurrent,
    bool plannedTarget = false,
    String? previousId,
  }) async {
    final isCurrent = stillCurrent ?? _currentAttempt();
    if (!_canStart || !isCurrent()) return;
    final Json? existing;
    try {
      // Recheck the journal at the creation boundary, even after abandonment.
      existing = await widget.repo.read('creating');
    } catch (_) {
      if (isCurrent()) {
        setState(() {
          _pending = _PendingCreation(
            _PendingPhase.readFailed,
            plan: plannedTarget
                ? _PendingPlan.openAfterRead
                : _PendingPlan.none,
          );
        });
        _scrollToFeedback();
      }
      return;
    }
    if (!isCurrent()) return;
    setState(() {
      _pending = _PendingCreation(
        _PendingPhase.ready,
        intent: existing,
        plan: existing != null && plannedTarget
            ? _PendingPlan.conflict
            : _PendingPlan.none,
      );
    });
    if (existing != null) {
      throw ApiFailure(
        409,
        'conflict',
        plannedTarget ? '先恢复上次创建，或放弃后继续打开今日计划中的对练。' : '请先恢复或放弃上次创建请求。',
        false,
      );
    }
    await create({
      'input': {...input, 'request_id': newRequestId()},
      'previous_id': ?previousId,
    }, stillCurrent: isCurrent);
  }

  // Every creation path, including replay and repeat, must re-read the T05
  // purpose grant. A local notice or an old draft is not consent.
  Future<bool> ensurePracticeConsent({bool Function()? stillCurrent}) async {
    final bool Function() isCurrent = stillCurrent ?? () => _routeIsActive;
    if (widget.demo) return true;
    final granted = await widget.repo.practiceConsent();
    if (!mounted || !isCurrent()) return false;
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
    if (!mounted || !isCurrent()) return false;
    if (ok != true) return false;
    await widget.repo.grantPracticeConsent();
    if (!isCurrent()) return false;
    final confirmed = await widget.repo.practiceConsent();
    if (!isCurrent()) return false;
    if (!confirmed) {
      throw const ApiFailure(403, 'forbidden', '练习授权未生效，请重试。', true);
    }
    return true;
  }

  Future<void> create(
    Json intent, {
    required bool Function() stillCurrent,
  }) async {
    final isCurrent = stillCurrent;
    if (!mounted || !isCurrent()) return;
    final repo = widget.repo;
    if (!await ensurePracticeConsent(stillCurrent: isCurrent)) return;
    if (!isCurrent()) return;
    final input = intent['input'] as Json;
    final body = {
      ...input,
      if (intent['previous_id'] != null) 'previous_id': intent['previous_id'],
    };
    // Fail closed for deleted / newly read-only contacts (also on replay).
    if (body['contact_id'] != null) {
      final book = await widget.contacts!.load();
      if (!isCurrent()) return;
      if (!book.people.any(
        (p) => p.id == body['contact_id'] && book.usable(p),
      )) {
        throw const ApiFailure(403, 'forbidden', '关系人已不可用，请重新选择。', false);
      }
    }
    await _savePending(repo, intent, isCurrent);
    if (!isCurrent()) return;
    final s = await repo.create(body);
    if (!isCurrent()) return;
    if (s['session_id'] != body['request_id']) throw const FormatException();
    await _savePending(repo, null, isCurrent);
    if (!isCurrent()) return;
    await open(
      s,
      input,
      priorId: intent['previous_id'],
      stillCurrent: isCurrent,
    );
  }

  Future<void> _savePending(
    PracticeRepository repo,
    Json? intent,
    bool Function() isCurrent,
  ) async {
    final plan = _pending.plan;
    try {
      await repo.remember('creating', intent);
    } catch (_) {
      // A failed write leaves the cache outcome unknown, so reconcile it.
      if (isCurrent()) await _loadPending(plan);
      rethrow;
    }
    if (!isCurrent()) return;
    setState(() {
      _pending = _PendingCreation(
        _PendingPhase.ready,
        intent: intent,
        plan: intent == null ? _PendingPlan.none : plan,
      );
    });
  }

  Future<void> open(
    Json s,
    Json? seed, {
    String? priorId,
    bool Function()? stillCurrent,
  }) async {
    final isCurrent = stillCurrent ?? _currentAttempt();
    if (!mounted || !isCurrent()) return;
    final id = s['session_id'] as String;
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
    if (!isCurrent()) return;
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
        if (!isCurrent()) return;
      } else if (level != null) {
        final list = await history;
        if (!isCurrent()) return;
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
    if (!mounted || !isCurrent()) return;
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
    if (!isCurrent()) return;
    final input = repeat?['input'];
    if (input is Json) {
      await start(input, previousId: id, stillCurrent: isCurrent);
    } else {
      setState(refresh);
    }
  }

  Widget items(
    Future<List<Json>> f,
    String empty,
    VoidCallback reload,
    Widget Function(Json) tile,
  ) => FutureBuilder<List<Json>>(
    future: f,
    builder: (context, s) {
      if (s.connectionState != ConnectionState.done) {
        return const LinearProgressIndicator();
      }
      if (s.hasError) {
        return TextButton(
          onPressed: () => setState(reload),
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

  Widget _pendingActions() {
    final canResolve = !busy && !resolvingTarget;
    final continuesPlan = _pending.plan == _PendingPlan.conflict;
    final hint = continuesPlan
        ? const Text('恢复会打开上次的练习；放弃后会继续打开今日计划中的对练。')
        : null;
    switch (_pending.phase) {
      case _PendingPhase.reading:
      case _PendingPhase.abandoning:
        return const SizedBox.shrink();
      case _PendingPhase.readFailed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_pending.plan == _PendingPlan.openAfterRead)
              const Text('重新核对后会继续打开今日计划中的对练。'),
            TextButton(
              onPressed: canResolve ? _retryPendingRead : null,
              child: const Text('本机续练记录读取失败，重试'),
            ),
          ],
        );
      case _PendingPhase.abandonFailed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?hint,
            OutlinedButton.icon(
              onPressed: canResolve ? _abandonPending : null,
              icon: const Icon(Icons.refresh),
              label: Text(continuesPlan ? '重试放弃并继续' : '重试放弃创建请求'),
            ),
          ],
        );
      case _PendingPhase.ready:
        if (_pending.intent == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ?hint,
            if (resolvingTarget) const Text('正在核对上次创建请求与今日计划中的对练…'),
            Wrap(
              children: [
                FilledButton(
                  onPressed: canResolve ? _resumePending : null,
                  child: const Text('恢复上次创建'),
                ),
                TextButton(
                  onPressed: canResolve ? _abandonPending : null,
                  child: const Text('放弃创建请求'),
                ),
              ],
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _markRouteExited();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('对练与预演')),
        body: SafeArea(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              if (widget.demo) const Text('离线演示 · 示例反馈不会计入真实额度'),
              if (busy) Semantics(liveRegion: true, child: const Text('正在处理…')),
              if (resolvingTarget)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text('正在打开计划中的对练…'),
                ),
              if (targetUnavailable)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.link_off_outlined),
                  title: Text('这项计划中的对练已删除或不可用，请返回今日计划重新选择。'),
                ),
              if (error != null) Text(error!, semanticsLabel: error),
              if (targetRetryAvailable && !resolvingTarget)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: busy || !_canStart ? null : _retryTargetLevel,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试打开计划中的对练'),
                  ),
                ),
              if (quota)
                TextButton(
                  onPressed: () => Navigator.pushNamed(context, '/membership'),
                  child: const Text('查看额度与重置时间'),
                ),
              _pendingActions(),
              Text('选一个练习场景', style: theme.titleLarge),
              GlobalScenePicker(widget.scene),
              if (widget.contacts != null)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(person?.name ?? '不指定关系人'),
                  subtitle: const Text('可选 · 只显示可用于当前场景的人'),
                  trailing: const Icon(Icons.unfold_more),
                  onTap: busy || resolvingTarget ? null : () => run(choose),
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
                      onSelected: busy || resolvingTarget
                          ? null
                          : (_) {
                              setState(() {
                                difficulty = d;
                                _refreshLevels();
                              });
                            },
                    ),
                ],
              ),
              items(
                levels,
                '这个条件下还没有关卡，试试其他难度。',
                _refreshLevels,
                (l) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l['title']),
                  subtitle: Text(
                    '难度 ${l['difficulty']} · ${skills[l['target_item']] ?? '整场表达'}',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy || resolvingTarget || !_canStart
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
                onPressed:
                    busy ||
                        resolvingTarget ||
                        !_canStart ||
                        scenario.text.trim().isEmpty
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
              items(history, '还没有练习记录。', _refreshHistory, (s) {
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
                  onTap: busy || resolvingTarget
                      ? null
                      : () => run(() => open(s, null)),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
