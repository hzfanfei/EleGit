import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'wenxiang_api.dart';
import 'link_quality.dart';
import '../chat/chat_image.dart';
import '../copy/ask_engine.dart';
import '../models.dart';
import '../utils/notification_center.dart';

/// An in-memory project backed by prefixed disposable workspace directories.
/// The ordinary ChatPage owns all interaction; no second chat UI or queue.
class TemporaryProjectApi extends WenxiangApi {
  TemporaryProjectApi(this.source)
      : super(baseUrl: source.baseUrl, apiKey: source.apiKey) {
    source.linkEpoch.addListener(_linkChanged);
  }
  final WenxiangApi source;
  final sessions = <String, ChatSession>{};
  final _images = <String, Uint8List>{};
  final _cancelled = <String>{};
  final _activeTurns = <String, String>{};
  final _preferences = <String, Map<String, dynamic>>{};
  String? activeId, model;
  bool _closed = false;
  Timer? _heartbeat;
  bool _beating = false;

  @override
  bool get ephemeral => true;
  void _linkChanged() {
    baseUrl = source.baseUrl;
    linkEpoch.value++;
  }

  @override
  Future<ServerStatus> status() => source.status();
  @override
  Future<HealthProbeResult> probeHealth(
          {Duration timeout = const Duration(seconds: 5)}) =>
      source.probeHealth(timeout: timeout);
  @override
  Future<Map<String, dynamic>> codexUsage() => source.codexUsage();
  @override
  Uri sttUri() => source.sttUri();
  @override
  Uri voiceUri() {
    final uri = source.voiceUri();
    return uri.replace(queryParameters: {
      ...uri.queryParameters,
      if (activeId != null) 'temporary': activeId!
    });
  }

