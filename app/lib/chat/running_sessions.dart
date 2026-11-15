import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/wenxiang_api.dart';
import '../copy/errors.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../persist/chat_backfill.dart';
import '../utils/notification_center.dart';
import '../voice/background_work.dart';

/// Owns executions independently of routes. Each API connection has its own pool.
class RunningSessions extends ChangeNotifier {
  RunningSessions._(this.api);
  static final _pools = Expando<RunningSessions>();
  static final _testPools = <RunningSessions>[];
  static RunningSessions of(WenxiangApi api) {
    if (_pools[api] case final existing?) return existing;
    final pool = RunningSessions._(api);
    _pools[api] = pool;
    assert(() {
      _testPools.add(pool);
      return true;
    }());
    return pool;
  }

  @visibleForTesting
  static void stopAllForTesting() {
    for (final pool in _testPools) {
      pool.stopAll();
    }
    _testPools.clear();
  }

  final WenxiangApi api;
  final Map<String, RunningRepo> _repos = {};
  final Map<String, SessionExecution> _executions = {};

  RunningRepo repo(RepoItem repo, AppMemory? memory) =>
      _repos.putIfAbsent(repo.fullName, () => RunningRepo(repo, memory));

  SessionExecution? execution(String? id) => _executions[id];
  List<SessionExecution> get active =>
      _executions.values.toSet().where((task) => task.busy).toList();

  SessionExecution session(RunningRepo repo, String id, bool agentMode) {
    final task = _executions.putIfAbsent(
        id, () => SessionExecution(this, repo, id, agentMode));
    if (!task.busy) task.agentMode = agentMode;
    return task;
  }

  void changed() => notifyListeners();

  @visibleForTesting
  void stopAll() {
    for (final execution in _executions.values) {
      execution.stop();
    }
  }
}

class RunningRepo {
  RunningRepo(this.repo, this.memory) {
    final saved = memory?.loadChats(repo.fullName);
    sessions.addAll(saved?.sessions ?? []);
    transcripts.addAll(saved?.transcripts ?? {});
    activeId = saved?.activeId;
  }

  final RepoItem repo;
  final AppMemory? memory;
  final List<ChatSession> sessions = [];
  final Map<String, List<ChatMessage>> transcripts = {};
  String? activeId;

  Future<void> persist() async {
    await memory?.saveChats(
        repo.fullName,
        RepoChatStore(
          sessions: sessions,
          activeId: activeId,
          transcripts: transcripts,
        ));
  }
}

class SessionExecution {
  SessionExecution(this.pool, this.repo, this.sessionId, this.agentMode);

  final RunningSessions pool;
  final RunningRepo repo;
  String sessionId;
  bool agentMode;
  final List<ChatMessage> queued = [];
  ChatMessage? current;
  bool busy = false;
  bool stopped = false;
  bool holding = false;
  bool pollOk = true;
  String text = '';
  String activity = '';
  String phase = 'connect';
  String? engine;
  ChatStreamEvent? decision;
  Timer? _pollTimer;
  Timer? _holdTimeout;
  Completer<void>? _pollWait;
  StreamSubscription<ChatStreamEvent>? _subscription;
  Completer<void>? _streamDone;

  List<ChatMessage> get messages =>
      repo.transcripts.putIfAbsent(sessionId, () => []);
  String get title => current?.content ?? '会话';
  int? get userIndex => current == null ? null : messages.indexOf(current!);
  List<int> get queuedIndices =>
      queued.map(messages.indexOf).where((i) => i >= 0).toList();

  void enqueue(ChatMessage message) {
    queued.add(message);
    if (!busy) {
      busy = true;
      stopped = false;
      unawaited(_drain());
    }
    pool.changed();
  }

  void stop() {
    if (!busy) return;
    stopped = true;
    _holdTimeout?.cancel();
    queued.clear();
    pool.api.cancelChat(sessionId: sessionId);
    unawaited(_subscription?.cancel().catchError((Object _) {}));
    _completeStream();
    _wakePoll();
    pool.changed();
  }

  void _completeStream() {
    final done = _streamDone;
    if (done != null && !done.isCompleted) done.complete();
  }

