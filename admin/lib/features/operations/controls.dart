import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/api.dart';
import '../../core/session.dart';

String failure(Object e, WidgetRef ref) {
  if (e is ApiFailure && e.status == 401) {
    ref.read(sessionProvider.notifier).clear();
  }
  return e is ApiFailure ? e.message : '读取数据失败，请重试';
}

class Choice extends StatelessWidget {
  const Choice(this.label, this.value, this.items, this.change, {super.key});
  final String label;
  final String? value;
  final Map<String, String> items;
  final ValueChanged<String>? change;
  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(labelText: label),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        isDense: true,
        isExpanded: true,
        value: items.containsKey(value) ? value : null,
        hint: const Text('暂无可选项'),
        items: [
          for (final e in items.entries)
            DropdownMenuItem(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: change == null
            ? null
            : (v) {
                if (v != null) change!(v);
              },
      ),
    ),
  );
}

class Section extends StatelessWidget {
  const Section(this.title, this.children, {super.key});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          for (final w in children) ...[const SizedBox(height: 12), w],
        ],
      ),
    ),
  );
}
