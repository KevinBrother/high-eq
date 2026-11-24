import 'package:flutter/material.dart';

import 'export_flow.dart';

class PrivacyExportCard extends StatelessWidget {
  const PrivacyExportCard({
    super.key,
    required this.phase,
    required this.onExport,
    required this.onCancel,
  });

  final PrivacyExportPhase? phase;
  final VoidCallback? onExport;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final status = switch (phase) {
      PrivacyExportPhase.preparing => '正在检查临时存储…',
      PrivacyExportPhase.downloading => '正在下载并校验 ZIP…',
      PrivacyExportPhase.opening => '正在打开系统面板…',
      PrivacyExportPhase.presenting => '请在系统面板中完成保存或分享。',
      null => '将此账号的数据打包成 ZIP，可保存到「文件」或通过系统分享。',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('数据导出', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Semantics(liveRegion: phase != null, child: Text(status)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              key: const Key('privacy-export'),
              onPressed: onExport,
              icon: const Icon(Icons.download_outlined),
              label: const Text('导出我的数据'),
            ),
            if (onCancel != null)
              TextButton(
                key: const Key('privacy-export-cancel'),
                onPressed: onCancel,
                child: const Text('取消导出'),
              ),
          ],
        ),
      ],
    );
  }
}
