import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/transport.dart';
import '../contacts/routes.dart';
import '../contacts/scene.dart';
import 'radar.dart';
import 'repository.dart';
import 'score.dart';
import 'surface.dart';

enum _Step { loading, consent, item, scene, result }

class AssessmentPage extends ConsumerStatefulWidget {
  const AssessmentPage(this.book, {super.key, this.startup = false});
  final AssessmentBook book;
  final bool startup;
  @override
  ConsumerState<AssessmentPage> createState() => _AssessmentState();
}

class _AssessmentState extends ConsumerState<AssessmentPage> {
  var step = _Step.loading;
  bool busy = false;
  String? error;
  Json? result, form;
  List<int> answers = [];
  int index = 0;
  DateTime? next;
  Timer? tick;
  AssessmentBook get book => widget.book;
  SceneMemory get scenes => ref.read(contactSpaceProvider).scene;
  @override
  void initState() {
    super.initState();
    run(load);
  }

  @override
  void dispose() {
    tick?.cancel();
    super.dispose();
  }

  void home() {
    Navigator.of(context).pushNamedAndRemoveUntil('/practice', (_) => false);
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      error = friendlyError(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> load() async {
    step = _Step.loading;
    if (!await book.allowed()) {
      await book.discardDraft();
      step = _Step.consent;
      return;
    }
    final previous = await book.latest();
    final draft = await book.read('draft');
    if (!mounted) return;
    if (previous != null &&
        (draft == null ||
            DateTime.parse(
              previous['next_eligible_at'],
            ).isAfter(DateTime.now()))) {
      await book.discardDraft();
      if (!mounted) return;
      if (widget.startup) {
        home();
      } else {
        showResult(previous);
      }
      return;
    }
    await questions(draft);
  }

  Future<void> questions(Json? saved) async {
    final q = await book.instrument();
    if (!mounted) return;
    form = q;
    answers = [];
    index = 0;
    if (saved?['version'] == q['version']) {
      final a = (saved!['answers'] as List).cast<int>();
      final i = saved['index'] as int;
      if (a.length <= 16 &&
          a.every((n) => n >= 1 && n <= 7) &&
          i >= 0 &&
          i <= a.length) {
        answers = a.toList();
        index = i;
        scenes.value = Scene.values.byName(saved['scene']);
      }
    }
    step = index == 16 ? _Step.scene : _Step.item;
  }

  Future<void> persist(List<int> a, int i, Scene s) => book.save('draft', {
    'version': form!['version'],
    'index': i,
    'answers': a,
    'scene': s.name,
  });
  Future<void> answer(int n) async {
    final a = [...answers];
    if (index == a.length) {
      a.add(n);
    } else {
      a[index] = n;
    }
    await persist(a, index + 1, scenes.value);
    if (!mounted) return;
    answers = a;
    index++;
    step = index == 16 ? _Step.scene : _Step.item;
  }

  Future<void> back() async {
    await persist(answers, index - 1, scenes.value);
    index--;
    step = _Step.item;
  }

  void showResult(Json? value, {DateTime? deadline}) {
    result = value;
    next = deadline ?? DateTime.parse(value!['next_eligible_at']);
    step = _Step.result;
    tick?.cancel();
    tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> submit() async {
    try {
      final r = await book.submit(form!['version'], answers);
      await book.discardDraft();
      if (mounted) showResult(r);
    } on ApiFailure catch (e) {
      if (e.status != 409 || e.retryAt == null) rethrow;
      await book.discardDraft();
      if (mounted) showResult(null, deadline: e.retryAt);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (step) {
      case _Step.loading:
        return FlowSurface('个人空间', '正在准备自评', busy: busy, message: error, [
          if (!busy)
            FilledButton(onPressed: () => run(load), child: const Text('重试')),
          if (!busy) TextButton(onPressed: home, child: const Text('暂时跳过')),
        ]);
      case _Step.consent:
        return Scaffold(
          body: Center(
            child: AlertDialog(
              scrollable: true,
              title: const Text('是否同意开始本次自评？'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '16 道题，约 2 分钟。我们需要答卷生成四维雷达图和训练计划。答卷与得分可能反映个人情绪倾向，加密保存至注销。中途离开可在本机续答。结果仅代表你的看法，不是诊断。不同意仍可使用其他功能。',
                  ),
                  if (error != null) Text(error!),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : home,
                  child: const Text('暂不测评'),
                ),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                          await book.grant();
                          await questions(null);
                        }),
                  child: const Text('单独同意并开始'),
                ),
              ],
            ),
          ),
        );
      case _Step.item:
        final q = form!;
        final item = q['items'][index];
        return FlowSurface(
          '本次自评   /   ${abilities[item['dimension']]}',
          '第 ${index + 1} / 16 题',
          busy: busy,
          message: error,
          [
            LinearProgressIndicator(value: index / 16),
            const SizedBox(height: 20),
            Text(item['zh'], style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 10),
            const Text('按平时的真实情况选择，答案没有对错。'),
            const SizedBox(height: 12),
            for (var i = 1; i <= 7; i++)
              ListTile(
                selected: index < answers.length && answers[index] == i,
                leading: Text('$i'),
                title: Text(q['options'][i - 1]),
                onTap: () => run(() => answer(i)),
              ),
            if (index > 0)
              TextButton(onPressed: () => run(back), child: const Text('上一题')),
            TextButton(onPressed: home, child: const Text('稍后续答')),
          ],
        );
      case _Step.scene:
        final memory = ref.watch(contactSpaceProvider).scene;
        return FlowSurface(
          '本次自评   /   16 题已答完',
          '想先在哪种场合练习？',
          busy: busy,
          message: error,
          [
            const Text('这个选择也会用于练习页，以后可以更改。'),
            const SizedBox(height: 16),
            ScenePicker(
              value: memory.value,
              onChanged: (s) => run(() async {
                await persist(answers, index, s);
                if (mounted) memory.value = s;
              }),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => run(submit),
              child: const Text('提交并查看雷达图'),
            ),
            TextButton(onPressed: () => run(back), child: const Text('返回检查答案')),
            TextButton(onPressed: home, child: const Text('稍后续答')),
          ],
        );
      case _Step.result:
        final remaining = next!.difference(DateTime.now());
        final days = (remaining.inSeconds / 86400).ceil();
        final r = result;
        return FlowSurface(
          '沟通手记   /   四维雷达',
          '看看此刻的自己',
          busy: busy,
          message: error,
          [
            if (r != null) ...[
              AssessmentRadar(
                percentages: {
                  for (final k in abilities.keys)
                    k: (r['dimensions'][k]['percent'] as num).toDouble(),
                },
              ),
              Text('本次自评总分 · ${(r['total']['percent'] as num).round()} / 100'),
            ],
            const SizedBox(height: 16),
            if (remaining > Duration.zero)
              Text('距下次可复测还有 ${days < 1 ? 1 : days} 天')
            else
              OutlinedButton(
                onPressed: () => run(() => questions(null)),
                child: const Text('开始复测'),
              ),
            FilledButton(onPressed: home, child: const Text('进入练习')),
          ],
        );
    }
  }
}