  @override
  Future<List<ChatSession>> listSessions(String owner, String repo) async =>
      sessions.values.toList().reversed.toList();
  @override
  Future<ChatSession> createSession(String owner, String repo) async {
    if (_closed) throw const OperationCancelled();
    final id = await source.createTemporaryChat();
    if (_closed) {
      await source.closeTemporaryChat(id);
      throw const OperationCancelled();
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final session = ChatSession(
        id: id, title: '新会话', createdAt: now, updatedAt: now, active: true);
    sessions[id] = session;
    activeId = id;
    _heartbeat ??=
        Timer.periodic(const Duration(minutes: 1), (_) => unawaited(_ping()));
    return session;
  }

  Future<void> _ping() async {
    if (_beating || _closed) return;
    _beating = true;
    try {
      await Future.wait(sessions.keys
          .toList()
          .map((id) => source.pingTemporaryChat(id).catchError((_) {})));
    } finally {
      _beating = false;
    }
  }

  @override
  Future<void> closeSession(String owner, String repo, String id) async {
    _cancelled.add(id);
    sessions.remove(id);
    await source.closeTemporaryChat(id);
    await NotificationCenter.instance.clearTemporaryFinish(id);
    if (activeId == id) activeId = sessions.keys.lastOrNull;
  }

  @override
  Future<void> warmChatSession(String owner, String repo,
      {String? sessionId}) async {
    if (sessionId != null && sessions.containsKey(sessionId)) {
      activeId = sessionId;
    }
  }

  Map<String, dynamic> options(bool agentMode) =>
      {'model': model, ...?_preferences[model], 'agentMode': agentMode};
  @override
  Future<void> prepareVoiceChatSession(
      {String? sessionId, bool agentMode = false}) async {
    activeId = sessionId ?? activeId;
    if (activeId != null) {
      await source.temporaryChatRequest(activeId!,
          method: 'PUT', suffix: '/options', body: options(agentMode));
    }
  }

  @override
  Future<ChatImageAttachment> uploadChatImage(
      {required Uint8List bytes, required String mimeType}) async {
    final id = 'temporary-image-${mintTurnId()}';
    _images[id] = bytes;
    ChatImageCache.put(id, bytes);
    return ChatImageAttachment(id: id, mimeType: mimeType);
  }

  @override
  Future<Uint8List> fetchChatImage(String id) async =>
      _images[id] ?? Uint8List(0);

  @override
  Future<Map<String, dynamic>> codexModels() async {
    final data = await source.codexModels();
    model ??= (data['scopes'] as Map?)?['repo']?['model']?.toString() ??
        (data['models'] as List?)?.firstOrNull?['id']?.toString();
    return {
      ...data,
      'scopes': {
        'repo': {'model': model, 'preferences': _preferences}
      }
    };
  }

  @override
  Future<void> setCodexModel(String model,
      {required AskEngineScope scope,
      String? effort,
      bool? fast,
      bool select = true}) async {
    if (select) this.model = model;
    _preferences[model] = {
      ...?_preferences[model],
      if (effort != null) 'effort': effort,
      if (fast != null) 'fast': fast
    };
  }

  @override
  Future<Map<String, dynamic>> measureModelSpeed(AskEngineScope scope) async {
    final id = activeId;
    if (id == null) throw ApiException('临时项目尚未准备好');
    final result = await source.temporaryChatRequest(id,
        method: 'POST', suffix: '/speed', body: options(false));
    return {...result, 'elapsedMs': result['totalMs']};
  }

  @override
  Stream<ChatStreamEvent> chatStream(
      {required String owner,
      required String repo,
      required String message,
      required List<ChatMessage> history,
      String? sessionId,
      bool agentMode = false,
      String? turnId,
      List<ChatImageAttachment> images = const []}) async* {
    final id = sessionId ?? activeId;
    if (id == null || _closed) return;
    activeId = id;
    _cancelled.remove(id);
    final requestId = turnId ?? mintTurnId();
    _activeTurns[id] = requestId;
    final body = {
      'id': requestId,
      'message': message,
      ...options(agentMode),
      'images': [
        for (final image in images)
          if (_images[image.id] != null)
            'data:${image.mimeType};base64,${base64Encode(_images[image.id]!)}'
      ],
      'history': [
        for (final m in history.take(history.isEmpty ? 0 : history.length - 1))
          if (m.role != 'error') {'role': m.role, 'content': m.content}
      ],
    };
    Map<String, dynamic>? data;
    // Reuse requestId when the POST response was lost, so work is never duplicated.
    for (var attempt = 0;
        attempt < 3 && !_closed && !_cancelled.contains(id);
        attempt++) {
      try {
        data = await source.temporaryChatRequest(id,
            method: 'POST', suffix: '/messages', body: body);
        break;
      } on ApiException {
        rethrow;
      } catch (_) {
        if (attempt == 2) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    if (data == null) return;
    yield ChatStreamEvent(type: 'start', sessionId: id, engine: 'codex');
    var watchedId = requestId,
        shown = '',
        prefix = '',
        lastActivity = '',
        decisionId = '';
    var failures = 0;
    while (!_closed &&
        !_cancelled.contains(id) &&
        sessions.containsKey(id) &&
        _activeTurns[id] == watchedId) {
      if (data != null) {
        final turns = (data['turns'] as List? ?? []).whereType<Map>();
        var turn = turns.where((t) => t['id'] == watchedId).firstOrNull;
        if (turn != null) {
          final nextId = turn['continuationId']?.toString();
          if (nextId != null) {
            prefix += '${turn['answer']}\n\n';
            watchedId = nextId;
            _activeTurns[id] = watchedId;
            turn = turns.where((t) => t['id'] == watchedId).firstOrNull;
          }
          if (turn != null) {
            final text = prefix + (turn['answer']?.toString() ?? '');
            if (text.startsWith(shown) && text.length > shown.length) {
              yield ChatStreamEvent(
                  type: 'delta', text: text.substring(shown.length));
            }
            shown = text;
            final activity = _activity(turn);
            if (activity != lastActivity) {
              lastActivity = activity;
              yield ChatStreamEvent(
                  type: 'status', phase: 'activity', detail: activity);
            }
            final decision = turn['decision'] as Map?;
            if (decision != null && decisionId != decision['requestId']) {
              decisionId = '${decision['requestId']}';
              yield ChatStreamEvent(
                  type: '${decision['type']}',
                  sessionId: id,
                  payload: Map<String, dynamic>.from(decision));
            }
            if (decision == null &&
                ['completed', 'failed', 'stopped'].contains(turn['status'])) {
              if (turn['error'] != null) {
                yield ChatStreamEvent(type: 'error', error: '${turn['error']}');
              }
              final answer = linkFiles(shown, id, data);
              final prior = sessions[id];
              if (prior != null) {
                sessions[id] = ChatSession(
                    id: id,
                    title: message.isEmpty ? '图片提问' : message,
                    createdAt: prior.createdAt,
                    updatedAt: DateTime.now().toUtc().toIso8601String(),
                    active: true);
              }
              yield ChatStreamEvent(
                  type: 'done', sessionId: id, text: answer, engine: 'codex');
              return;
            }
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (_closed || _cancelled.contains(id)) return;
      try {
        data = await source.temporaryChatRequest(id);
        failures = 0;
      } on ApiException {
        rethrow;
      } catch (_) {
        data = null;
        failures++;
        yield ChatStreamEvent(
            type: 'status', phase: 'hold', detail: '正在恢复连接，本机任务继续运行…');
        if (failures >= 600) throw ApiException('连接中断时间过长，请重新打开临时会话');
      }
    }
  }

  String _activity(Map turn) {
    final steps = (turn['steps'] as List? ?? []).whereType<Map>().toList();
    if (steps.isEmpty) return '${turn['activity'] ?? '正在回答…'}';
    return steps.take(100).map((s) {
      final age = (((s['finishedAt'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch) -
              ((s['startedAt'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch)) ~/
          1000;
      final command = s['title'] == '执行命令';
      return '${command ? '跑脚本' : s['title']}\n${s['detail'] ?? ''}\n${s['output'] ?? ''}${command ? '\n已跑 $age 秒' : ''}';
    }).join('\n\n');
  }

  String linkFiles(String text, String id, Map snapshot) =>
      text.replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^\s)]+)\)'), (match) {
        final raw = match[2]!;
        final uri = Uri.tryParse(raw);
        if (uri == null ||
            uri.hasScheme && !['file', 'sandbox'].contains(uri.scheme)) {
          return match[0]!;
        }
        final relative = Uri.decodeComponent(uri.path).replaceAll('\\', '/');
        final files = (snapshot['files'] as List? ?? [])
            .whereType<Map>();
        final file = files.where((file) {
          final path = '${file['path']}';
          return relative == path || relative.endsWith('/$path');
        }).firstOrNull;
        if (file == null) return match[0]!;
        final onlineUrl = file['downloadUrl'] as String?;
        final url = onlineUrl ??
            source.temporaryFileUri(id, '${file['path']}', '${snapshot['downloadKey']}').toString();
        return '[${match[1]}]($url)';
      });

  @override
  void cancelChat({String? sessionId, String? turnId}) {
    final id = sessionId ?? activeId;
    if (id == null) return;
    _cancelled.add(id);
    final target = _activeTurns.remove(id) ?? turnId;
    unawaited(source.temporaryChatRequest(id,
        method: 'POST',
        suffix: '/stop',
        body: {
          if (target != null) 'turnId': target
        }).catchError((_) => <String, dynamic>{}));
  }

  @override
  Future<void> replyInteraction(
      {required String sessionId,
      required String requestId,
      required String kind,
      bool accept = false,
      bool skip = false,
      List<Map<String, dynamic>> answers = const []}) async {
    await source.temporaryChatRequest(sessionId,
        method: 'POST',
        suffix: '/decision',
        body: {
          'requestId': requestId,
          'accept': accept,
          'skip': skip,
          'answers': answers
        });
  }

  @override
  Stream<ChatStreamEvent> repoVoiceTurnStream(
      {required String owner,
      required String repo,
      required String message,
      required List<ChatMessage> history,
      String? sessionId,
      String? ttsVoice,
      bool agentMode = false}) async* {
    await prepareVoiceChatSession(sessionId: sessionId, agentMode: agentMode);
    final id = activeId;
    if (id == null) return;
    await for (final event in source.temporaryVoiceStream(id, message)) {
      if (event.type == 'done') {
        final snapshot = await source.temporaryChatRequest(id);
        yield ChatStreamEvent(
            type: 'done',
            sessionId: id,
            engine: event.engine,
            text: linkFiles(event.text, id, snapshot));
      } else {
        yield event;
      }
    }
  }

  @override
  void cancelRepoVoiceTurn() => source.cancelTemporaryVoice();
  @override
  Future<String?> finalChatAnswer({
    required String sessionId,
    required String turnId,
  }) async {
    final snapshot = await source.temporaryChatRequest(sessionId);
    final turns = {
      for (final turn in (snapshot['turns'] as List? ?? const []).whereType<Map>())
        turn['id']: turn,
    };
    final visited = <Object?>{};
    final answer = StringBuffer();
    var turn = turns[turnId];
    while (turn != null && visited.add(turn['id'])) {
      final text = turn['answer']?.toString().trim() ?? '';
      if (text.isNotEmpty) {
        if (answer.isNotEmpty) answer.write('\n\n');
        answer.write(text);
      }
      final next = turn['continuationId'];
      if (next == null) {
        return turn['status'] == 'completed' && answer.isNotEmpty
            ? linkFiles(answer.toString(), sessionId, snapshot)
            : null;
      }
      turn = turns[next];
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> fetchInbox() async => {'items': []};

  Future<void> closeProject() async {
    if (_closed) return;
    _closed = true;
    _heartbeat?.cancel();
    source.linkEpoch.removeListener(_linkChanged);
    cancelRepoVoiceTurn();
    for (final id in _images.keys) {
      ChatImageCache.remove(id);
    }
    _images.clear();
    _preferences.clear();
    _activeTurns.clear();
    final ids = sessions.keys.toList();
    sessions.clear();
    await Future.wait(ids.map((id) async {
      await source.closeTemporaryChat(id);
      await NotificationCenter.instance.clearTemporaryFinish(id);
    }));
  }
}
