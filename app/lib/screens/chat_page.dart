import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/engine.dart';
import '../copy/errors.dart';
import '../copy/time.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../voice/device_media.dart';
import '../voice/voice_client.dart';
import '../voice/voice_media.dart';
import '../copy/voice_stt_copy.dart';
import '../voice/voice_stt_client.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_hold_to_speak.dart';
import '../widgets/wx_rich_text.dart';
import '../widgets/wx_typewriter_stream.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.api,
    required this.repo,
    required this.onBack,
    this.memory,
    this.voiceMedia,
    this.sttClient,
  });

  final WenxiangApi api;
  final RepoItem repo;
  final VoidCallback onBack;
  final AppMemory? memory;
  final VoiceMedia? voiceMedia;
  final VoiceSttClient? sttClient;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _suggestions = [
    '这个仓库最近在做什么？',
    'README 里怎么写的？',
    '有哪些开放的 PR？',
  ];

  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final Map<String, List<ChatMessage>> _transcripts = {};
  final List<ChatSession> _sessions = [];
  late final WxTypewriterStream _typewriter;
  final ValueNotifier<String?> _liveEngine = ValueNotifier(null);
  final ValueNotifier<String> _livePhase = ValueNotifier('connect');
  Timer? _livePhaseTimer;
  String? _sessionId;
  bool _live = false;
  bool _busy = false;
  int? _editingIndex;
  String? _lastUser;
  bool _voiceReady = false;
  String _voiceHint = '还没配语音密钥。请在本机问象服务的 .env 里配置。';
  bool _voiceInputMode = false;
  bool _holding = false;
  bool _holdPending = false;
  bool _holdCancel = false;
  bool _sttBusy = false;
  String _holdLive = '';
  String _holdHint = '';
  VoiceMedia? _media;
  VoiceSttClient? _stt;
  StreamSubscription<VoiceEvent>? _sttSub;
  StreamSubscription<Uint8List>? _micSub;
  double _holdStartY = 0;
  bool _voiceHoldTipVisible = true;
  bool _userScrolledAwayFromBottom = false;
  bool _pendingNewBelow = false;
  bool _autoFollowing = false;
  bool _preparingChat = true;

  static const _scrollBottomThreshold = 80.0;

  List<ChatMessage> get _messages =>
      _transcripts.putIfAbsent(_sessionId ?? '', () => <ChatMessage>[]);

  ChatSession? get _currentSession {
    if (_sessionId == null) return null;
    for (final session in _sessions) {
      if (session.id == _sessionId) return session;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _typewriter = WxTypewriterStream(
      onReveal: () {
        if (mounted && _live) _jumpToLatest();
      },
    );
    _restoreLocal();
    widget.api
        .warmChatSession(widget.repo.owner, widget.repo.name)
        .catchError((_) {});
    _loadSessions().whenComplete(() {
      if (mounted) setState(() => _preparingChat = false);
    });
    _loadVoice();
    _voiceHoldTipVisible = !(widget.memory?.voiceHoldTipDismissed() ?? false);
    _scroll.addListener(_onScrollPosition);
  }

  void _onScrollPosition() {
    if (!_scroll.hasClients || !mounted || _autoFollowing) return;
    if (_nearBottom && (_userScrolledAwayFromBottom || _pendingNewBelow)) {
      setState(() {
        _userScrolledAwayFromBottom = false;
        _pendingNewBelow = false;
      });
    }
  }

  bool _onChatScrollNotification(ScrollNotification notification) {
    if (_autoFollowing) return false;
    if (notification is ScrollUpdateNotification && notification.dragDetails != null) {
      if (!_nearBottom && !_userScrolledAwayFromBottom) {
        setState(() => _userScrolledAwayFromBottom = true);
      }
    }
    return false;
  }

  void _jumpToLatest({bool force = false}) {
    if (force) {
      _userScrolledAwayFromBottom = false;
      _pendingNewBelow = false;
    } else if (_userScrolledAwayFromBottom || !_nearBottom) {
      if (_live || _busy) {
        if (!_pendingNewBelow) setState(() => _pendingNewBelow = true);
      }
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_scroll.hasClients || !mounted) return;
      _autoFollowing = true;
      try {
        await _scroll.animateTo(
          _scroll.position.maxScrollExtent + _scrollBottomThreshold,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
        );
      } finally {
        _autoFollowing = false;
      }
    });
  }

  Future<void> _loadVoice() async {
    try {
      final status = await widget.api.status();
      if (!mounted) return;
      setState(() {
        _voiceReady = status.voiceReady;
        _voiceHint = status.voiceReady
            ? ''
            : (status.voiceHint.isEmpty ? humanizeSttEvent(code: 'unconfigured') : status.voiceHint);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _voiceReady = false;
        _voiceHint = '连不上问象服务，暂时无法使用语音。请确认电脑上的服务已启动。';
      });
    }
  }

  void _toggleVoiceInput() {
    if (!_voiceReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_voiceHint.isEmpty ? humanizeSttEvent(code: 'unconfigured') : _voiceHint)),
      );
      return;
    }
    if (_busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在生成回答，稍后再用语音')),
      );
      return;
    }
    if (_sttBusy || _holding) return;
    setState(() {
      _voiceInputMode = !_voiceInputMode;
      if (_voiceInputMode) _focus.unfocus();
    });
  }

  Future<void> _beginHold(double globalY) async {
    if (_busy || _sttBusy || _holding || _holdPending || !_voiceReady) return;
    setState(() {
      _holdPending = true;
      _holdStartY = globalY;
      _holdHint = '松开发送，上滑取消';
    });
    final client = widget.sttClient ?? SocketSttClient(widget.api.sttUri());
    _stt = client;
    _sttSub = client.connect().listen(_onSttEvent, onError: (err) => _failStt(humanizeSttConnectionError(err)));
    client.start();
    final media = widget.voiceMedia ?? _media ?? DeviceVoiceMedia();
    _media = media;
    final allowed = await media.requestMic();
    if (!mounted) return;
    if (!allowed) {
      _disposeStt();
      if (mounted) {
        setState(() {
          _holdPending = false;
          _holdHint = '';
        });
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('需要麦克风才能说话')),
      );
      return;
    }
    _micSub = media.startMic().listen(client.sendPcm, onError: (_) {
      _failStt('需要麦克风才能说话');
    });
    HapticFeedback.mediumImpact();
    setState(() {
      _holding = true;
      _holdPending = false;
      _holdCancel = false;
      _holdLive = '';
    });
  }

  void _moveHold(double globalY) {
    if (!_holding && !_holdPending) return;
    final cancel = _holdStartY - globalY > 72;
    if (cancel == _holdCancel) return;
    setState(() {
      _holdCancel = cancel;
      _holdHint = cancel ? '松开取消' : '松开发送，上滑取消';
    });
  }

  Future<void> _endHold() async {
    if (!_holding && !_holdPending && _stt == null) return;
    final cancel = _holdCancel;
    final pendingOnly = _holdPending && _stt == null;
    setState(() {
      _holding = false;
      _holdPending = false;
      _holdCancel = false;
      _holdHint = '';
    });
    if (pendingOnly) {
      setState(() => _holdLive = '');
      return;
    }
    await _micSub?.cancel();
    _micSub = null;
    await _media?.stopMic();
    if (cancel) {
      _stt?.cancel();
      _disposeStt();
      setState(() => _holdLive = '');
      return;
    }
    setState(() {
      _sttBusy = true;
      _holdHint = '识别中…';
    });
    _stt?.stop();
  }

  void _onSttEvent(VoiceEvent event) {
    if (!mounted) return;
    if (event.type == 'error') {
      _failStt(humanizeSttEvent(code: event.code, hint: event.hint));
      if (event.code == 'unconfigured') {
        setState(() {
          _voiceReady = false;
          _voiceHint = humanizeSttEvent(code: 'unconfigured');
        });
      }
      return;
    }
    if (event.type == 'caption' && event.text.isNotEmpty) {
      setState(() => _holdLive = event.text);
    }
    if (event.type == 'done') {
      final text = event.text.trim();
      _disposeStt();
      setState(() {
        _sttBusy = false;
        _holdLive = '';
        _holdHint = '';
      });
      if (text.isNotEmpty) {
        unawaited(_dismissVoiceHoldTip());
        unawaited(_send(text));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(humanizeSttEvent(code: 'empty'))),
        );
      }
    }
    if (event.type == 'cancelled') {
      _disposeStt();
      setState(() {
        _sttBusy = false;
        _holdLive = '';
        _holdHint = '';
      });
    }
  }

  void _failStt(String message) {
    _disposeStt();
    setState(() {
      _sttBusy = false;
      _holding = false;
      _holdLive = '';
      _holdHint = '';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _dismissVoiceHoldTip() async {
    if (!_voiceHoldTipVisible) return;
    setState(() => _voiceHoldTipVisible = false);
    await widget.memory?.dismissVoiceHoldTip();
  }

  void _disposeStt() {
    _sttSub?.cancel();
    _sttSub = null;
    _stt?.dispose();
    _stt = null;
  }

  void _restoreLocal() {
    final stored = widget.memory?.loadChats(widget.repo.fullName);
    if (stored == null || stored.sessions.isEmpty && stored.transcripts.isEmpty) {
      return;
    }
    _sessions
      ..clear()
      ..addAll(stored.sessions);
    _transcripts
      ..clear()
      ..addAll(stored.transcripts.map((key, value) => MapEntry(key, List<ChatMessage>.from(value))));
    _sessionId = stored.activeId ?? (_sessions.isEmpty ? null : _sessions.first.id);
  }

  Future<void> _persist() async {
    final memory = widget.memory;
    if (memory == null) return;
    await memory.saveChats(
      widget.repo.fullName,
      RepoChatStore(
        sessions: List<ChatSession>.from(_sessions),
        activeId: _sessionId,
        transcripts: _transcripts.map((key, value) => MapEntry(key, List<ChatMessage>.from(value))),
      ),
    );
  }

  void _setLivePhase(String phase) {
    if (phase.isEmpty || _livePhase.value == phase) return;
    _livePhase.value = phase;
  }

  void _startLivePhaseFallback() {
    _livePhaseTimer?.cancel();
    final sentAt = DateTime.now();
    _livePhaseTimer = Timer.periodic(const Duration(milliseconds: 900), (timer) {
      if (!mounted || !_live || _typewriter.visible.value.isNotEmpty) {
        timer.cancel();
        return;
      }
      final seconds = DateTime.now().difference(sentAt).inSeconds;
      if (seconds >= 4) {
        _setLivePhase('generate');
      } else if (seconds >= 1.5 && _livePhase.value == 'connect') {
        _setLivePhase('repo');
      }
    });
  }

  void _stopLivePhaseFallback() {
    _livePhaseTimer?.cancel();
    _livePhaseTimer = null;
  }

  Future<void> _refreshCurrentSessionMeta() async {
    final id = _sessionId;
    if (id == null || id.isEmpty) return;
    try {
      final list = await widget.api.listSessions(widget.repo.owner, widget.repo.name);
      if (!mounted) return;
      ChatSession? remote;
      for (final session in list) {
        if (session.id == id) {
          remote = session;
          break;
        }
      }
      if (remote == null) return;
      setState(() {
        final index = _sessions.indexWhere((item) => item.id == id);
        if (index >= 0) {
          _sessions[index] = remote!;
        }
      });
      await _persist();
    } catch (_) {}
  }

  Future<void> _loadSessions() async {
    try {
      var list = await widget.api.listSessions(widget.repo.owner, widget.repo.name);
      if (list.isEmpty && _sessions.isEmpty) {
        final created = await widget.api.createSession(widget.repo.owner, widget.repo.name);
        list = [created];
      }
      if (!mounted) return;
      setState(() {
        final known = {for (final session in _sessions) session.id: session};
        for (final session in list) {
          final prior = known[session.id];
          if (prior == null) {
            _sessions.add(session);
            continue;
          }
          if (prior.title == '新会话' && session.title != '新会话') {
            final index = _sessions.indexWhere((item) => item.id == session.id);
            if (index >= 0) _sessions[index] = session;
          }
        }
        final keep = _sessionId;
        final keepHasTurns = keep != null && (_transcripts[keep]?.isNotEmpty ?? false);
        if (!keepHasTurns && (keep == null || !_sessions.any((session) => session.id == keep))) {
          if (list.isNotEmpty) {
            _sessionId = list.firstWhere((s) => s.active, orElse: () => list.first).id;
          } else if (_sessions.isNotEmpty) {
            _sessionId = _sessions.first.id;
          }
        }
      });
      await _persist();
      _warmAcp();
    } catch (_) {
      // Chat can still send without a sessionId; the server will open an implicit one.
    }
  }

  void _warmAcp() {
    final id = _sessionId;
    widget.api
        .warmChatSession(widget.repo.owner, widget.repo.name, sessionId: id)
        .catchError((_) {});
  }

  Future<void> _newSession() async {
    if (_busy) return;
    try {
      final created = await widget.api.createSession(widget.repo.owner, widget.repo.name);
      if (!mounted) return;
      setState(() {
        _sessions.insert(0, created);
        _sessionId = created.id;
        _transcripts[created.id] = [];
        _live = false;
        _editingIndex = null;
      });
      _typewriter.reset();
      _liveEngine.value = null;
      _livePhase.value = 'connect';
      await _persist();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(humanizeError(err))),
      );
    }
  }

  Future<void> _switchSession(ChatSession session) async {
    if (_busy) return;
    setState(() {
      _sessionId = session.id;
      _live = false;
      _editingIndex = null;
    });
    _typewriter.reset();
    _liveEngine.value = null;
    _livePhase.value = 'connect';
    _persist();
  }

  Future<void> _closeSession(ChatSession session) async {
    try {
      await widget.api.closeSession(widget.repo.owner, widget.repo.name, session.id);
      if (!mounted) return;
      setState(() {
        _sessions.removeWhere((s) => s.id == session.id);
        _transcripts.remove(session.id);
        if (_sessionId == session.id) {
          _sessionId = _sessions.isEmpty ? null : _sessions.first.id;
          _live = false;
        }
      });
      if (_sessionId == null || _sessions.isEmpty) {
        _typewriter.reset();
        _liveEngine.value = null;
      }
      if (_sessions.isEmpty) await _newSession();
      await _persist();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(humanizeError(err))),
      );
    }
  }

  void _rememberSessionId(String? next) {
    if (next == null || next.isEmpty || next == _sessionId) return;
    final old = _sessionId ?? '';
    final prior = _transcripts.remove(old);
    if (prior != null) {
      _transcripts[next] = prior;
    }
    _sessionId = next;
    if (!_sessions.any((s) => s.id == next)) {
      _sessions.insert(
        0,
        ChatSession(
          id: next,
          title: '新会话',
          createdAt: '',
          updatedAt: '',
          active: true,
        ),
      );
    }
  }

  void _beginEdit(int index) {
    if (_busy || _live) return;
    setState(() => _editingIndex = index);
  }

  void _cancelEdit() {
    if (_editingIndex == null) return;
    setState(() => _editingIndex = null);
  }

  Future<void> _commitEdit(int index, String text) async {
    final next = text.trim();
    if (next.isEmpty || _busy) return;
    final prefix = List<ChatMessage>.from(_messages.take(index));
    try {
      final created = await widget.api.createSession(widget.repo.owner, widget.repo.name);
      if (!mounted) return;
      setState(() {
        _editingIndex = null;
        _sessions.insert(0, created);
        _sessionId = created.id;
        _transcripts[created.id] = prefix;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _editingIndex = null;
        _messages
          ..clear()
          ..addAll(prefix);
      });
    }
    await _persist();
    await _send(next);
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    _editingIndex = null;
    _input.clear();
    _lastUser = text;
    HapticFeedback.selectionClick();
    _typewriter.reset();
    _liveEngine.value = null;
    _livePhase.value = 'connect';
    _startLivePhaseFallback();
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _live = true;
      _busy = true;
    });
    _jumpToLatest(force: true);

    final history = _messages.where((m) => m.role != 'error').toList();
    var firstDelta = true;

    try {
      await for (final event in widget.api.chatStream(
        owner: widget.repo.owner,
        repo: widget.repo.name,
        message: text,
        sessionId: _sessionId,
        history: history,
      )) {
        if (!mounted) return;
        if (event.sessionId != null && event.sessionId!.isNotEmpty) {
          _rememberSessionId(event.sessionId);
        }
        if (event.type == 'status' && event.phase != null && event.phase!.isNotEmpty) {
          _setLivePhase(event.phase!);
        } else if (event.type == 'delta' && event.text.isNotEmpty) {
          if (firstDelta) {
            firstDelta = false;
            HapticFeedback.lightImpact();
          }
          _typewriter.push(event.text);
        } else if (event.type == 'start' && event.engine != null) {
          _liveEngine.value = event.engine;
          _setLivePhase('repo');
        } else if (event.type == 'done') {
          _liveEngine.value = event.engine ?? _liveEngine.value;
          if (event.text.isNotEmpty && _typewriter.fullText.isEmpty) {
            _typewriter.push(event.text);
          }
        } else if (event.type == 'error') {
          throw ApiException(event.error ?? '问答失败');
        }
      }
      if (!mounted) return;
      await _typewriter.animateToEnd();
      if (!mounted) return;
      final answer = _typewriter.fullText;
      setState(() {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: answer,
          engine: _liveEngine.value,
        ));
        _live = false;
      });
      _typewriter.reset();
      await _persist();
      unawaited(_refreshCurrentSessionMeta());
    } on OperationCancelled {
      if (!mounted) return;
      _typewriter.flushNow();
      final partial = _typewriter.fullText;
      setState(() {
        if (partial.isNotEmpty) {
          _messages.add(ChatMessage(
            role: 'assistant',
            content: partial,
            engine: _liveEngine.value,
          ));
        }
        _live = false;
      });
      _typewriter.reset();
      await _persist();
    } catch (err) {
      if (!mounted) return;
      _typewriter.flushNow();
      final partial = _typewriter.fullText;
      final shown = humanizeError(err);
      setState(() {
        if (partial.isEmpty) {
          _messages.add(ChatMessage(role: 'error', content: shown));
        } else {
          _messages.add(ChatMessage(
            role: 'assistant',
            content: partial,
            engine: _liveEngine.value,
          ));
          _messages.add(ChatMessage(role: 'error', content: shown));
        }
        _live = false;
      });
      _typewriter.reset();
      await _persist();
    } finally {
      _stopLivePhaseFallback();
      if (mounted) {
        setState(() {
          _busy = false;
          _live = false;
        });
      }
      _jumpToLatest();
    }
  }

  void _stop() {
    if (!_busy) return;
    widget.api.cancelChat();
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    return pos.pixels >= pos.maxScrollExtent - _scrollBottomThreshold;
  }

  Future<void> _openSessions() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Wx.surface,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 20),
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 3,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Wx.hairline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text('历史会话', style: Theme.of(context).textTheme.titleMedium),
                      ),
                      TextButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                Navigator.pop(context);
                                await _newSession();
                              },
                        icon: const Icon(Icons.add_comment_outlined, size: 18),
                        label: const Text('新建'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const WxHairline(),
                  const SizedBox(height: 8),
                  if (_sessions.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                      child: Text('还没有会话', style: Theme.of(context).textTheme.bodyMedium),
                    ),
                  for (final session in _sessions)
                    _SessionRow(
                      session: session,
                      selected: session.id == _sessionId,
                      onOpen: () {
                        Navigator.pop(context);
                        _switchSession(session);
                      },
                      onClose: _busy
                          ? null
                          : () async {
                              await _closeSession(session);
                              setSheet(() {});
                            },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
    if (_busy) widget.api.cancelChat();
    _disposeStt();
    _micSub?.cancel();
    _media?.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.removeListener(_onScrollPosition);
    _scroll.dispose();
    _stopLivePhaseFallback();
    _typewriter.dispose();
    _liveEngine.dispose();
    _livePhase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _currentSession;
    final subtitle = session == null || session.title.isEmpty || session.title == '新会话'
        ? ''
        : session.title;
    final itemCount = _messages.length + (_live ? 1 : 0);
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
          WxPageHeader(
            onBack: () {
              _stop();
              widget.onBack();
            },
            backTooltip: '返回仓库',
            title: widget.repo.fullName,
            subtitle: subtitle,
            trailing: [
              IconButton(
                tooltip: '新建会话',
                onPressed: _busy || _preparingChat ? null : _newSession,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: '历史会话',
                onPressed: _preparingChat ? null : _openSessions,
                icon: const Icon(Icons.history),
              ),
            ],
          ),
          const WxHairline(),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                itemCount == 0
                    ? _EmptyChat(
                        onPick: _busy || _preparingChat ? null : _send,
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: _onChatScrollNotification,
                        child: ListView.builder(
                          key: const Key('wx-chat-list'),
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(Wx.inset, 20, Wx.inset, 16),
                          itemCount: itemCount,
                          itemBuilder: (context, index) {
                      if (index < _messages.length) {
                        final message = _messages[index];
                        return _FinishedTurn(
                          key: ValueKey('m-$index-${message.role}'),
                          message: message,
                          editing: _editingIndex == index,
                          onEdit: message.role == 'user' && !_busy && !_live
                              ? () => _beginEdit(index)
                              : null,
                          onCancelEdit: _cancelEdit,
                          onSubmitEdit: (text) => _commitEdit(index, text),
                          onRetry: message.role == 'error' && _lastUser != null && !_busy
                              ? () => _send(_lastUser)
                              : null,
                        );
                      }
                      return _LiveTurn(
                        text: _typewriter.visible,
                        engine: _liveEngine,
                        phase: _livePhase,
                      );
                    },
                        ),
                      ),
                if (_pendingNewBelow && itemCount > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 10,
                    child: Center(
                      child: _NewMessagesPill(onTap: () => _jumpToLatest(force: true)),
                    ),
                  ),
              ],
            ),
          ),
          const WxHairline(),
          _Composer(
            controller: _input,
            focus: _focus,
            busy: _busy,
            preparing: _preparingChat,
            voiceReady: _voiceReady,
            voiceInputMode: _voiceInputMode,
            holding: _holding || _holdPending,
            holdCancel: _holdCancel,
            sttBusy: _sttBusy,
            holdLive: _holdLive,
            holdHint: _holdHint,
            voiceHoldTipVisible: _voiceHoldTipVisible,
            onToggleVoiceInput: _toggleVoiceInput,
            onHoldStart: _beginHold,
            onHoldMove: _moveHold,
            onHoldEnd: _endHold,
            onSend: _send,
            onStop: _stop,
          ),
            ],
          ),
          if (_preparingChat)
            const ColoredBox(
              color: Color(0x990C0D0F),
              child: Center(
                child: WxBusy(label: '正在准备对话…'),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onPick});
  final void Function(String text)? onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Wx.inset, 36, Wx.inset, 16),
      children: [
        Text('从进度问起。', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          '有本机 Agent 就直接问；没有则用本地进度。不编造。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 28),
        for (final q in _ChatPageState._suggestions)
          _SuggestRow(label: q, onTap: onPick == null ? null : () => onPick!(q)),
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.selected,
    required this.onOpen,
    this.onClose,
  });

  final ChatSession session;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final title = session.title.isEmpty ? '新会话' : session.title;
    final when = formatRelativeTime(session.updatedAt.isNotEmpty ? session.updatedAt : session.createdAt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? Wx.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        if (when.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(when, style: Theme.of(context).textTheme.labelSmall),
                        ],
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭会话',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SuggestRow extends StatelessWidget {
  const _SuggestRow({required this.label, required this.onTap});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Wx.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
                  ),
                  const Icon(Icons.north_east, size: 16, color: Wx.faint),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditableUserTurn extends StatefulWidget {
  const _EditableUserTurn({
    required this.message,
    required this.editing,
    this.onEdit,
    this.onCancel,
    this.onSubmit,
  });

  final ChatMessage message;
  final bool editing;
  final VoidCallback? onEdit;
  final VoidCallback? onCancel;
  final Future<void> Function(String text)? onSubmit;

  @override
  State<_EditableUserTurn> createState() => _EditableUserTurnState();
}

