import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'consent.dart';
import 'session.dart';
import 'transport.dart';

// One setting selects transport AND storage namespace (including backend origin).
const endpoint = String.fromEnvironment('APP_ENDPOINT', defaultValue: 'mock');

class DeviceSecret implements SecretStore {
  final String key;
  const DeviceSecret(this.key);
  static const _vault = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );
  @override
  Future<String?> read() => _vault.read(key: key);
  @override
  Future<void> replace(String? value) => value == null
      ? _vault.delete(key: key)
      : _vault.write(key: key, value: value);
}

final apiProvider = FutureProvider<AppApi>((ref) async {
  final mock = endpoint == 'mock';
  final origin = Uri.parse(mock ? 'https://example.invalid' : endpoint);
  if (origin.scheme != 'https' ||
      origin.host.isEmpty ||
      origin.userInfo.isNotEmpty ||
      !{'', '/'}.contains(origin.path) ||
      origin.hasQuery ||
      origin.hasFragment) {
    throw const FormatException('请输入 HTTPS 服务地址');
  }
  final name = base64UrlEncode(
    (await Sha256().hash(utf8.encode(endpoint))).bytes,
  );
  final dir = await getApplicationCacheDirectory();
  final sessions = Sessions(
    DeviceSecret('session.$name'),
    Directory('${dir.path}/accounts/$name'),
  );
  await sessions.restore();
  final transport = mock ? ExampleTransport() : HttpTransport(http.Client());
  ref.onDispose(transport.close);
  return AppApi(origin, transport, sessions);
});

/// The active identity changes synchronously when a session is revoked. Keep
/// that transition observable without asking account-scoped providers to read
/// a nullable session and throw while their old page is still mounted.
final accountScopeProvider = Provider<AccountScope?>((ref) {
  final api = ref.watch(apiProvider).requireValue;
  final identity = api.sessions.identity;
  void changed() => ref.invalidateSelf();
  identity.addListener(changed);
  ref.onDispose(() => identity.removeListener(changed));
  return identity.value;
});

final consentProvider = FutureProvider<ConsentGate>(
  (ref) async => ConsentGate(await ref.watch(apiProvider.future)),
);
