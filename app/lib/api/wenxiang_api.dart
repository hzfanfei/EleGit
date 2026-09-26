import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../copy/ask_engine.dart';
import '../models.dart';
import '../models/diagnostics.dart';
import '../utils/async_gate.dart';
import '../voice/background_work.dart';

bool chatEventHasVisibleText(ChatStreamEvent event) {
  if (event.pcm != null && event.pcm!.isNotEmpty) return true;
  if (event.text.isEmpty) return false;
  return event.type == 'delta' || event.type == 'done' || event.type == 'caption';
}

Duration chatStreamRetryDelay(int failures) {
  switch (failures) {
    case 1:
      return const Duration(seconds: 2);
    case 2:
      return const Duration(seconds: 4);
    default:
      return const Duration(seconds: 6);
  }
}

bool shouldRetryChatStreamBeforeText({
  required bool sawText,
  required int failures,
  required bool cancelled,
  required Object error,
}) {
  if (cancelled || error is OperationCancelled) return false;
  if (error is ApiException) return false;
  if (sawText) return false;
  return failures < 4;
}

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

  /// Headers for authenticated GETs (e.g. book markdown images).
  Map<String, String> get assetHeaders => {
        'X-Wenxiang-Key': apiKey,
        'ngrok-skip-browser-warning': 'true',
      };

  Uri bookAssetUri(String bookId, String cacheRelativePath) {
    return _uri('/v1/books/$bookId/asset', {'path': cacheRelativePath});
  }

  Future<Uint8List> fetchBookAssetBytes(String bookId, String cacheRelativePath) {
    return bookAssetGate.run(() {
      return retryTransient(() => _getAssetBytes(bookAssetUri(bookId, cacheRelativePath)));
    });
  }

  Future<Uint8List> fetchBookAssetBytesFromCandidates(
    String bookId,
    Iterable<String> cacheRelativePaths,
  ) {
    return bookAssetGate.run(() {
      return retryTransient(() async {
        Object? last;
        for (final path in cacheRelativePaths) {
          final trimmed = path.trim();
          if (trimmed.isEmpty) continue;
          try {
            return await _getAssetBytes(bookAssetUri(bookId, trimmed));
          } catch (err) {
            last = err;
          }
        }
        throw last ?? ApiException('图片加载失败');
      });
    });
  }

  Future<Uint8List> fetchUrlBytes(Uri uri) {
    return bookAssetGate.run(() {
      return retryTransient(() => _getAssetBytes(uri));
    });
  }

  Future<Uint8List> _getAssetBytes(Uri uri) async {
    final res = await http.get(uri, headers: assetHeaders).timeout(const Duration(seconds: 20));
    final type = res.headers['content-type'] ?? '';
    if (res.statusCode >= 400 || res.bodyBytes.isEmpty || type.contains('text/html')) {
      final html = type.contains('text/html') ? ' html interstitial' : '';
      throw ApiException('图片加载失败 HTTP ${res.statusCode}$html');
    }
    return res.bodyBytes;
  }

  http.Client? _checkoutClient;
  http.Client? _chatClient;
  http.Client? _bookVoiceClient;
  http.Client? _repoVoiceClient;
  bool _checkoutCancelled = false;
  bool _chatCancelled = false;
  bool _bookVoiceCancelled = false;
  bool _repoVoiceCancelled = false;

  void cancelCheckout() {
    _checkoutCancelled = true;
    _checkoutClient?.close();
    _checkoutClient = null;
  }

  void cancelChat({String? sessionId}) {
    _chatCancelled = true;
    _chatClient?.close();
    _chatClient = null;
    final id = sessionId?.trim() ?? '';
    if (id.isEmpty) return;
    unawaited(_postChatCancel(id));
  }

  Future<void> replyInteraction({
    required String sessionId,
    required String requestId,
    required String kind,
    bool accept = false,
    bool skip = false,
    List<Map<String, dynamic>> answers = const [],
  }) async {
    final res = await http
        .post(
          _uri('/v1/chat/interact'),
          headers: _headers,
          body: jsonEncode({
            'sessionId': sessionId,
            'requestId': requestId,
            'kind': kind,
            'accept': accept,
            'skip': skip,
            'answers': answers,
          }),
        )
        .timeout(const Duration(seconds: 20));
    _json(res, fallback: '提交选择失败');
  }

  Future<void> _postChatCancel(String sessionId) async {
    try {
      await http
          .post(
            _uri('/v1/chat/cancel'),
            headers: _headers,
            body: jsonEncode({'sessionId': sessionId}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  void cancelBookVoiceTurn() {
    _bookVoiceCancelled = true;
    _bookVoiceClient?.close();
    _bookVoiceClient = null;
  }

  void cancelRepoVoiceTurn() {
    _repoVoiceCancelled = true;
    _repoVoiceClient?.close();
    _repoVoiceClient = null;
  }

  Future<Map<String, dynamic>> _json(
    http.Response res, {
    required String fallback,
  }) async {
    Map<String, dynamic> body = {};
    if (res.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {
        if (res.statusCode >= 400) {
          throw ApiException('$fallback（HTTP ${res.statusCode}）');
        }
      }
    }
    if (res.statusCode >= 400) {
      throw ApiException((body['error'] ?? fallback).toString());
    }
    return body;
  }

  Future<List<String>> uploadClientLogs(
    List<Map<String, dynamic>> entries, {
    String app = 'wenxiang',
    String platform = '',
  }) async {
    if (entries.isEmpty) return const [];
    final res = await http
        .post(
          _uri('/v1/client-logs'),
          headers: _headers,
          body: jsonEncode({
            'app': app,
            'platform': platform,
            'entries': entries,
          }),
        )
        .timeout(const Duration(seconds: 12));
    final body = await _json(res, fallback: '上传错误日志失败');
    final accepted = body['accepted'];
    if (accepted is! List) return const [];
    return [for (final id in accepted) id.toString()];
  }

  Future<void> ping() async {
    final res = await http.get(_uri('/health'), headers: _headers).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw ApiException('无法连接问象服务（HTTP ${res.statusCode}）');
    }
    if (apiKey.trim().isEmpty) {
      throw ApiException(
        'App 未配置 API Key。请在仓库根目录运行 node scripts/sync-app-env.js 后重新编译 App。',
      );
    }
  }

  Future<void> setTtsVoice(String ttsVoice) async {
    final res = await http
        .put(
          _uri('/v1/voice/tts-voice'),
          headers: _headers,
          body: jsonEncode({'ttsVoice': ttsVoice}),
        )
        .timeout(const Duration(seconds: 12));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '保存音色失败');
    }
  }

  /// Synthesizes a short preview phrase for [ttsVoice]; PCM at 24 kHz unless header says otherwise.
  Future<TtsVoicePreview> previewTtsVoice(String ttsVoice, {String? text}) async {
    final res = await http
        .post(
          _uri('/v1/voice/tts-preview'),
          headers: _headers,
          body: jsonEncode({
            'ttsVoice': ttsVoice,
            if (text != null && text.isNotEmpty) 'text': text,
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '音色试听失败');
    }
    final rateHeader = res.headers['x-sample-rate'];
    final sampleRate = int.tryParse(rateHeader ?? '') ?? 24000;
    return TtsVoicePreview(pcm: res.bodyBytes, sampleRate: sampleRate);
  }

  Future<DiagnosticsProbeResult> runDiagnosticsProbe({String? ttsVoice}) async {
    final res = await http
        .post(
          _uri('/v1/diagnostics/probe'),
          headers: _headers,
          body: jsonEncode({
            if (ttsVoice != null && ttsVoice.isNotEmpty) 'ttsVoice': ttsVoice,
          }),
        )
        .timeout(const Duration(minutes: 3));
    final body = await _json(res, fallback: '通路检测失败');
    return DiagnosticsProbeResult.fromJson(body);
  }

  Future<void> setVoiceStack(String stack) async {
    final res = await http
        .put(
          _uri('/v1/settings/voice-stack'),
          headers: _headers,
          body: jsonEncode({'stack': stack}),
        )
        .timeout(const Duration(seconds: 90));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '保存语音引擎失败');
    }
  }

  Future<void> setAskEngine(String engine, {required AskEngineScope scope}) async {
    final res = await http
        .put(
          _uri('/v1/settings/ask-engine'),
          headers: _headers,
          body: jsonEncode({'engine': engine, 'scope': askEngineScopeId(scope)}),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '保存问答方式失败');
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
    await BackgroundWork.acquire();
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
      await BackgroundWork.release();
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

  Future<List<RepoItem>> localRepos(String query) async {
    final res = await http
        .get(_uri('/v1/repos/local', {'q': query}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    final body = await _json(res, fallback: '读取本机仓库失败');
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

  /// Pre-start Cursor ACP for this repo so the first chat token arrives sooner.
  Uri bookCoverUri(String bookId) => _uri('/v1/books/$bookId/cover');

  Future<StaticLibrary> listStaticFiles() async {
    final res = await http
        .get(_uri('/v1/static'), headers: _headers)
        .timeout(const Duration(seconds: 25));
    final body = await _json(res, fallback: '读取静态资源失败');
    final list = (body['files'] as List?) ?? [];
    return StaticLibrary(
      dir: (body['dir'] ?? '').toString(),
      files: list
          .whereType<Map>()
          .map((e) => StaticFileItem.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }

  Future<void> deleteStaticFile(String path) async {
    final res = await http
        .delete(_uri('/v1/static', {'path': path}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    await _json(res, fallback: '删除资源失败');
  }

  Future<List<BookItem>> listBooks() async {
    final res = await http
        .get(_uri('/v1/books'), headers: _headers)
        .timeout(const Duration(seconds: 25));
    final body = await _json(res, fallback: '读取书单失败');
    final list = (body['books'] as List?) ?? [];
    return list
        .whereType<Map>()
        .map((e) => BookItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<List<ChatSession>> listBookSessions(String bookId) async {
    final res = await http
        .get(_uri('/v1/books/$bookId/sessions'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    final body = await _json(res, fallback: '读取书籍会话失败');
    final list = (body['sessions'] as List?) ?? [];
    return list
        .whereType<Map>()
        .map((e) => ChatSession.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<ChatSession> createBookSession(String bookId) async {
    final res = await http
        .post(_uri('/v1/books/$bookId/sessions'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    final body = await _json(res, fallback: '新建书籍会话失败');
    return ChatSession.fromJson(body);
  }

  Future<void> closeBookSession(String bookId, String id) async {
    final res = await http
        .delete(_uri('/v1/books/$bookId/sessions/$id'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    await _json(res, fallback: '关闭书籍会话失败');
  }

  Future<BookReadingManifest> fetchBookReadingManifest(String bookId) async {
    final res = await http
        .get(_uri('/v1/books/$bookId/reading'), headers: _headers)
        .timeout(const Duration(seconds: 60));
    final body = await _json(res, fallback: '加载书籍目录失败');
    return BookReadingManifest.fromJson(Map<String, dynamic>.from(body));
  }

  Future<String> fetchBookChapterMarkdown(String bookId, String filename) async {
    final safe = Uri.encodeComponent(filename);
    final res = await http
        .get(_uri('/v1/books/$bookId/chapters/$safe'), headers: _headers)
        .timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '加载章节失败');
    }
    return res.body;
  }

  Future<void> warmBookSession(String bookId, {String? sessionId}) async {
    final res = await http
        .post(
          _uri('/v1/books/$bookId/sessions/warm'),
          headers: _headers,
          body: jsonEncode({
            if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '书籍预热失败');
    }
  }

  Stream<ChatStreamEvent> bookVoiceTurnStream({
    required String bookId,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? chapter,
    String? ttsVoice,
  }) {
    _bookVoiceCancelled = false;
    return _retryBeforeVisible(
      () => _bookVoiceTurnOnce(
        bookId: bookId,
        message: message,
        history: history,
        sessionId: sessionId,
        chapter: chapter,
        ttsVoice: ttsVoice,
      ),
      cancelled: () => _bookVoiceCancelled,
    );
  }

  Stream<ChatStreamEvent> _bookVoiceTurnOnce({
    required String bookId,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? chapter,
    String? ttsVoice,
  }) async* {
    final client = http.Client();
    _bookVoiceClient = client;
    try {
      final request = http.Request('POST', _uri('/v1/books/voice-turn'))
        ..headers.addAll({
          ..._headers,
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode({
          'bookId': bookId,
          'message': message,
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          if (chapter != null && chapter.isNotEmpty) 'chapter': chapter,
          if (ttsVoice != null && ttsVoice.isNotEmpty) 'ttsVoice': ttsVoice,
          'history': history
              .map((m) => {'role': m.role, 'content': m.content})
              .toList(),
        });
      final res = await client.send(request).timeout(const Duration(seconds: 25));
      if (res.statusCode >= 400) {
        final raw = await res.stream.bytesToString();
        String error = '快问快答失败';
        try {
          error = (jsonDecode(raw)['error'] ?? error).toString();
        } catch (_) {}
        throw ApiException(error);
      }
      var buffer = '';
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        if (_bookVoiceCancelled) throw const OperationCancelled();
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
      if (_bookVoiceCancelled || err is OperationCancelled) {
        throw const OperationCancelled();
      }
      rethrow;
    } finally {
      if (identical(_bookVoiceClient, client)) _bookVoiceClient = null;
      client.close();
    }
  }

  Stream<ChatStreamEvent> repoVoiceTurnStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? ttsVoice,
    bool agentMode = false,
  }) {
    _repoVoiceCancelled = false;
    return _retryBeforeVisible(
      () => _repoVoiceTurnOnce(
        owner: owner,
        repo: repo,
        message: message,
        history: history,
        sessionId: sessionId,
        ttsVoice: ttsVoice,
        agentMode: agentMode,
      ),
      cancelled: () => _repoVoiceCancelled,
    );
  }

  Stream<ChatStreamEvent> _repoVoiceTurnOnce({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? ttsVoice,
    bool agentMode = false,
  }) async* {
    final client = http.Client();
    _repoVoiceClient = client;
    try {
      final request = http.Request('POST', _uri('/v1/chat/voice-turn'))
        ..headers.addAll({
          ..._headers,
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode({
          'owner': owner,
          'repo': repo,
          'message': message,
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          if (ttsVoice != null && ttsVoice.isNotEmpty) 'ttsVoice': ttsVoice,
          if (agentMode) 'agentMode': true,
          'history': history
              .map((m) => {'role': m.role, 'content': m.content})
              .toList(),
        });
      final res = await client.send(request).timeout(const Duration(seconds: 25));
      if (res.statusCode >= 400) {
        final raw = await res.stream.bytesToString();
        String error = '快问快答失败';
        try {
          error = (jsonDecode(raw)['error'] ?? error).toString();
        } catch (_) {}
        throw ApiException(error);
      }
      var buffer = '';
      await for (final chunk in res.stream.transform(utf8.decoder)) {
        if (_repoVoiceCancelled) throw const OperationCancelled();
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
      if (_repoVoiceCancelled || err is OperationCancelled) {
        throw const OperationCancelled();
      }
      rethrow;
    } finally {
      if (identical(_repoVoiceClient, client)) _repoVoiceClient = null;
      client.close();
    }
  }

  Stream<ChatStreamEvent> bookChatStream({
    required String bookId,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? chapter,
  }) {
    _chatCancelled = false;
    return _retryBeforeVisible(
      () => _bookChatStreamOnce(
        bookId: bookId,
        message: message,
        history: history,
        sessionId: sessionId,
        chapter: chapter,
      ),
      cancelled: () => _chatCancelled,
    );
  }

  Stream<ChatStreamEvent> _bookChatStreamOnce({
    required String bookId,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? chapter,
  }) async* {
    final client = http.Client();
    _chatClient = client;
    try {
      final request = http.Request('POST', _uri('/v1/books/chat'))
        ..headers.addAll({
          ..._headers,
          'Accept': 'text/event-stream',
        })
        ..body = jsonEncode({
          'bookId': bookId,
          'message': message,
          if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          if (chapter != null && chapter.isNotEmpty) 'chapter': chapter,
          'history': history
              .map((m) => {'role': m.role, 'content': m.content})
              .toList(),
        });
      final res = await client.send(request).timeout(const Duration(seconds: 25));
      if (res.statusCode >= 400) {
        final raw = await res.stream.bytesToString();
        String error = '问书失败';
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

  Future<void> warmChatSession(
    String owner,
    String repo, {
    String? sessionId,
  }) async {
    final res = await http
        .post(
          _uri('/v1/repos/$owner/$repo/sessions/warm'),
          headers: _headers,
          body: jsonEncode({
            if (sessionId != null && sessionId.isNotEmpty) 'sessionId': sessionId,
          }),
        )
        .timeout(const Duration(seconds: 45));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '预热失败');
    }
  }

  Stream<ChatStreamEvent> _retryBeforeVisible(
    Stream<ChatStreamEvent> Function() open, {
    required bool Function() cancelled,
  }) async* {
    await BackgroundWork.acquire();
    try {
      var failures = 0;
      while (true) {
        var sawText = false;
        try {
          await for (final event in open()) {
            if (chatEventHasVisibleText(event)) sawText = true;
            yield event;
          }
          return;
        } catch (err) {
          failures += 1;
          if (!shouldRetryChatStreamBeforeText(
            sawText: sawText,
            failures: failures,
            cancelled: cancelled(),
            error: err,
          )) {
            if (cancelled() || err is OperationCancelled) {
              throw const OperationCancelled();
            }
            rethrow;
          }
          await _waitToRetry(chatStreamRetryDelay(failures), cancelled);
        }
      }
    } finally {
      await BackgroundWork.release();
    }
  }

  Future<void> _waitToRetry(Duration total, bool Function() cancelled) async {
    const slice = Duration(milliseconds: 200);
    var left = total;
    while (left > Duration.zero) {
      if (cancelled()) throw const OperationCancelled();
      final step = left < slice ? left : slice;
      await Future<void>.delayed(step);
      left -= step;
    }
  }

  Stream<ChatStreamEvent> chatStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    bool agentMode = false,
  }) {
    _chatCancelled = false;
    return _retryBeforeVisible(
      () => _chatStreamOnce(
        owner: owner,
        repo: repo,
        message: message,
        history: history,
        sessionId: sessionId,
        agentMode: agentMode,
      ),
      cancelled: () => _chatCancelled,
    );
  }

  Stream<ChatStreamEvent> _chatStreamOnce({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    bool agentMode = false,
  }) async* {
    final client = http.Client();
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
          if (agentMode) 'agentMode': true,
          'history': history
              .map((m) => {'role': m.role, 'content': m.content})
              .toList(),
        });
      final res = await client.send(request).timeout(const Duration(seconds: 25));
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

  Future<void> reportPresence(String state) async {
    try {
      await http
          .post(
            _uri('/v1/presence'),
            headers: _headers,
            body: jsonEncode({'state': state}),
          )
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  Future<Map<String, dynamic>> fetchInbox() async {
    final res = await http
        .get(_uri('/v1/inbox'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    return _json(res, fallback: '读取通知中心失败');
  }

  Future<void> markInboxRead(String id) async {
    final res = await http
        .post(_uri('/v1/inbox/${Uri.encodeComponent(id)}/read'), headers: _headers)
        .timeout(const Duration(seconds: 12));
    if (res.statusCode >= 400) {
      await _json(res, fallback: '标记通知已读失败');
    }
  }
}

class TtsVoicePreview {
  const TtsVoicePreview({required this.pcm, required this.sampleRate});

  final Uint8List pcm;
  final int sampleRate;
}
