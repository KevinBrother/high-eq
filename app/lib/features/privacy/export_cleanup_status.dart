class PrivacyExportCleanupStatus {
  const PrivacyExportCleanupStatus({
    required this.ok,
    required this.removed,
    required this.failed,
  });

  final bool ok;
  final int removed;
  final int failed;

  factory PrivacyExportCleanupStatus.fromChannel(Object? value) {
    if (value is! Map) throw const FormatException('导出清理状态格式异常');
    final state = value['state'];
    final removed = value['removed'];
    final failed = value['failed'];
    if ((state != 'ok' && state != 'failed') ||
        removed is! int ||
        failed is! int ||
        removed < 0 ||
        failed < 0) {
      throw const FormatException('导出清理状态格式异常');
    }
    return PrivacyExportCleanupStatus(
      ok: state == 'ok' && failed == 0,
      removed: removed,
      failed: failed,
    );
  }
}
