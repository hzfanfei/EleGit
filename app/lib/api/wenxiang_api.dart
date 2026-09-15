import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

class WenxiangApi {
  WenxiangApi({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  Uri _uri(String path, [Map<String, String>? query]) {
    final root = baseUrl.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$root$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-Wenxiang-Key': apiKey,
      };

  Future<Map<String, dynamic>> _json(
    http.Response res, {
    required String fallback,
  }) async {
    Map<String, dynamic> body = {};
    if (res.body.isNotEmpty) {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    }
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] ?? fallback).toString());
    }
    return body;
  }

  Future<void> ping() async {
    final res = await http.get(_uri('/health')).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw ApiException('无法连接问象服务（HTTP ${res.statusCode}）');
    }
  }

  Future<ServerStatus> status() async {
    final res = await http
        .get(_uri('/v1/status'), headers: _headers)
        .timeout(const Duration(seconds: 12));
    final body = await _json(res, fallback: '读取状态失败');
    return ServerStatus.fromJson(body);
  }

  Future<OAuthStart> startOAuth() async {
    final res = await http
        .post(
          _uri('/v1/github/oauth/start'),
          headers: _headers,
          body: jsonEncode({'publicBaseUrl': baseUrl}),
        )
        .timeout(const Duration(seconds: 20));
    final body = await _json(res, fallback: '无法开始浏览器登录');
    return OAuthStart(
      state: (body['state'] ?? '').toString(),
      authorizeUrl: (body['authorizeUrl'] ?? '').toString(),
      redirectUri: (body['redirectUri'] ?? '').toString(),
    );
  }

  Future<bool> pollOAuth(String state) async {
    final res = await http
        .get(_uri('/v1/github/oauth/status', {'state': state}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    final body = await _json(res, fallback: '登录尚未完成');
    if ((body['status'] ?? '') == 'error') {
      throw ApiException((body['error'] ?? 'GitHub 登录失败').toString());
    }
    return body['connected'] == true;
  }

  Future<CheckoutResult> checkout(String owner, String repo) async {
    final res = await http
        .post(_uri('/v1/repos/$owner/$repo/checkout'), headers: _headers)
        .timeout(const Duration(minutes: 3));
    final body = await _json(res, fallback: '克隆仓库失败');
    final local = body['local'] as Map<String, dynamic>? ?? {};
    return CheckoutResult(
      path: (body['path'] ?? local['path'] ?? '').toString(),
      branch: (local['branch'] ?? '').toString(),
      head: (local['head'] ?? '').toString(),
    );
  }

  Future<ServerStatus> savePat(String token) async {
    final res = await http
        .post(
          _uri('/v1/github/pat'),
          headers: _headers,
          body: jsonEncode({'token': token}),
        )
        .timeout(const Duration(seconds: 20));
    await _json(res, fallback: 'GitHub PAT 无效');
    return status();
  }

  Future<DeviceStart> startDevice() async {
    final res = await http
        .post(_uri('/v1/github/device/start'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    final body = await _json(res, fallback: '无法开始设备码登录');
    return DeviceStart(
      deviceCode: (body['deviceCode'] ?? '').toString(),
      userCode: (body['userCode'] ?? '').toString(),
      verificationUri: (body['verificationUri'] ?? '').toString(),
      interval: (body['interval'] as num?)?.toInt() ?? 5,
    );
  }

  Future<bool> pollDevice(String deviceCode) async {
    final res = await http
        .get(
          _uri('/v1/github/device/poll', {'device_code': deviceCode}),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 202) return false;
    await _json(res, fallback: '设备码尚未完成');
    return true;
  }

  Future<void> disconnectGithub() async {
    final res = await http
        .delete(_uri('/v1/github/session'), headers: _headers)
        .timeout(const Duration(seconds: 12));
    await _json(res, fallback: '断开失败');
  }

  Future<List<RepoItem>> repos(String query) async {
    final res = await http
        .get(_uri('/v1/repos', {'q': query}), headers: _headers)
        .timeout(const Duration(seconds: 25));
    final body = await _json(res, fallback: '拉取仓库失败');
    final list = (body['repos'] as List?) ?? [];
    return list
        .whereType<Map>()
        .map((e) => RepoItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Stream<ChatStreamEvent> chatStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
  }) async* {
    final client = http.Client();
    try {
      final request = http.Request('POST', _uri('/v1/chat'))
        ..headers.addAll({
          ..._headers,
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode({
          'owner': owner,
          'repo': repo,
          'message': message,
          'history': history
              .map((m) => {'role': m.role, 'content': m.content})
              .toList(),
        });
      final res = await client.send(request).timeout(const Duration(minutes: 4));
      if (res.statusCode >= 400) {
        final raw = await res.stream.bytesToString();
        String error = '问答失败';
        try {
          error = (jsonDecode(raw)['error'] ?? error).toString();
        } catch (_) {}
        throw ApiException(error);
      }
      var buffer = '';
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        buffer += chunk;
        final parts = buffer.split('\n\n');
        buffer = parts.removeLast();
        for (final part in parts) {
          final event = ChatStreamEvent.fromSse(part);
          if (event != null) yield event;
        }
      }
      if (buffer.trim().isNotEmpty) {
        final event = ChatStreamEvent.fromSse(buffer);
        if (event != null) yield event;
      }
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> startTunnel() async {
    final res = await http
        .post(_uri('/v1/tunnel/start'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    return _json(res, fallback: '启动隧道失败');
  }

  Future<Map<String, dynamic>> stopTunnel() async {
    final res = await http
        .post(_uri('/v1/tunnel/stop'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    return _json(res, fallback: '停止隧道失败');
  }
}
