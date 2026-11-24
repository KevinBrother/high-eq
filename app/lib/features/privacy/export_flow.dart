import 'dart:async';

import 'package:path_provider/path_provider.dart';

import '../../core/api.dart';
import '../../core/app_op.g.dart';
import '../../core/session.dart';
import 'account_access.dart';
import 'export.dart';
import 'export_delivery.dart';

enum PrivacyExportPhase { preparing, downloading, opening, presenting }

/// A single privacy route owns this flow and its cleanup capability.
final class PrivacyExportFlow {
  PrivacyExportFlow(this._api, this._scope)
    : _admission = AccountAccess.of(_api, _scope),
      _sink = FilePrivacyExportSink.accountScopedLazy(
        getTemporaryDirectory,
        _scope.account,
        requireAccountManifest: true,
      ) {
    _api.sessions.identity.addListener(_checkAccount);
    _admission.addListener(_checkAccount);
  }

  final AppApi _api;
  final AccountScope _scope;
  final AccountAccess _admission;
  final FilePrivacyExportSink _sink;
  final _delivery = const PlatformPrivacyExportDelivery();
  Completer<void>? _abort;
  PrivacyExportCleanup? _pendingCleanup;
  bool _closed = false;

  void _checkAccount() {
    if (!_admission.isOrdinary) cancel();
  }

  void cancel() {
    final abort = _abort;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _api.sessions.identity.removeListener(_checkAccount);
    _admission.removeListener(_checkAccount);
    cancel();
  }

  Future<void> run(void Function(PrivacyExportPhase) onPhase) async {
    if (_closed || _abort != null) throw _cancelled;
    final account = _admission.requireOrdinary();
    final abort = _abort = Completer<void>();
    PrivacyExportArtifact? artifact;
    var dispatched = false;
    var delivered = false;
    void requireAllowed() {
      if (abort.isCompleted) throw _cancelled;
      _admission.requireOrdinary(account);
    }

    try {
      onPhase(PrivacyExportPhase.preparing);
      await _preflight();
      requireAllowed();
      await _recover();
      requireAllowed();
      onPhase(PrivacyExportPhase.downloading);
      artifact = await _sink.save(
        _api
            .bytesGuarded(
              AppOp.exportData,
              scope: _scope,
              beforeSend: () async => requireAllowed(),
              checkBeforeSend: requireAllowed,
              abortTrigger: abort.future,
            )
            .map((chunk) {
              requireAllowed();
              return chunk;
            }),
      );
      requireAllowed();
      await _delivery.deliverArtifact(
        artifact,
        requireAllowed: requireAllowed,
        onDispatched: () {
          dispatched = true;
          onPhase(PrivacyExportPhase.opening);
        },
        onPresented: () {
          if (!abort.isCompleted) onPhase(PrivacyExportPhase.presenting);
        },
      );
      delivered = true;
    } catch (error) {
      final failure = error is PrivacyExportStagingFailure ? error : null;
      if (failure != null) {
        _pendingCleanup = failure.cleanup;
        throw _cleanupFailure;
      }
      if (abort.isCompleted || error is SessionChanged) throw _cancelled;
      if (error is PrivacyExportIntegrityFailure) {
        throw const PrivacyExportDeliveryFailure(
          privacyExportIntegrityFailedMessage,
          deliveryCode: 'integrity_failed',
        );
      }
      if (error is PrivacyExportStagingFileFailure) {
        throw const PrivacyExportDeliveryFailure(
          privacyExportLocalStagingFailedMessage,
          deliveryCode: 'staging_failed',
        );
      }
      rethrow;
    } finally {
      try {
        final cleanup = artifact?.cleanup;
        if (cleanup != null) {
          _pendingCleanup = cleanup;
          await cleanup.discard();
          _pendingCleanup = null;
        }
      } catch (_) {
        if (delivered) {
          throw const PrivacyExportDeliveryFailure(
            '系统已完成保存或分享，临时导出文件仍待清理。',
            deliveryCode: 'cleanup_failed',
          );
        }
        if (dispatched) {
          throw const PrivacyExportDeliveryFailure(
            privacyExportDeliveryCleanupFailedMessage,
            deliveryCode: 'cleanup_failed',
          );
        }
        throw _cleanupFailure;
      } finally {
        if (!abort.isCompleted) abort.complete();
        _abort = null;
      }
    }
  }

  Future<void> _preflight() async {
    try {
      if (!(await _delivery.checkCleanup()).ok) throw _cleanupFailure;
    } on PrivacyExportDeliveryFailure {
      rethrow;
    } catch (_) {
      throw _cleanupFailure;
    }
  }

  Future<void> _recover() async {
    try {
      await _pendingCleanup?.discard();
      _pendingCleanup = null;
      await _sink.reclaimInterruptedArtifacts();
    } catch (_) {
      throw _cleanupFailure;
    }
  }

  static const _cancelled = PrivacyExportDeliveryFailure(
    privacyExportCancelledMessage,
    deliveryCode: 'cancelled',
  );
  static const _cleanupFailure = PrivacyExportDeliveryFailure(
    privacyExportCleanupFailedMessage,
    deliveryCode: 'cleanup_failed',
  );
}
