import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import '../../core/api.dart';
import '../../core/endpoints.g.dart';
import '../../core/session.dart';
import '../../core/transport.dart';
import '../onboarding/login.dart' show vendorChannel;

/// The offline transport never reaches a platform SDK; neither path grants rights locally.
class StorePort {
  final bool demo;
  const StorePort(this.demo);
  Future<void> available(String channel) async {
    if (!demo &&
        await vendorChannel.invokeMethod<bool>('available', {
              'channel': channel,
            }) !=
            true) {
      throw PlatformException(code: 'unavailable');
    }
  }

  Future<List<String>> apple(String? plan, String? token) async {
    if (demo) return ['example-only'];
    return await vendorChannel.invokeListMethod<String>(
          plan == null ? 'restore' : 'purchase',
          {'plan': plan, 'appAccountToken': token},
        ) ??
        [];
  }

  Future<void> finish(String signed) async {
    if (!demo) {
      await vendorChannel.invokeMethod<void>('finish', {'signed': signed});
    }
  }

  Future<void> android(String channel, String payload) async {
    if (!demo) {
      await vendorChannel.invokeMethod<void>('pay', {
        'channel': channel,
        'payload': payload,
      });
    }
  }
}

String _uuid() {
  final r = Random.secure(), b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

class MemberStore {
  final AppApi api;
  final AccountScope scope;
  final StorePort port;
  MemberStore(this.api, this.scope, {StorePort? port})
    : port = port ?? StorePort(api.transport is ExampleTransport);
  MobileEndpoints get wire => MobileEndpoints(api);
  Future<Json> rights() => wire.getEntitlements(scope: scope);
  Future<bool> apple({String? plan}) async {
    await port.available('apple');
    String? token;
    if (plan != null) {
      token =
          (await wire.getPurchaseToken(scope: scope))['app_account_token']
              as String;
      if (!RegExp(
        r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
      ).hasMatch(token)) {
        throw const FormatException();
      }
    }
    api.sessions.require(scope);
    final signed = await port.apple(plan, token);
    for (final tx in signed) {
      if (tx.isEmpty) throw const FormatException();
      await wire.restorePurchase(
        scope: scope,
        body: {'signed_transaction': tx},
      );
      api.sessions.require(scope);
      await port.finish(tx);
    }
    return signed.isNotEmpty;
  }

  Future<void> android(String channel, String plan) async {
    await port.available(channel);
    final key = 'purchase.$channel.$plan';
    final pending = await api.sessions.get(scope, CacheKind.queue, key);
    final id = pending == null ? _uuid() : utf8.decode(pending);
    if (pending == null) {
      await api.sessions.put(scope, CacheKind.queue, key, utf8.encode(id));
    }
    final order = await wire.createOrder(
      scope: scope,
      body: {'platform': channel, 'product': plan, 'request_id': id},
    );
    api.sessions.require(scope);
    await port.android(channel, order['payment_payload'] as String);
    await api.sessions.remove(scope, CacheKind.queue, key);
  }
}
