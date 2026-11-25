import 'package:flutter/material.dart';

import 'models.dart';
import 'presentation.dart';

class SummarySection extends StatelessWidget {
  const SummarySection({
    required this.groups,
    required this.contactNames,
    required this.onReload,
    required this.reloading,
    super.key,
  });

  final List<EmotionGroup> groups;
  final Map<String, String> contactNames;
  final VoidCallback onReload;
  final bool reloading;

  @override
  Widget build(BuildContext context) {
    final contactIds = <String>{};
    for (final group in groups) {
      final contactId = _contactId(group);
      if (contactId != null) contactIds.add(contactId);
    }
    // Ordinals are only presentation labels. Sort the opaque IDs so a stable
    // set of contacts keeps the same neutral labels across response ordering.
    final orderedContactIds = contactIds.toList()..sort();
    final contactNumbers = <String, int>{
      for (var i = 0; i < orderedContactIds.length; i++)
        orderedContactIds[i]: i + 1,
    };

    final idsByName = <String, List<String>>{};
    for (final id in orderedContactIds) {
      final name = contactNames[id]?.trim();
      if (name == null || name.isEmpty) continue;
      (idsByName[name] ??= []).add(id);
    }
    final sameNameNumbers = <String, int>{
      for (final ids in idsByName.values)
        if (ids.length > 1)
          for (var i = 0; i < ids.length; i++) ids[i]: i + 1,
    };

    String contactLabel(EmotionGroup group) {
      final contactId = _contactId(group);
      if (contactId == null) return '未关联对象';
      final name = contactNames[contactId]?.trim();
      if (name != null && name.isNotEmpty) {
        final number = sameNameNumbers[contactId];
        return number == null ? name : '$name（对象 $number）';
      }
      return '已关联对象 ${contactNumbers[contactId]}';
    }

    final baseTitles = [
      for (final group in groups)
        '${contactLabel(group)} · ${assistSceneLabels[group.scene] ?? '未补场景'}',
    ];
    final reservedTitles = baseTitles.toSet();
    final displayedTitles = <String>{};
    final titles = <String>[];
    for (final base in baseTitles) {
      var title = base;
      var number = 1;
      while (displayedTitles.contains(title)) {
        do {
          title = '$base（分组 ${number++}）';
        } while (reservedTitles.contains(title));
      }
      displayedTitles.add(title);
      titles.add(title);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            '按对象与场景的回看',
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            style: assistButtonStyle,
            onPressed: reloading ? null : onReload,
            icon: reloading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(reloading ? '正在重新读取…' : '重新读取汇总'),
          ),
        ),
        const SizedBox(height: 8),
        if (groups.isEmpty)
          const Text('还没有可汇总的授权记录。')
        else
          for (final (index, group) in groups.indexed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titles[index],
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text('手动记录 ${group.manualCount} 次'),
                    Text('明确本人 ${group.confirmedSelfCount} 次'),
                  ],
                ),
              ),
            ),
        const SizedBox(height: 8),
        const Text('这些只是授权范围内的记录计数，不计算分数，也不推断人格。'),
      ],
    );
  }

  String? _contactId(EmotionGroup group) {
    final contactId = group.contactId?.trim();
    return contactId == null || contactId.isEmpty ? null : contactId;
  }
}
