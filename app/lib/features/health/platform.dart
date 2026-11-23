import 'package:flutter/services.dart';

abstract interface class HealthPort {
  Future<String?> source();
  // `onSystemPrompt` must fire synchronously immediately before the actual
  // interactive OS/vendor authorization request, never during release preflight.
  Future<bool> request({void Function()? onSystemPrompt});
  // Non-interactive. Apple hides read grants: a query must itself be filtered by HealthKit.
  Future<bool> queryable();
  Future<List<List>> read(int from, int to);
  Future<void> stop();
}

class DeviceHealth implements HealthPort {
  static const _ch = MethodChannel('cn.higheq/health-history');
  @override
  Future<String?> source() => _ch.invokeMethod<String>('source');
  @override
  Future<bool> request({void Function()? onSystemPrompt}) async {
    onSystemPrompt?.call();
    return await _ch.invokeMethod<bool>('request') == true;
  }

  @override
  Future<bool> queryable() async =>
      await _ch.invokeMethod<bool>('queryable') == true;
  @override
  Future<List<List>> read(int from, int to) async =>
      (await _ch.invokeListMethod<List>('read', {'from': from, 'to': to})) ??
      [];
  @override
  Future<void> stop() => _ch.invokeMethod<void>('stop');
}
