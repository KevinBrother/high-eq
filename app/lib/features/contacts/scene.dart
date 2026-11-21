import 'package:flutter/material.dart';

enum Scene {
  work('职场'),
  partner('伴侣'),
  family('家人'),
  friends('朋友'),
  social('陌生社交');

  const Scene(this.label);
  final String label;
}

/// Share within a login session, never between accounts. For a local form draft
/// use ScenePicker directly so abandoning the form cannot change the global scene.
class SceneMemory extends ValueNotifier<Scene> {
  SceneMemory([super.value = Scene.work]);
}

class GlobalScenePicker extends StatelessWidget {
  const GlobalScenePicker(this.memory, {super.key});
  final SceneMemory memory;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Scene>(
    valueListenable: memory,
    builder: (_, value, _) =>
        ScenePicker(value: value, onChanged: (s) => memory.value = s),
  );
}

class ScenePicker extends StatelessWidget {
  const ScenePicker({required this.value, required this.onChanged, super.key});
  final Scene value;
  final ValueChanged<Scene>? onChanged;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      for (final s in Scene.values)
        ChoiceChip(
          label: Text(s.label),
          selected: s == value,
          onSelected: onChanged == null ? null : (_) => onChanged!(s),
        ),
    ],
  );
}
