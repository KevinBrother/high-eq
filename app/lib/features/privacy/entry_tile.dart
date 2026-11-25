import 'package:flutter/material.dart';

class PrivacyEntryTile extends StatelessWidget {
  const PrivacyEntryTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    key: const Key('me-privacy'),
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.shield_outlined),
    title: const Text('隐私与个人数据'),
    subtitle: const Text('查阅账号资料、导出数据、删除记录与管理注销'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => Navigator.pushNamed(context, '/privacy'),
  );
}
