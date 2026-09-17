import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models.dart';

class ApiException implements Exception {
  ApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

class OperationCancelled implements Exception {
  const OperationCancelled();

  @override
  String toString() => 'cancelled';
}

class WenxiangApi {
  WenxiangApi({required this.baseUrl, required this.apiKey});

  final String baseUrl;
  final String apiKey;

  Uri _uri(String path, [Map<String, String>? query]) {
    final root = baseUrl.replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$root$path').replace(queryParameters: query);
  }

  Map<String, String> get headers => {
        'Content-Type': 'application/json',
        'X-Wenxiang-Key': apiKey,
        'ngrok-skip-browser-warning': 'true',
      };

  Uri voiceUri() {
    return _voiceWsUri('/v1/voice');
  }

  Uri sttUri() {
    return _voiceWsUri('/v1/voice/stt');
  }

  Uri _voiceWsUri(String path) {
    final root = baseUrl.replaceAll(RegExp(r'/$'), '');
    final ws = root.startsWith('https')
        ? root.replaceFirst(RegExp(r'^https'), 'wss')
        : root.replaceFirst(RegExp(r'^http'), 'ws');
    return Uri.parse('$ws$path').replace(queryParameters: {
      'key': apiKey,
      'ngrok-skip-browser-warning': 'true',
    });
  }

  Map<String, String> get _headers => headers;

  http.Client? _checkoutClient;
  http.Client? _chatClient;
  bool _checkoutCancelled = false;
  bool _chatCancelled = false;

  void cancelCheckout() {
    _checkoutCancelled = true;
    _checkoutClient?.close();
    _checkoutClient = null;
  }

  void cancelChat() {
    _chatCancelled = true;
    _chatClient?.close();
    _chatClient = null;
  }

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
    final res = await http.get(_uri('/health'), headers: _headers).timeout(const Duration(seconds: 8));
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

  Future<CheckoutSyncStatus> checkoutStatus(String owner, String repo) async {
    final res = await http
        .get(_uri('/v1/repos/$owner/$repo/checkout-status'), headers: _headers)
        .timeout(const Duration(seconds: 45));
    final body = await _json(res, fallback: '读取本机仓库状态失败');
    return CheckoutSyncStatus.fromJson(body);
  }

  Future<CheckoutResult> checkout(String owner, String repo) async {
    final client = http.Client();
    _checkoutCancelled = false;
    _checkoutClient = client;
    try {
      final res = await client
          .post(_uri('/v1/repos/$owner/$repo/checkout'), headers: _headers)
          .timeout(const Duration(minutes: 3));
      Map<String, dynamic> body = {};
      if (res.body.isNotEmpty) {
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is Map<String, dynamic>) body = decoded;
        } catch (_) {}
      }
      if (res.statusCode == 499 || body['code'] == 'cancelled') {
        throw const OperationCancelled();
      }
      if (res.statusCode >= 400) {
        throw ApiException((body['error'] ?? '克隆仓库失败').toString());
      }
      final local = body['local'] as Map<String, dynamic>? ?? {};
      final present = local['present'] != false;
      final path = (body['path'] ?? local['path'] ?? '').toString();
      if (!present || path.isEmpty) {
        throw ApiException('仓库没有完整写到本机。请重试。');
      }
      return CheckoutResult(
        path: path,
        branch: (local['branch'] ?? '').toString(),
        head: (local['head'] ?? '').toString(),
      );
    } catch (err) {
      if (_checkoutCancelled || err is OperationCancelled) {
        throw const OperationCancelled();
      }
      rethrow;
    } finally {
      if (identical(_checkoutClient, client)) _checkoutClient = null;
      client.close();
    }
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

  Future<List<ChatSession>> listSessions(String owner, String repo) async {
    final res = await http
        .get(_uri('/v1/repos/$owner/$repo/sessions'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    final body = await _json(res, fallback: '读取会话失败');
    final list = (body['sessions'] as List?) ?? [];
    return list
        .whereType<Map>()
        .map((e) => ChatSession.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ChatSession> createSession(String owner, String repo) async {
    final res = await http
        .post(_uri('/v1/repos/$owner/$repo/sessions'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    final body = await _json(res, fallback: '新建会话失败');
    return ChatSession.fromJson(body);
  }

  Future<void> closeSession(String owner, String repo, String id) async {
    final res = await http
        .delete(_uri('/v1/repos/$owner/$repo/sessions/$id'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    await _json(res, fallback: '关闭会话失败');
  }

  Stream<ChatStreamEvent> chatStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
  }) async* {
    final client = http.Client();
    _chatCancelled = false;
    _chatClient = client;
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
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
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
        if (_chatCancelled) throw const OperationCancelled();
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
    } catch (err) {
      if (_chatCancelled || err is OperationCancelled) {
        throw const OperationCancelled();
      }
      rethrow;
    } finally {
      if (identical(_chatClient, client)) _chatClient = null;
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
