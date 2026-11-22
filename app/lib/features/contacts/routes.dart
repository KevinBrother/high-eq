import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/endpoints.g.dart';
import '../../core/providers.dart';
import '../../core/transport.dart';
import 'demo.dart';
import 'repository.dart';
import 'scene.dart';
import 'workspace.dart';

/// Both routes and onboarding watch the same provider. Session changes discard
/// scene and demo data even when a form is open; old network work stays scoped.
final contactSpaceProvider = Provider((ref) {
  final api = ref.watch(apiProvider).requireValue;
  final scope = ref.watch(accountScopeProvider);
  final demo = api.transport is ExampleTransport;
  final ContactsRepository? repo = demo
      ? DemoContacts()
      : scope == null
      ? null
      : ApiContacts(MobileEndpoints(api), scope);
  return (scene: SceneMemory(), repo: repo, demo: demo);
});

class ContactRoute extends ConsumerWidget {
  const ContactRoute({required this.sceneOnly, super.key});
  final bool sceneOnly;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final space = ref.watch(contactSpaceProvider);
    final repo = space.repo;
    if (sceneOnly) {
      return Scaffold(
        appBar: AppBar(title: const Text('练习场景')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                '你想在哪种场合练习？',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text('这里的选择将用于接下来的练习，随时可以切换。'),
              const SizedBox(height: 20),
              GlobalScenePicker(space.scene),
            ],
          ),
        ),
      );
    }
    if (repo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('关系人')),
        body: const Center(child: Text('请先登录，再打开自己的关系手记。')),
      );
    }
    return ContactsWorkspace(
      key: ObjectKey(repo),
      repo: repo,
      selection: space.scene,
      demo: space.demo,
    );
  }
}
