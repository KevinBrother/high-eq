import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'export.dart' show PrivacyExportArtifact;
import 'export_cleanup_status.dart';

export 'export_cleanup_status.dart';

const _exportChannel = MethodChannel('cn.higheq/mobile-commerce');

const privacyExportCleanupFailedMessage = '上次临时导出文件未能清理；为保护隐私，本次未打开保存或分享。';
const privacyExportLocalStagingFailedMessage =
    '无法在本机暂存导出文件；请检查设备剩余空间与应用存储权限后重试。';
const privacyExportIntegrityFailedMessage = '导出文件完整性校验失败；未打开保存或分享，请重新导出。';
const privacyExportPartialTargetMessage = '目标位置可能留下未完成的 ZIP，请检查后手动处理。';
const privacyExportCancelledMessage = '已取消导出；临时文件已清理。';
const privacyExportUnavailableMessage = '当前设备或构建暂不支持系统保存或分享。';
const privacyExportIoErrorMessage =
    '系统未能完成导出；临时导出文件已清理，但$privacyExportPartialTargetMessage';
const privacyExportDeliveryCleanupFailedMessage =
    '系统保存或分享未完成，临时导出文件未清理；请重试或检查本机存储。';

class PrivacyExportDeliveryFailure implements Exception {
  const PrivacyExportDeliveryFailure(
    this.message, {
    required this.deliveryCode,
    this.cause,
  });

  final String message;
  final String deliveryCode;
  final Object? cause;

  @override
  String toString() => message;
}

/// Hands a validated ZIP to iOS and scopes presentation reports to the request.
class PlatformPrivacyExportDelivery {
  const PlatformPrivacyExportDelivery();

  static var _nextRequestId = 0;
  // A retiring account can still be awaiting its native receipt when the next
  // account tries to export. A presentation report belongs to only one call.
  static final _pendingPresentations = <int, void Function()?>{};

  static Future<void> _handlePresentation(MethodCall call) async {
    if (call.method != 'shareExportPresented') throw MissingPluginException();
    final requestId = call.arguments as int;
    final onPresented = _pendingPresentations[requestId];
    if (onPresented == null) return;
    _pendingPresentations[requestId] = null;
    onPresented();
  }

  bool get _supported => defaultTargetPlatform == TargetPlatform.iOS;
  static const _unavailable = PrivacyExportDeliveryFailure(
    privacyExportUnavailableMessage,
    deliveryCode: 'unavailable',
  );

  Future<PrivacyExportCleanupStatus> checkCleanup() async {
    if (!_supported) throw _unavailable;
    try {
      return PrivacyExportCleanupStatus.fromChannel(
        await _exportChannel.invokeMethod<Object?>('cleanupStatus'),
      );
    } on MissingPluginException {
      throw _unavailable;
    }
  }

  Future<void> deliver({required String path, required String mimeType}) =>
      _deliver(path: path, mimeType: mimeType);

  /// Rechecks owner and route after the final native preflight, immediately
  /// before control passes to the system activity.
  Future<void> deliverArtifact(
    PrivacyExportArtifact artifact, {
    required void Function() requireAllowed,
    required void Function() onDispatched,
    required void Function() onPresented,
  }) async {
    await _deliver(
      path: artifact.path,
      mimeType: 'application/zip',
      artifact: artifact,
      requireAllowed: requireAllowed,
      onDispatched: onDispatched,
      onPresented: onPresented,
    );
  }

  Future<void> _deliver({
    required String path,
    required String mimeType,
    PrivacyExportArtifact? artifact,
    void Function()? requireAllowed,
    void Function()? onDispatched,
    void Function()? onPresented,
  }) async {
    try {
      final cleanup = await checkCleanup();
      if (!cleanup.ok) {
        throw const PrivacyExportDeliveryFailure(
          privacyExportCleanupFailedMessage,
          deliveryCode: 'cleanup_failed',
        );
      }
      requireAllowed?.call();
      artifact?.requireCurrent();
      Future<void> share() async {
        final requestId = ++_nextRequestId;
        if (_pendingPresentations.isEmpty) {
          _exportChannel.setMethodCallHandler(_handlePresentation);
        }
        _pendingPresentations[requestId] = onPresented;
        try {
          onDispatched?.call();
          await _exportChannel.invokeMethod<void>('shareExport', {
            'path': path,
            'mimeType': mimeType,
            'requestId': requestId,
          });
        } finally {
          _pendingPresentations.remove(requestId);
          if (_pendingPresentations.isEmpty) {
            _exportChannel.setMethodCallHandler(null);
          }
        }
      }

      if (artifact == null) {
        await share();
      } else {
        await artifact.holdForDelivery(share);
      }
    } on PrivacyExportDeliveryFailure {
      rethrow;
    } on FormatException catch (error) {
      throw PrivacyExportDeliveryFailure(
        privacyExportCleanupFailedMessage,
        deliveryCode: 'cleanup_failed',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw _deliveryFailure(error.code, error);
    } on MissingPluginException catch (error) {
      throw PrivacyExportDeliveryFailure(
        privacyExportUnavailableMessage,
        deliveryCode: 'unavailable',
        cause: error,
      );
    }
  }
}

PrivacyExportDeliveryFailure _deliveryFailure(String code, Object cause) {
  final message = switch (code) {
    'cancelled' => privacyExportCancelledMessage,
    'unavailable' => privacyExportUnavailableMessage,
    'busy' => '系统正在处理上一次导出，请关闭该面板后重试。',
    'io_error' => privacyExportIoErrorMessage,
    'cleanup_failed' => privacyExportCleanupFailedMessage,
    _ => privacyExportUnavailableMessage,
  };
  return PrivacyExportDeliveryFailure(
    message,
    deliveryCode: code,
    cause: cause,
  );
}
