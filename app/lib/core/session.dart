import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

abstract interface class SecretStore {
  Future<String?> read();
  Future<void> replace(String? value);
}

class Tokens {
  final String account, access, refresh;
  final DateTime expires;
  Tokens(this.account, this.access, this.refresh, this.expires) {
    if ([account, access, refresh].any((s) => s.isEmpty)) {
      throw const FormatException('登录信息不完整');
    }
  }
  factory Tokens.fromJson(Map<String, dynamic> json) => Tokens(
    json['user_id'],
    json['access_token'],
    json['refresh_token'],
    DateTime.parse(json['expires_at']),
  );
  Map<String, dynamic> toJson() => {
    'user_id': account,
    'access_token': access,
    'refresh_token': refresh,
    'expires_at': expires.toUtc().toIso8601String(),
  };
}

enum CacheKind { continuation, draft, recording, queue }

class SessionChanged implements Exception {}

/// Capture this handle when scheduling work, never look up the current user at dispatch.
class AccountScope {
  AccountScope._(this.account);
  final String account;
}

class Sessions {
  final SecretStore _secret;
  final Directory
  _directory; // Dedicated to this backend; never a shared directory.
  final _cipher = AesGcm.with256bits();
  Future<void> _tail = Future.value();
  final _identity = ValueNotifier<AccountScope?>(null);
  ValueListenable<AccountScope?> get identity => _identity;
  AccountScope? get _active => _identity.value;
  SecretKey? _key;
  Tokens? _tokens;
  int _generation = 0;
  Sessions(this._secret, this._directory);
  AccountScope? get active => _active;
  Tokens require(AccountScope scope) {
    if (!identical(scope, _active)) throw SessionChanged();
    return _tokens!;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _check(int generation) {
    if (_generation != generation) throw SessionChanged();
  }

  int _invalidate() {
    _identity.value = null;
    _tokens = null;
    _key = null;
    return ++_generation;
  }

  Future<void> _wipe() async {
    // Destroy decryption material first, including after a process interruption.
    await _secret.replace(null);
    if (await _directory.exists()) await _directory.delete(recursive: true);
    await _directory.create(recursive: true);
  }

  Future<void> restore() {
    final generation = _invalidate();
    return _serial(() async {
      final raw = await _secret.read();
      if (raw == null) {
        await _wipe();
        return;
      }
      final data = jsonDecode(raw);
      final tokens = Tokens.fromJson(data['tokens']);
      final key = SecretKey(base64Decode(data['key']));
      await _directory.create(recursive: true);
      await for (final entry in _directory.list()) {
        if (entry is File &&
            (entry.path.endsWith('.new') ||
                (entry.path.endsWith('.audio') && await _expired(entry)))) {
          await entry.delete();
        }
      }
      _check(generation);
      _key = key;
      _tokens = tokens;
      _identity.value = AccountScope._(tokens.account);
    });
  }

  Future<AccountScope> activate(Tokens tokens) {
    final generation = _invalidate();
    return _serial(() async {
      await _wipe();
      final key = await _cipher.newSecretKey();
      await _persist(tokens, key);
      _check(generation);
      _tokens = tokens;
      _key = key;
      return _identity.value = AccountScope._(tokens.account);
    });
  }

  Future<void> _persist(Tokens tokens, SecretKey key) async => _secret.replace(
    jsonEncode({
      'tokens': tokens.toJson(),
      'key': base64Encode(await key.extractBytes()),
    }),
  );
  Future<void> rotate(AccountScope scope, Tokens tokens) => _serial(() async {
    require(scope);
    if (tokens.account != scope.account) throw SessionChanged();
    await _persist(tokens, _key!);
    require(scope);
    _tokens = tokens;
  });
  Future<void> clear() {
    _invalidate();
    return _serial(_wipe);
  }

  Future<bool> _expired(File file) async => !DateTime.now().isBefore(
    (await file.lastModified()).add(const Duration(days: 3)),
  );

  Future<File> _file(CacheKind kind, String id) async {
    final name = await Sha256().hash(utf8.encode('${kind.name}:$id'));
    final suffix = kind == CacheKind.recording ? '.audio' : '';
    return File('${_directory.path}/${base64UrlEncode(name.bytes)}$suffix');
  }

  Future<void> put(
    AccountScope scope,
    CacheKind kind,
    String id,
    List<int> bytes,
  ) => _serial(() async {
    require(scope);
    final file = await _file(kind, id);
    require(scope);
    final box = await _cipher.encrypt(
      bytes,
      secretKey: _key!,
      aad: utf8.encode('${scope.account}:${kind.name}:$id'),
    );
    final tmp = File('${file.path}.new');
    await tmp.writeAsBytes(box.concatenation(), flush: true);
    require(scope);
    await tmp.rename(file.path);
  });
  Future<List<int>?> get(AccountScope scope, CacheKind kind, String id) =>
      _serial(() async {
        require(scope);
        final file = await _file(kind, id);
        if (!await file.exists()) return null;
        if (kind == CacheKind.recording && await _expired(file)) {
          await file.delete();
          return null;
        }
        final box = SecretBox.fromConcatenation(
          await file.readAsBytes(),
          nonceLength: _cipher.nonceLength,
          macLength: _cipher.macAlgorithm.macLength,
        );
        require(scope);
        final bytes = await _cipher.decrypt(
          box,
          secretKey: _key!,
          aad: utf8.encode('${scope.account}:${kind.name}:$id'),
        );
        require(scope);
        return bytes;
      });
  Future<void> remove(AccountScope scope, CacheKind kind, String id) =>
      _serial(() async {
        require(scope);
        final file = await _file(kind, id);
        if (await file.exists()) await file.delete();
      });
}
