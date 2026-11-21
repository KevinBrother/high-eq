import 'package:flutter/material.dart';

/// Trim only the shared prefix and suffix; the two displayed blocks preserve
/// whitespace and relative order without quadratic diffing of 64 KiB templates.
class TemplateDelta extends StatelessWidget {
  const TemplateDelta(
    this.oldText,
    this.newText,
    this.oldLabel,
    this.newLabel, {
    super.key,
  });
  final String oldText, newText, oldLabel, newLabel;
  @override
  Widget build(BuildContext context) {
    if (oldText == newText) return const Text('两版正文相同');
    final a = oldText.split('\n'), b = newText.split('\n');
    int start = 0, end = 0;
    while (start < a.length && start < b.length && a[start] == b[start]) {
      start++;
    }
    while (end < a.length - start &&
        end < b.length - start &&
        a[a.length - 1 - end] == b[b.length - 1 - end]) {
      end++;
    }
    Widget block(String label, List<String> lines, Color color) => Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label · ${lines.length} 行',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          if (lines.isNotEmpty) SelectableText(lines.join('\n')),
        ],
      ),
    );
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('两版正文不同'),
        Text('从第 ${start + 1} 行开始 · 已折叠前 $start 行和末尾 $end 行相同正文'),
        const SizedBox(height: 8),
        block(
          '对照 $oldLabel',
          a.sublist(start, a.length - end),
          colors.surfaceContainerHighest,
        ),
        block(
          '所选 $newLabel',
          b.sublist(start, b.length - end),
          colors.secondaryContainer,
        ),
      ],
    );
  }
}
