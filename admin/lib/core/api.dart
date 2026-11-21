import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

final apiProvider = Provider<AdminApi>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return AdminApi(client, Uri.base);
});

class ApiFailure implements Exception {
  const ApiFailure(this.status, this.message);
  final int status;
  final String message;
}

class Session {
  const Session(this.token, this.role, this.expires);
  final String token, role;
  final DateTime expires;
  bool get canAudit => role == 'super_admin';
}

class AdminApi {
  AdminApi(this.client, this.origin);
  final http.Client client;
  final Uri origin;
  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    String? token,
    Map<String, String>? query,
    Map<String, String>? body,
  }) async {
    final uri = origin
        .resolve('/admin/v1/$path')
        .replace(queryParameters: query);
    final req = http.Request(method, uri);
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    try {
      final response = await client
          .send(req)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw ApiFailure(response.statusCode, switch (response.statusCode) {
          400 => '请检查输入后重试',
          401 => '凭据无效或会话已过期，请重新登录',
          403 => '当前角色无权执行此操作',
          _ => '服务暂不可用，请稍后重试',
        });
      }
      return jsonDecode(utf8.decode(response.bodyBytes))
          as Map<String, dynamic>;
    } on TimeoutException {
      throw const ApiFailure(0, '连接超时，请重试');
    } on http.ClientException {
      throw const ApiFailure(0, '无法连接后台，请检查网络');
    }
  }

  Future<Session> login(String name, String password) async {
    final data = await _request(
      'POST',
      'auth/login',
      body: {'login': name, 'password': password},
    );
    final role = data['role'];
    if (role != 'operator' && role != 'super_admin') {
      throw const ApiFailure(0, '无法识别管理员角色');
    }
    return Session(
      data['access_token'] as String,
      role as String,
      DateTime.parse(data['expires_at'] as String),
    );
  }

  Future<void> logout(String token) async {
    await _request('POST', 'auth/logout', token: token);
  }

  Future<Map<String, dynamic>> audit(
    String token,
    Map<String, String> filters,
  ) => _request('GET', 'audit-logs', token: token, query: filters);
}
