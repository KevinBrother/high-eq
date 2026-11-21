import 'package:flutter/material.dart';
import '../../core/transport.dart';
import 'models.dart';
import 'scene.dart';

class ProfileView extends StatelessWidget {
  const ProfileView(this.contact, {super.key});
  final Contact contact;
  @override
  Widget build(BuildContext context) {
    final p = contact.profile;
    final theme = Theme.of(context);
    Widget trait(String heading, Json value) {
      final confidence = value['confidence'];
      final valid = confidence is num && confidence >= 0 && confidence <= 1;
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(heading, style: theme.textTheme.titleSmall),
            Text(observation(value['label'] as String)),
            Text(
              valid ? '把握度 ${(confidence * 100).round()}%' : '把握度暂不可用',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${contact.scene.label} · 关系手记',
          style: theme.textTheme.labelLarge,
        ),
        Text(contact.name, style: theme.textTheme.headlineMedium),
        const SizedBox(height: 16),
        Text('交流线索 · 仅供参考', style: theme.textTheme.titleLarge),
        const Text('这些是从有限描述中得到的印象，不是对一个人的定论。'),
        const SizedBox(height: 12),
        Text(observation(p['summary'] as String)),
        for (final item in p['big_five'] as List) trait('日常相处', item),
        trait('遇到分歧时', p['conflict_style']),
        if (contact.scene == Scene.partner && p['attachment'] != null)
          trait('亲密相处时', p['attachment']),
        const Divider(height: 32),
      ],
    );
  }
}