class _EditableUserTurnState extends State<_EditableUserTurn> {
  late final TextEditingController _edit = TextEditingController(text: widget.message.content);

  @override
  void didUpdateWidget(covariant _EditableUserTurn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.editing && !oldWidget.editing) {
      _edit.text = widget.message.content;
      _edit.selection = TextSelection.fromPosition(TextPosition(offset: _edit.text.length));
    }
  }

  @override
  void dispose() {
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _VoiceTurn(
      voice: '你问',
      voiceColor: Wx.accent,
      railColor: Wx.accent,
      railWidth: 3,
      bottom: 20,
      trailing: widget.editing || widget.onEdit == null
          ? null
          : IconButton(
              tooltip: '编辑',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onEdit,
              icon: const Icon(Icons.edit_outlined, size: 18),
            ),
      child: widget.editing
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('wx-edit-field'),
                  controller: _edit,
                  minLines: 1,
                  maxLines: 8,
                  autofocus: true,
                  textInputAction: TextInputAction.newline,
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Wx.surface,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(onPressed: widget.onCancel, child: const Text('取消')),
                    const Spacer(),
                    FilledButton(
                      onPressed: () => widget.onSubmit?.call(_edit.text),
                      child: const Text('发送'),
                    ),
                  ],
                ),
              ],
            )
          : SelectableText(
              widget.message.content,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Wx.text,
                    height: 1.5,
                  ),
            ),
    );
  }
}