  void _wakePoll() {
    _pollTimer?.cancel();
    final wait = _pollWait;
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  Future<void> _drain() async {
    await BackgroundWork.acquire();
    try {
      while (queued.isNotEmpty && !stopped) {
        current = queued.removeAt(0);
        text = '';
        activity = '';
        phase = 'connect';
        holding = false;
        decision = null;
        engine = null;
        pool.changed();
        try {
          await _run();
        } catch (error) {
          recordClientError(error, kind: 'chat');
          messages.add(ChatMessage(role: 'error', content: error.toString()));
        }
        final answer = stripTaskMarker(text);
        final at = messages.indexOf(current!);
        if (at >= 0 &&
            answer.isNotEmpty &&
            insertTurnAnswer(messages, at, answer)) {
          // Preserve the engine label on the answer stored for this turn.
          final reply =
              messages.skip(at + 1).firstWhere((m) => m.role == 'assistant');
          reply.engine = engine;
        }
        await repo.persist();
      }
    } finally {
      busy = false;
      holding = false;
      current = null;
      decision = null;
      text = '';
      pool.changed();
      await BackgroundWork.release();
    }
  }

  Future<void> _run() async {
    var accepted = false;
    var finished = false;
    Object? failure;
    final at = messages.indexOf(current!);
    final done = Completer<void>();
    _streamDone = done;
    _subscription = pool.api
        .chatStream(
      owner: repo.repo.owner,
      repo: repo.repo.name,
      message: current!.content.trim().isEmpty ? '请看附图。' : current!.content,
      history: messages.take(at + 1).where((m) => m.role != 'error').toList(),
      sessionId: sessionId,
      agentMode: agentMode,
      turnId: current!.turnId,
      images: current!.images,
    )
        .listen((event) {
      if (stopped) return;
      accepted = true;
      final id = event.sessionId;
      if (id != null && id.isNotEmpty && id != sessionId) {
        final transcript = repo.transcripts.remove(sessionId);
        sessionId = id;
        if (transcript != null) repo.transcripts[id] = transcript;
        pool._executions[id] = this;
      }
      if (event.engine != null) engine = event.engine;
      switch (event.type) {
        case 'delta':
          text += event.text;
        case 'done':
          if (event.text.isNotEmpty) text = event.text;
          finished = true;
          activity = '';
        case 'status':
          if (event.phase == 'activity' ||
              (event.detail?.isNotEmpty ?? false)) {
            activity = event.detail ?? '';
          }
          if (event.phase != null && event.phase != 'activity')
            phase = event.phase!;
        case 'start':
          phase = 'repo';
        case 'ask':
        case 'plan':
          decision = event;
        case 'error':
          failure = ApiException(event.error ?? '问答失败');
      }
      pool.changed();
    }, onError: (Object error) {
      failure = error;
      _completeStream();
    }, onDone: _completeStream);
    await done.future;
    _subscription = null;
    _streamDone = null;
    if (stopped) return;
    final cause = failure is AcceptedChatDrop
        ? (failure as AcceptedChatDrop).cause
        : failure;
    if (!finished &&
        (failure is AcceptedChatDrop ||
            (accepted && (failure == null || isChatTransportDrop(cause!))))) {
      await _hold();
    } else if (failure != null) {
      recordClientError(failure!, kind: 'chat');
      messages.add(ChatMessage(role: 'error', content: failure.toString()));
    }
  }

  Future<void> _hold() async {
    holding = true;
    phase = 'hold';
    var expired = false;
    _holdTimeout = Timer(const Duration(minutes: 12), () {
      expired = true;
      _wakePoll();
    });
    pool.changed();
    try {
      while (!stopped && !expired) {
        try {
          final response = await pool.api.fetchInbox();
          if (stopped) return;
          pollOk = true;
          final rows = ((response['items'] as List?) ?? [])
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList();
          final row = pickHeldInboxItem(rows, turnId: current!.turnId ?? '');
          if (row != null) {
            activity = (row['activity'] ?? '').toString();
            final answer = (row['answer'] ?? '').toString();
            if (answer.isNotEmpty) text = answer;
            if (row['partial'] != true && answer.isNotEmpty) {
              await NotificationCenter.instance.notifyPolledFinish(row);
              return;
            }
          }
          final saved = repo.memory?.loadChats(repo.repo.fullName);
          final answer = answerAfterTurn(
              saved?.transcripts[sessionId] ?? [], current!.turnId ?? '');
          if (answer != null) {
            text = answer;
            return;
          }
        } catch (_) {
          pollOk = false;
        }
        pool.changed();
        _pollWait = Completer<void>();
        _pollTimer = Timer(const Duration(milliseconds: 400), _wakePoll);
        await _pollWait!.future;
      }
    } finally {
      _holdTimeout?.cancel();
      _pollTimer?.cancel();
    }
  }
}