class _FinishedTurn extends StatelessWidget {
  const _FinishedTurn({
    super.key,
    required this.message,
    this.editing = false,
    this.onEdit,
    this.onCancelEdit,
    this.onSubmitEdit,
    this.onRetry,
  });
  final ChatMessage message;
  final bool editing;
  final VoidCallback? onEdit;
  final VoidCallback? onCancelEdit;
  final Future<void> Function(String text)? onSubmitEdit;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (message.role == 'user') {
      return _EditableUserTurn(
        message: message,
        editing: editing,
        onEdit: onEdit,
        onCancel: onCancelEdit,
        onSubmit: onSubmitEdit,
      );
    }
    if (message.role == 'error') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: WxErrorPanel(
          error: message.content,
          onRetry: onRetry,
          retryLabel: '重试上一问',
        ),
      );
    }
    return _VoiceTurn(
      voice: '问象',
      voiceColor: Wx.text,
      railColor: Wx.hairline,
      railWidth: 2,
      bottom: 32,
      footer: engineFootnote(message.engine).isEmpty
          ? null
          : Text(
              engineFootnote(message.engine),
              style: Theme.of(context).textTheme.labelSmall,
            ),
      child: GestureDetector(
        onLongPress: () async {
          await Clipboard.setData(ClipboardData(text: message.content));
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已复制回答')),
          );
        },
        child: WxReadableText(message.content),
      ),
    );
  }
}

String _livePhaseLabel(String phase) {
  switch (phase) {
    case 'repo':
      return '读仓库、整理上下文…';
    case 'generate':
      return '生成回答…';
    case 'connect':
    default:
      return '连接 Agent…';
  }
}

class _LiveTurn extends StatelessWidget {
  const _LiveTurn({
    required this.text,
    required this.engine,
    required this.phase,
  });
  final ValueNotifier<String> text;
  final ValueNotifier<String?> engine;
  final ValueNotifier<String> phase;

  @override
  Widget build(BuildContext context) {
    return _VoiceTurn(
      voice: '问象',
      voiceColor: Wx.text,
      railColor: Wx.hairline,
      railWidth: 2,
      bottom: 32,
      footer: ValueListenableBuilder<String?>(
        valueListenable: engine,
        builder: (context, value, _) {
          final label = engineFootnote(value);
          if (label.isEmpty) return const SizedBox.shrink();
          return Text(
            label,
            style: Theme.of(context).textTheme.labelSmall,
          );
        },
      ),
      child: ValueListenableBuilder<String>(
        valueListenable: text,
        builder: (context, value, _) {
          if (value.isEmpty) {
            return ValueListenableBuilder<String>(
              valueListenable: phase,
              builder: (context, livePhase, _) {
                return Semantics(
                  liveRegion: true,
                  child: Row(
                    children: [
                      Text(
                        _livePhaseLabel(livePhase),
                        style: const TextStyle(color: Wx.muted, fontSize: 16, height: 1.55),
                      ),
                      const SizedBox(width: 8),
                      const _Caret(),
                    ],
                  ),
                );
              },
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: WxReadableText(value)),
              const Padding(
                padding: EdgeInsets.only(left: 2, bottom: 3),
                child: _Caret(),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _VoiceTurn extends StatelessWidget {
  const _VoiceTurn({
    required this.voice,
    required this.voiceColor,
    required this.railColor,
    required this.railWidth,
    required this.child,
    this.footer,
    this.trailing,
    this.bottom = 24,
  });

  final String voice;
  final Color voiceColor;
  final Color railColor;
  final double railWidth;
  final Widget child;
  final Widget? footer;
  final Widget? trailing;
  final double bottom;

  @override
  Widget build(BuildContext context) {
    final ask = voice == '你问';
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ColoredBox(
              color: railColor,
              child: SizedBox(width: railWidth),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          voice,
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                color: voiceColor,
                                fontSize: ask ? 12 : 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: ask ? 0.4 : 0.8,
                              ),
                        ),
                      ),
                      if (trailing != null) trailing!,
                    ],
                  ),
                  const SizedBox(height: 8),
                  child,
                  if (footer != null) ...[
                    const SizedBox(height: 10),
                    footer!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Caret extends StatefulWidget {
  const _Caret();

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 2,
        height: 15,
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: Wx.accent,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.busy,
    this.preparing = false,
    required this.voiceReady,
    required this.voiceInputMode,
    required this.holding,
    required this.holdCancel,
    required this.sttBusy,
    required this.holdLive,
    required this.holdHint,
    required this.voiceHoldTipVisible,
    required this.onToggleVoiceInput,
    required this.onHoldStart,
    required this.onHoldMove,
    required this.onHoldEnd,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final bool preparing;
  final bool voiceReady;
  final bool voiceInputMode;
  final bool holding;
  final bool holdCancel;
  final bool sttBusy;
  final String holdLive;
  final String holdHint;
  final bool voiceHoldTipVisible;
  final VoidCallback onToggleVoiceInput;
  final Future<void> Function(double globalY) onHoldStart;
  final void Function(double globalY) onHoldMove;
  final Future<void> Function() onHoldEnd;
  final Future<void> Function() onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final voiceLocked = busy || preparing || sttBusy;
    final inputLocked = busy || preparing;
    return ColoredBox(
      color: Wx.bg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Wx.inset, 10, 12, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if ((holding || sttBusy) && holdLive.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: WxHoldLiveChip(
                    text: holdLive,
                    recognizing: sttBusy,
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    key: const Key('wx-voice-toggle'),
                    tooltip: !voiceReady
                        ? '语音未配置'
                        : busy
                            ? '生成中，暂不可用'
                            : (voiceInputMode ? '键盘输入' : '按住说话'),
                    onPressed: voiceLocked && voiceReady ? null : onToggleVoiceInput,
                    icon: Icon(
                      voiceInputMode ? Icons.keyboard_outlined : Icons.mic_none_outlined,
                      color: !voiceReady ? Wx.faint : null,
                    ),
                  ),
                  Expanded(
                    child: voiceInputMode
                        ? WxHoldToSpeakPad(
                            enabled: voiceReady && !voiceLocked,
                            holding: holding,
                            holdCancel: holdCancel,
                            sttBusy: sttBusy,
                            hint: !voiceReady
                                ? '语音未就绪'
                                : busy
                                    ? '生成中，稍后再说'
                                    : holdHint.isNotEmpty
                                        ? holdHint
                                        : (sttBusy ? '识别中…' : '按住 说话'),
                            onHoldStart: onHoldStart,
                            onHoldMove: onHoldMove,
                            onHoldEnd: onHoldEnd,
                          )
                        : TextField(
                            controller: controller,
                            focusNode: focus,
                            minLines: 1,
                            maxLines: 6,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) {
                              if (!inputLocked) onSend();
                            },
                            enabled: !preparing,
                            decoration: InputDecoration(
                              hintText: preparing
                                  ? '正在准备对话…'
                                  : busy
                                      ? '生成中，可先写下一条'
                                      : '问进度，像在 Cursor 里一样',
                              filled: true,
                              fillColor: Wx.surface,
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: Wx.tap,
                    height: Wx.tap,
                    child: busy
                        ? IconButton(
                            tooltip: '停止',
                            onPressed: onStop,
                            icon: const Icon(Icons.stop_circle_outlined, size: 26, color: Wx.accent),
                          )
                        : IconButton.filled(
                            tooltip: '发送',
                            onPressed: voiceInputMode || preparing ? null : onSend,
                            icon: const Icon(Icons.arrow_upward, size: 20),
                          ),
                  ),
                ],
              ),
              if (voiceInputMode &&
                  voiceReady &&
                  voiceHoldTipVisible &&
                  !holding &&
                  !sttBusy &&
                  !busy &&
                  !preparing &&
                  holdHint.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '松手自动发送，上滑取消',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Wx.faint,
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewMessagesPill extends StatelessWidget {
  const _NewMessagesPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Wx.raised,
      elevation: 0,
      shadowColor: Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          key: const Key('wx-new-messages-pill'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Wx.hairline),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '新消息',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Wx.text,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.south, size: 16, color: Wx.accent),
            ],
          ),
        ),
      ),
    );
  }
}
