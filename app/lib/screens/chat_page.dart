import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/wenxiang_api.dart';
import '../chat/chat_image.dart';
import '../chat/running_sessions.dart';
import 'running_sessions_page.dart';
import '../copy/engine.dart';
import '../copy/ask_engine.dart';
import '../copy/errors.dart';
import '../copy/time.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../persist/chat_backfill.dart';
import '../persist/turn_answers.dart' show mergeFinalTurnAnswer;
import '../persist/book_reader_prefs.dart';
import '../theme.dart';
import '../voice/device_media.dart';
import '../voice/repo_quick_voice_session.dart';
import '../voice/volc_tts_voices.dart';
import '../voice/voice_client.dart';
import '../voice/voice_media.dart';
import '../copy/voice_stt_copy.dart';
import '../voice/voice_stt_client.dart';
import '../widgets/book_quick_voice_fab.dart';
import '../widgets/wx_chat_markdown_stream.dart';
import '../widgets/agent_decision_card.dart';
import '../widgets/agent_details_dialog.dart';
import '../widgets/chat_image_strip.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_running_more_icon.dart';
import '../widgets/wx_motion.dart';
import '../widgets/wx_link_route.dart';
import '../widgets/wx_hold_to_speak.dart';
import '../widgets/wx_rich_text.dart';
import '../widgets/wx_speak_answer.dart';
import '../widgets/wx_typewriter_stream.dart';
import 'call_page.dart';

/// Mic sits this far above the system inset, clear of the 64px composer
/// (8 + 48 + 8). The list keeps the same gap so the last line is not under the button.
const _kChatFabLift = 92.0;
const _kChatComposerBody = 64.0;
const _kChatDraftStrip = 84.0;
const _kChatListBottomInset =
    _kChatFabLift + kQuickVoiceFabBottomPad + kQuickVoiceMicSize - _kChatComposerBody + 8;

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.api,
    required this.repo,
    required this.onBack,
    this.memory,
    this.initialSessionId,
    this.voiceMedia,
    this.sttClient,
    this.callMedia,
    this.callClient,
    this.openAnswerLink,
    this.temporary = false,
    this.onOpenFiles,
  });

  final WenxiangApi api;
  final RepoItem repo;
  final VoidCallback onBack;
  final AppMemory? memory;
  final String? initialSessionId;
  final VoiceMedia? voiceMedia;
  final VoiceSttClient? sttClient;
  final VoiceMedia? callMedia;
  final VoiceCallClient? callClient;

  /// When set, used instead of the system browser. Tests record the tapped URL.
  final Future<bool> Function(Uri uri)? openAnswerLink;
  final bool temporary;
  final VoidCallback? onOpenFiles;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const _quickVoicePalette = ReaderPalette(
    paper: Wx.raised,
    ink: Wx.text,
    muted: Wx.muted,
    chromeFade: Wx.bg,
  );

  static const _suggestions = [
    '这个仓库最近在做什么？',
    'README 里怎么写的？',
    '有哪些开放的 PR？',
  ];

  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController(keepScrollOffset: false);
  late final RunningSessions _running;
  late final RunningRepo _repoState;
  Map<String, List<ChatMessage>> get _transcripts => _repoState.transcripts;
  List<ChatSession> get _sessions => _repoState.sessions;
  SessionExecution? get _execution => _running.execution(_sessionId);
  SessionExecution? _shownExecution;
  String? _shownTurnId;
  int _shownMessageCount = 0;
  int _shownQueueCount = 0;
  late final WxTypewriterStream _typewriter;
  final ValueNotifier<String?> _liveEngine = ValueNotifier(null);
  final ValueNotifier<String> _livePhase = ValueNotifier('connect');
  final ValueNotifier<String> _liveActivity = ValueNotifier('');
  /// Hold inbox poll: yellow = last poll ok, red = last poll failed.
  final ValueNotifier<bool> _holdPollOk = ValueNotifier(true);
  Timer? _streamScrollTimer;
  double _lastFollowExtent = -1;
  String? _sessionId;
  bool _live = false;
  bool _busy = false;
  int? _processingUserIndex;
  bool _agentMode = false;
  Map<String, dynamic>? _codexUsage;
  bool _usageLoading = false;
  Timer? _usageTimer;
  ChatStreamEvent? _decision;
  ChatMessage? _appearingQuestion;
  ChatMessage? _editingMessage;
  final _sessionViews = <String, _SessionView>{};
  _SessionView get _sessionView =>
      _sessionViews.putIfAbsent(_sessionId ?? '', _SessionView.new);
  List<_DraftImage> get _draftImages => _sessionView.images;
  final _checkingResults = <ChatMessage>{};
  bool get _readingImages => _sessionView.readingImages;
  bool get _uploadingImages => _sessionView.uploadingImages;
  bool _voiceReady = false;
  bool _voiceCall = false;
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
  bool _restoringScroll = false;
  int _scrollEpoch = 0;
  bool _preparingChat = true;
  bool _creatingSession = false;
  bool get _sessionPending => _preparingChat || _creatingSession;
  late final RepoQuickVoiceSession _quickVoice;

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
    _running = RunningSessions.of(widget.api);
    _repoState = _running.repo(widget.repo, widget.memory);
    widget.api.linkEpoch.addListener(_onLinkChanged);
    _refreshCodexUsage();
    _usageTimer = Timer.periodic(const Duration(minutes: 5), (_) => _refreshCodexUsage());
    _voiceInputMode = widget.memory?.chatVoiceInput() ?? false;
    _typewriter = WxTypewriterStream(
      onReveal: () {
        if (mounted && _live) _followTypewriterTail();
      },
    );
    _quickVoice = RepoQuickVoiceSession(
      api: widget.api,
      owner: widget.repo.owner,
      repo: widget.repo.name,
      resolveTtsVoice: () => widget.memory?.ttsVoice() ?? kDefaultVolcTtsVoice,
      resolveAgentMode: () => _agentMode,
      sttClient: widget.sttClient,
      voiceMedia: widget.voiceMedia,
      onChanged: () {
        if (mounted) setState(() {});
      },
      historyForVoice: () => _messages
          .where((message) => message.outcome != ChatTurnOutcome.queueCancelled)
          .toList(),
      resolveSessionId: () => _sessionId,
      onSessionId: _rememberSessionId,
      onTurnRecorded: ({
        required String question,
        required String answer,
        String? engine,
        String? sessionId,
      }) async {
        if (!mounted) return;
        setState(() {
          _rememberInputMode(true);
          _messages.addAll([
            ChatMessage(role: 'user', content: question, via: 'voice'),
            ChatMessage(role: 'assistant', content: answer, engine: engine, via: 'voice'),
          ]);
          _appearingQuestion = _messages[_messages.length - 2];
        });
        if (sessionId != null && sessionId.isNotEmpty) {
          _rememberSessionId(sessionId);
        }
        await _persist();
        _jumpToLatest(force: true);
      },
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      },
    );
    _restoreLocal();
    chatBackfillTick.addListener(_onChatBackfill);
    _running.addListener(_syncExecution);
    _agentMode = widget.memory?.agentModeFor(widget.repo.fullName) ?? widget.temporary;
    widget.api
        .warmChatSession(widget.repo.owner, widget.repo.name)
        .catchError((_) {});
    _loadSessions().whenComplete(() {
      if (mounted) {
        setState(() => _preparingChat = false);
        _syncExecution(force: true);
      }
    });
    _loadVoice();
    _voiceHoldTipVisible = !(widget.memory?.voiceHoldTipDismissed() ?? false);
    _scroll.addListener(_onScrollPosition);
  }

  void _onScrollPosition() {
    if (!_scroll.hasClients || !mounted || _autoFollowing || _restoringScroll) return;
    if (_nearBottom && (_userScrolledAwayFromBottom || _pendingNewBelow)) {
      setState(() {
        _userScrolledAwayFromBottom = false;
        _pendingNewBelow = false;
      });
    }
  }

  bool _onChatScrollNotification(ScrollNotification notification) {
    if (_autoFollowing || _restoringScroll) return false;
    if (notification is ScrollUpdateNotification && notification.dragDetails != null) {
      if (!_nearBottom && !_userScrolledAwayFromBottom) {
        setState(() => _userScrolledAwayFromBottom = true);
      }
    }
    return false;
  }

  void _cancelStreamScrollFollow() {
    _streamScrollTimer?.cancel();
    _streamScrollTimer = null;
    _lastFollowExtent = -1;
  }

  /// While typewriter ticks, avoid stacked [animateTo] calls (they jitter short lists).
  void _followTypewriterTail() {
    if (_restoringScroll) return;
    if (_userScrolledAwayFromBottom || !_nearBottom) {
      if (!_pendingNewBelow) setState(() => _pendingNewBelow = true);
      return;
    }
    _streamScrollTimer?.cancel();
    _streamScrollTimer = Timer(const Duration(milliseconds: 48), () {
      if (!mounted || !_scroll.hasClients || _restoringScroll) return;
      final pos = _scroll.position;
      if (pos.pixels <= 0.5) return;
      if (_lastFollowExtent == 0 && _nearBottom) return;
      _lastFollowExtent = 0;
      _autoFollowing = true;
      pos.jumpTo(0);
      _autoFollowing = false;
    });
  }

  void _jumpToLatest({bool force = false}) {
    if (_restoringScroll) return;
    if (force) {
      _userScrolledAwayFromBottom = false;
      _pendingNewBelow = false;
      _cancelStreamScrollFollow();
    } else if (_userScrolledAwayFromBottom || !_nearBottom) {
      if (_live || _busy) {
        if (!_pendingNewBelow) setState(() => _pendingNewBelow = true);
      }
      return;
    }
    final epoch = _scrollEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!_scroll.hasClients || !mounted || epoch != _scrollEpoch) return;
      final pos = _scroll.position;
      if (pos.pixels <= 1) return;
      _autoFollowing = true;
      try {
        if (_live) {
          pos.jumpTo(0);
        } else {
          await pos.animateTo(
            0,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
          );
        }
      } finally {
        if (epoch == _scrollEpoch) _autoFollowing = false;
      }
    });
  }

  Future<void> _loadVoice() async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final status = await widget.api.status();
        if (!mounted) return;
        setState(() {
          _voiceReady = status.voiceReady;
          _voiceCall = status.voiceCall;
          _voiceHint = status.voiceReady
              ? ''
              : (status.voiceHint.isEmpty ? humanizeSttEvent(code: 'unconfigured') : status.voiceHint);
        });
        return;
      } catch (_) {
        if (attempt == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _voiceReady = false;
      _voiceCall = false;
      _voiceHint = '连不上问象服务，暂时无法使用语音。请确认电脑上的服务已启动。';
    });
  }

  Future<void> _toggleVoiceInput() async {
    if (!_voiceReady) {
      await _loadVoice();
      if (!mounted) return;
      if (!_voiceReady) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(_voiceHint.isEmpty ? humanizeSttEvent(code: 'unconfigured') : _voiceHint)),
        );
        return;
      }
    }
    if (_sttBusy || _holding) return;
    setState(() {
      _voiceInputMode = !_voiceInputMode;
      if (_voiceInputMode) _focus.unfocus();
    });
    unawaited(widget.memory?.saveChatVoiceInput(_voiceInputMode));
  }

  Future<void> _openCall() async {
    if (!_voiceCall || _preparingChat || _busy || _live || _holding || _holdPending || _sttBusy) return;
    _quickVoice.interruptReply();
    if (widget.temporary) {
      try { await widget.api.prepareVoiceChatSession(sessionId: _sessionId, agentMode: _agentMode); }
      catch (err) { if (mounted) _snack(err.toString()); return; }
    }
    if (!mounted) return;
    await openVoiceCall(
      context,
      api: widget.api,
      repo: widget.repo,
      media: widget.callMedia,
      client: widget.callClient,
      onTranscript: _foldCallTranscript,
    );
  }

  void _foldCallTranscript(List<ChatMessage> captions) {
    if (!mounted || captions.isEmpty) return;
    setState(() {
      for (final item in captions) {
        _messages.add(ChatMessage(
          role: item.role,
          content: item.content,
          engine: item.engine,
          via: 'voice',
        ));
      }
    });
    unawaited(_persist());
    _jumpToLatest(force: true);
  }

  Future<void> _beginHold(double globalY) async {
    if (_sttBusy || _holding || _holdPending || !_voiceReady) return;
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
    if (!mounted || _stt != client || !_holdPending) return;
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
    final client = _stt;
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
    // A disconnect/cancel can finish this session while the recorder stops.
    if (!mounted || client == null || _stt != client) return;
    if (cancel) {
      _stt?.cancel();
      _disposeStt();
      setState(() => _holdLive = '');
      return;
    }
    setState(() {
      _sttBusy = true;
      _holdHint = '识别中，点按取消';
    });
    _stt?.stop();
  }

  void _cancelSttRecognition() {
    if (!_sttBusy && _stt == null) return;
    HapticFeedback.selectionClick();
    _stt?.cancel();
    _disposeStt();
    if (!mounted) return;
    setState(() {
      _sttBusy = false;
      _holdLive = '';
      _holdHint = '';
    });
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
        _composeFromVoice = true;
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
      _holdPending = false;
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
    if (_micSub != null) {
      _micSub?.cancel();
      _micSub = null;
      unawaited(_media?.stopMic());
    }
    _sttSub?.cancel();
    _sttSub = null;
    _stt?.dispose();
    _stt = null;
  }

  void _restoreLocal() {
    _sessionId = widget.initialSessionId ?? _repoState.activeId ??
        (_sessions.isEmpty ? null : _sessions.first.id);
  }

  Future<void> _persist() async {
    _repoState.activeId = _sessionId;
    await _repoState.persist();
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
            _selectSession(list.firstWhere((s) => s.active, orElse: () => list.first).id);
          } else if (_sessions.isNotEmpty) {
            _selectSession(_sessions.first.id);
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
    if (_sessionPending) return;
    setState(() => _creatingSession = true);
    try {
      final created = await widget.api.createSession(widget.repo.owner, widget.repo.name);
      if (!mounted) return;
      setState(() {
        _sessions.insert(0, created);
        _transcripts[created.id] = [];
        _selectSession(created.id);
      });
      _syncExecution(force: true);
      await _persist();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(humanizeError(err))),
      );
    } finally {
      if (mounted) setState(() => _creatingSession = false);
    }
  }

  Future<void> _switchSession(ChatSession session) async {
    setState(() => _selectSession(session.id));
    _syncExecution(force: true);
    _persist();
    if (widget.temporary) _warmAcp();
  }

  Future<void> _closeSession(ChatSession session) async {
    _running.execution(session.id)?.stop();
    try {
      await widget.api.closeSession(widget.repo.owner, widget.repo.name, session.id);
      if (!mounted) return;
      setState(() {
        _repoState.removeSession(session.id);
        if (_sessionId == session.id) {
          _selectSession(_sessions.firstOrNull?.id);
        }
        _sessionViews.remove(session.id);
      });
      if (_sessionId == null || _sessions.isEmpty) {
        _typewriter.reset();
        _liveEngine.value = null;
      }
      _syncExecution(force: true);
      if (_sessions.isEmpty) await _newSession();
      await _persist();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(humanizeError(err))),
      );
    }
  }

  void _selectSession(String? id) {
    if (_sessionId == id) return;
    final previous = _sessionView;
    previous.input = _input.value;
    if (!_restoringScroll && _scroll.hasClients) {
      previous.offset = _scroll.offset;
    }
    _sessionId = id;
    final next = _sessionView;
    _input.value = next.input;
    _editingMessage = null;
    _appearingQuestion = null;
    _shownTurnId = null;
    _cancelStreamScrollFollow();
    _autoFollowing = false;
    _pendingNewBelow = false;
    _userScrolledAwayFromBottom = false;
    _restoringScroll = true;
    final epoch = ++_scrollEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _scrollEpoch) return;
      if (_scroll.hasClients) {
        final position = _scroll.position;
        position.jumpTo(next.offset.clamp(0.0, position.maxScrollExtent));
      }
      _userScrolledAwayFromBottom = !_nearBottom;
      _restoringScroll = false;
    });
  }

  void _renameSessionView(String next) {
    final view = _sessionViews.remove(_sessionId ?? '');
    if (view != null) _sessionViews[next] = view;
    _sessionId = next;
  }

  void _rememberSessionId(String? next) {
    if (next == null || next.isEmpty || next == _sessionId) return;
    final old = _sessionId ?? '';
    final prior = _transcripts.remove(old);
    if (prior != null) {
      _transcripts[next] = prior;
    }
    _renameSessionView(next);
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

  void _beginEdit(ChatMessage message) {
    final index = _messages.indexOf(message);
    if (index < 0 || _sessionPending || _readingImages || _uploadingImages) return;
    if (_processingUserIndex == index) return;
    final queued = _isQueuedUserMessage(message);
    if (!queued && (_busy || _live)) return;
    setState(() => _editingMessage = message);
  }

  void _cancelEdit() {
    if (_editingMessage == null) return;
    setState(() => _editingMessage = null);
  }

  Future<void> _commitEdit(ChatMessage message, String text) async {
    final index = _messages.indexOf(message);
    final next = text.trim();
    if (index < 0 || _sessionPending || _readingImages || _uploadingImages) {
      return;
    }
    if (next.isEmpty && message.images.isEmpty) return;
    final queued =
        _isQueuedUserMessage(message) && _processingUserIndex != index;
    if (queued) {
      setState(() {
        message.content = next;
        _editingMessage = null;
      });
      await _persist();
      return;
    }
    if (_busy || _live) {
      if (mounted) setState(() => _editingMessage = null);
      return;
    }
    final prefix = List<ChatMessage>.from(_messages.take(index));
    setState(() => _creatingSession = true);
    try {
      final created =
          await widget.api.createSession(widget.repo.owner, widget.repo.name);
      if (!mounted) return;
      setState(() {
        _sessions.insert(0, created);
        _transcripts[created.id] = prefix;
        _selectSession(created.id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _editingMessage = null;
        _messages
          ..clear()
          ..addAll(prefix);
      });
    } finally {
      if (mounted) setState(() => _creatingSession = false);
    }
    await _send(next, message.images);
  }

  int get _queuedCount => _execution?.queued.length ?? 0;

  bool _isQueuedUserMessage(ChatMessage message) {
    return message.role == 'user' &&
        (_execution?.queued.contains(message) ?? false);
  }

  Future<void> _removeQueuedTurn(ChatMessage message) async {
    if (!_isQueuedUserMessage(message)) return;
    HapticFeedback.selectionClick();
    setState(() {
      _messages.remove(message);
      _execution?.queued.remove(message);
      _processingUserIndex = _execution?.userIndex;
      if (_editingMessage == message) _editingMessage = null;
    });
    await _persist();
  }

  bool _composeFromVoice = false;

  void _rememberInputMode(bool voice) {
    _voiceInputMode = voice;
    unawaited(widget.memory?.saveChatVoiceInput(voice));
  }

  Future<void> _pickImages() async {
    if (_readingImages ||
        _uploadingImages ||
        _sessionPending ||
        _holding ||
        _sttBusy) {
      return;
    }
    final target = _sessionView;
    final room = chatImageMaxCount - target.images.length;
    if (room <= 0) {
      _snack('最多带 4 张图');
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Wx.raised,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    setState(() => target.readingImages = true);
    try {
      if (source == ImageSource.camera) {
        final status = await Permission.camera.request();
        if (!mounted) return;
        if (!status.isGranted) {
          _snack('需要相机权限才能拍照');
          return;
        }
      }
      final picker = ImagePicker();
      final files = <XFile>[];
      if (source == ImageSource.gallery) {
        files.addAll(await picker.pickMultiImage(
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 82,
          limit: room,
        ));
      } else {
        final shot = await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 82,
        );
        if (shot != null) files.add(shot);
      }
      if (!mounted || files.isEmpty) return;
      final stored = <_DraftImage>[];
      var skipped = false;
      for (final file in files.take(room)) {
        if (await file.length() > chatImageMaxBytes) {
          skipped = true;
          continue;
        }
        final bytes = await file.readAsBytes();
        if (!mounted) return;
        stored.add(_DraftImage(
          bytes: bytes,
          mimeType: chatImageMime(mimeType: file.mimeType, path: file.path),
        ));
      }
      if (!mounted) return;
      if (skipped) _snack('有图片太大，已跳过');
      if (stored.isEmpty) return;
      setState(() => target.images.addAll(stored));
    } catch (_) {
      if (mounted) _snack('没能读取图片');
    } finally {
      if (mounted) setState(() => target.readingImages = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _send(
      [String? preset, List<ChatImageAttachment>? reuseImages]) async {
    if (_sessionPending || _readingImages || _uploadingImages) return;
    final text = (preset ?? _input.text).trim();
    final voice = _composeFromVoice;
    _composeFromVoice = false;
    final usingDrafts = reuseImages == null;
    final draftCount = usingDrafts ? _draftImages.length : reuseImages.length;
    if (text.isEmpty && draftCount == 0) return;

    // Capture the destination before uploading: routes and selected sessions may change.
    if (_sessionId == null) _rememberSessionId(mintTurnId());
    _repoState.activeId = _sessionId;
    final targetId = _sessionId!;
    final targetMessages = _messages;
    final targetMode = _agentMode;
    final targetView = _sessionView;
    final drafts = List<_DraftImage>.from(targetView.images);
    HapticFeedback.selectionClick();
    _editingMessage = null;
    if (usingDrafts) {
      _input.clear();
      targetView.images.clear();
    }

    List<ChatImageAttachment> images;
    if (!usingDrafts) {
      images = reuseImages;
    } else if (drafts.isEmpty) {
      images = const [];
    } else {
      setState(() => targetView.uploadingImages = true);
      try {
        final uploaded = <ChatImageAttachment>[];
        for (final draft in drafts) {
          uploaded.add(await widget.api.uploadChatImage(
            bytes: draft.bytes,
            mimeType: draft.mimeType,
          ));
        }
        images = uploaded;
      } catch (err) {
        if (mounted) {
          setState(() {
            targetView.uploadingImages = false;
            if (identical(_sessionView, targetView)) {
              if (_input.text.isEmpty) _input.text = text;
            } else if (targetView.input.text.isEmpty) {
              targetView.input = TextEditingValue(
                text: text,
                selection: TextSelection.collapsed(offset: text.length),
              );
            }
            targetView.images.addAll(drafts);
          });
          _snack(humanizeError(err));
        }
        return;
      }
    }

    if (!_sessions.any((s) => s.id == targetId)) {
      if (mounted) setState(() => targetView.uploadingImages = false);
      return;
    }
    final message = ChatMessage(
      role: 'user', content: text, via: voice ? 'voice' : null,
      turnId: mintTurnId(), images: images,
    );
    targetMessages.add(message);
    _running.session(_repoState, targetId, targetMode).enqueue(message);
    if (mounted) {
      setState(() {
        targetView.uploadingImages = false;
        if (_sessionId == targetId) {
          if (usingDrafts) _rememberInputMode(voice);
          _appearingQuestion = message;
        }
      });
      if (_sessionId == targetId) _jumpToLatest(force: true);
    }
    await _repoState.persist();
  }

  void _retryTurn(ChatMessage question) {
    if (_busy || !_messages.contains(question)) return;
    unawaited(_send(question.content, question.images));
  }

  Future<void> _checkTimedOutTurn(ChatMessage question) async {
    final session = _sessionId;
    final turn = question.turnId;
    if (session == null ||
        turn == null ||
        question.outcome != ChatTurnOutcome.timedOut ||
        _checkingResults.contains(question)) {
      return;
    }
    final messages = _messages;
    setState(() => _checkingResults.add(question));
    try {
      final answer =
          await widget.api.finalChatAnswer(sessionId: session, turnId: turn);
      final index = messages.indexOf(question);
      if (index < 0 ||
          !_transcripts.containsValue(messages) ||
          question.outcome != ChatTurnOutcome.timedOut) {
        return;
      }
      if (answer == null || !mergeFinalTurnAnswer(messages, index, answer)) {
        if (mounted && _sessionId == session) _snack('还没有收到最终答复，可以稍后再查看');
        return;
      }
      await _repoState.persist();
      _running.changed();
    } catch (error) {
      if (mounted && _sessionId == session) _snack(humanizeError(error));
    } finally {
      if (mounted) setState(() => _checkingResults.remove(question));
    }
  }

  Future<void> _submitDecision({
    required String kind,
    required bool skip,
    required bool accept,
    required List<Map<String, dynamic>> answers,
  }) async {
    final execution = _execution;
    final requestId = _decision?.payload?['requestId']?.toString() ?? '';
    final sessionId = (_decision?.sessionId ?? _sessionId ?? '').trim();
    if (requestId.isEmpty || sessionId.isEmpty) {
      throw StateError('missing interaction');
    }
    await widget.api.replyInteraction(
      sessionId: sessionId,
      requestId: requestId,
      kind: kind,
      accept: accept,
      skip: skip,
      answers: answers,
    );
    execution?.decision = null;
    _running.changed();
  }

  void _syncReplyText() {
    final next = _shownExecution?.text ?? '';
    final previous = _typewriter.fullText;
    if (next == previous) return;
    if (next.startsWith(previous)) {
      _typewriter.push(next.substring(previous.length));
    } else {
      _typewriter.replacePending(next);
    }
  }

  void _syncExecution({bool force = false}) {
    if (!mounted) return;
    final task = _execution;
    final sessionChanged = task != null && task.sessionId != _sessionId;
    if (sessionChanged) {
      _renameSessionView(task.sessionId);
    }
    final busy = task?.busy ?? false;
    final live = busy && task?.current != null && !task!.stopped;
    final active = live ? task : null;
    final executionChanged = active != _shownExecution;
    if (executionChanged) {
      _shownExecution?.replyText.removeListener(_syncReplyText);
      _shownExecution = active;
      active?.replyText.addListener(_syncReplyText);
    }
    final turnId = task?.current?.turnId;
    final wasBusy = _busy;
    if (executionChanged || turnId != _shownTurnId) {
      _typewriter.reset();
      _shownTurnId = turnId;
      _syncReplyText();
    }
    _liveEngine.value = task?.engine;
    _liveActivity.value = task?.activity ?? '';
    _livePhase.value = task?.phase ?? 'connect';
    _holdPollOk.value = task?.pollOk ?? true;
    final messageCount = _messages.length;
    final queueCount = _queuedCount;
    final userIndex = task?.userIndex;
    final decision = task?.decision;
    if (!force &&
        !sessionChanged &&
        !executionChanged &&
        busy == wasBusy &&
        live == _live &&
        messageCount == _shownMessageCount &&
        queueCount == _shownQueueCount &&
        userIndex == _processingUserIndex &&
        decision == _decision) {
      return;
    }
    setState(() {
      _busy = busy;
      _live = live;
      _shownMessageCount = messageCount;
      _shownQueueCount = queueCount;
      _processingUserIndex = userIndex;
      _decision = decision;
    });
    if (wasBusy && !_busy) {
      unawaited(_refreshCodexUsage());
      unawaited(_refreshCurrentSessionMeta());
    }
    _jumpToLatest();
  }

  void _stop() => _execution?.stop();

  void _onChatBackfill() {
    if (!mounted) return;
    _mergeBackfill();
  }

  void _mergeBackfill() {
    _repoState.mergeSaved();
    if (mounted) setState(() {});
  }

  Future<void> _openRunningSessions() async {
    final task = await Navigator.of(context, rootNavigator: true).push<SessionExecution>(
      MaterialPageRoute(builder: (_) => RunningSessionsPage(running: _running)),
    );
    if (!mounted || task == null) return;
    if (task.repo.repo.fullName == widget.repo.fullName) {
      setState(() => _selectSession(task.sessionId));
      _syncExecution(force: true);
      await _persist();
    } else {
      await Navigator.of(context).push<void>(MaterialPageRoute(builder: (context) => ChatPage(
        api: widget.api, repo: task.repo.repo, memory: widget.memory,
        initialSessionId: task.sessionId,
        onBack: () => Navigator.of(context).pop(),
      )));
      if (mounted) _syncExecution();
    }
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    return pos.pixels <= _scrollBottomThreshold;
  }

  Future<void> _openSessions() async {
    String? closingId;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Wx.surface,
      showDragHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Wx.radius)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (sheetContext, setSheet) {
            return SafeArea(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 20),
                itemCount: 1 + _sessions.length,
                itemBuilder: (context, index) {
                  if (index > 0) {
                    final session = _sessions[index - 1];
                    return _SessionRow(
                      session: session,
                      selected: session.id == _sessionId,
                      closing: closingId == session.id,
                      onOpen: closingId != null
                          ? null
                          : () {
                              Navigator.pop(context);
                              _switchSession(session);
                            },
                      onClose: _busy || closingId != null
                          ? null
                          : () async {
                              setSheet(() => closingId = session.id);
                              await _closeSession(session);
                              if (sheetContext.mounted) {
                                setSheet(() => closingId = null);
                              }
                            },
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
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
                            child: Text(
                              '历史会话',
                              key: const Key('wx-session-sheet'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _sessionPending || closingId != null
                                ? null
                                : () async {
                                    Navigator.pop(context);
                                    await _newSession();
                                  },
                            icon: const Icon(Icons.add_comment_outlined,
                                size: 18),
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
                          child: Text('还没有会话',
                              style: Theme.of(context).textTheme.bodyMedium),
                        ),
                    ],
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _refreshCodexUsage() async {
    if (_usageLoading) return;
    setState(() => _usageLoading = true);
    try {
      final usage = await widget.api.codexUsage();
      if (mounted) setState(() => _codexUsage = usage);
    } catch (_) {
      if (mounted) setState(() => _codexUsage = null);
    } finally {
      if (mounted) setState(() => _usageLoading = false);
    }
  }

  void _onLinkChanged() {
    if (mounted) {
      setState(() => _codexUsage = null);
      _refreshCodexUsage();
    }
  }

  @override
  void dispose() {
    _usageTimer?.cancel();
    widget.api.linkEpoch.removeListener(_onLinkChanged);
    chatBackfillTick.removeListener(_onChatBackfill);
    _running.removeListener(_syncExecution);
    _shownExecution?.replyText.removeListener(_syncReplyText);
    _quickVoice.dispose();
    _disposeStt();
    _micSub?.cancel();
    _media?.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.removeListener(_onScrollPosition);
    _scroll.dispose();
    _cancelStreamScrollFollow();
    _typewriter.dispose();
    _liveEngine.dispose();
    _livePhase.dispose();
    _liveActivity.dispose();
    _holdPollOk.dispose();
    super.dispose();
  }

  Widget _messageList(int itemCount) {
    final messages = _messages;
    final liveAt =
        _live ? (_processingUserIndex ?? messages.length - 1) + 1 : null;
    const liveKey = ValueKey('wx-live-reply');

    return NotificationListener<ScrollNotification>(
      key: ValueKey(_scrollEpoch),
      onNotification: _onChatScrollNotification,
      child: ListView.builder(
        key: const Key('wx-chat-list'),
        controller: _scroll,
        reverse: true,
        padding: EdgeInsets.fromLTRB(
          4,
          12,
          4,
          _kChatListBottomInset + (_draftImages.isEmpty ? 0 : _kChatDraftStrip),
        ),
        itemCount: itemCount,
        findChildIndexCallback: (key) {
          if (key == liveKey) {
            return liveAt == null ? null : itemCount - 1 - liveAt;
          }
          if (key is! ObjectKey) return null;
          final index = messages.indexOf(key.value as ChatMessage);
          if (index < 0) return null;
          final row = liveAt != null && index >= liveAt ? index + 1 : index;
          return itemCount - 1 - row;
        },
        itemBuilder: (context, index) {
          final row = itemCount - 1 - index;
          if (row == liveAt) {
            return _LiveTurn(
              key: liveKey,
              api: widget.api,
              openAnswerLink: widget.openAnswerLink,
              text: _typewriter.visible,
              engine: _liveEngine,
              phase: _livePhase,
              activity: _liveActivity,
              holdPollOk: _holdPollOk,
            );
          }
          final at = liveAt != null && row > liveAt ? row - 1 : row;
          final message = messages[at];
          final queued = _isQueuedUserMessage(message);
          ChatMessage? retryQuestion;
          if (message.role == 'error' && message.turnId != null) {
            final questionAt = indexOfTurn(messages, message.turnId!);
            if (questionAt >= 0) retryQuestion = messages[questionAt];
          } else if (message.outcome == ChatTurnOutcome.queueCancelled) {
            retryQuestion = message;
          }
          ChatTurnOutcome? replyOutcome;
          if (message.role == 'assistant') {
            for (var i = at - 1; i >= 0; i--) {
              if (messages[i].role != 'user') continue;
              replyOutcome = messages[i].outcome;
              break;
            }
          }
          final retry = retryQuestion;
          return _FinishedTurn(
            key: ObjectKey(message),
            api: widget.api,
            openAnswerLink: widget.openAnswerLink,
            ttsVoice: widget.memory?.ttsVoice(),
            appear: identical(_appearingQuestion, message),
            message: message,
            queued: queued,
            editing: _editingMessage == message,
            replyOutcome: replyOutcome,
            onEdit: message.role == 'user' &&
                    _processingUserIndex != at &&
                    !_sessionPending &&
                    !_readingImages &&
                    !_uploadingImages &&
                    (queued || !_busy)
                ? () => _beginEdit(message)
                : null,
            onCancelEdit: _cancelEdit,
            onSubmitEdit: (text) => _commitEdit(message, text),
            onRemoveQueue: queued ? () => _removeQueuedTurn(message) : null,
            onRetry: retry != null &&
                    !_busy &&
                    !_sessionPending &&
                    !_uploadingImages &&
                    !_readingImages
                ? () => _retryTurn(retry)
                : null,
            checkingResult: _checkingResults.contains(message),
            onCheckResult: message.outcome == ChatTurnOutcome.timedOut &&
                    message.turnId != null
                ? () => _checkTimedOutTurn(message)
                : null,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = _currentSession;
    final subtitle = session == null || session.title.isEmpty || session.title == '新会话'
        ? ''
        : session.title;
    final itemCount = _messages.length + (_live ? 1 : 0);
    final sessionWait = _creatingSession ? '正在新建会话…' : '正在准备对话…';
    return PopScope(
      canPop: false,
      child: Scaffold(
      body: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          WxPageHeader(
            onBack: () {
              widget.onBack();
            },
            backTooltip: widget.temporary ? '结束临时会话' : '返回仓库',
            title: widget.temporary ? '临时会话' : widget.repo.fullName,
            subtitle: widget.temporary ? '对话临时保留 · 产物归档' : subtitle,
            status: WxLinkQualityMark(api: widget.api),
            trailing: [
              _AgentModeChip(
                api: widget.api,
                agentMode: _agentMode,
                usage: _codexUsage,
                loading: _usageLoading,
                onRefreshUsage: _refreshCodexUsage,
                repoName: widget.repo.name,
                enabled: !_busy && !_sessionPending,
                onChanged: (value) {
                  setState(() => _agentMode = value);
                  widget.memory?.saveAgentMode(widget.repo.fullName, value);
                },
              ),
              if (_voiceCall)
                IconButton(
                  key: const Key('wx-call'),
                  tooltip: '电话',
                  onPressed: _sessionPending || _busy || _live ? null : _openCall,
                  icon: const Icon(Icons.phone_outlined),
                ),
              PopupMenuButton<String>(
                key: const Key('wx-chat-more'),
                tooltip: '更多',
                enabled: !_sessionPending,
                color: Wx.surface,
                surfaceTintColor: Colors.transparent,
                icon: WxRunningMoreIcon(running: _running),
                onSelected: (value) {
                  if (value == 'new') _newSession();
                  if (value == 'history') _openSessions();
                  if (value == 'running') _openRunningSessions();
                  if (value == 'files') widget.onOpenFiles?.call();
                },
                itemBuilder: (context) => [
                  if (widget.onOpenFiles != null) const PopupMenuItem(value: 'files', child: Text('本次生成文件')),
                  PopupMenuItem(
                    key: const Key('wx-chat-new-session'),
                    value: 'new',
                    enabled: !_sessionPending,
                    child: const Text('新建会话'),
                  ),
                  const PopupMenuItem(
                    key: Key('wx-chat-running'),
                    value: 'running',
                    child: Text('执行中'),
                  ),
                  const PopupMenuItem(
                    key: Key('wx-chat-history'),
                    value: 'history',
                    child: Text('历史会话'),
                  ),
                ],
              ),
            ],
          ),
          const WxHairline(),
          if (_sessionPending && itemCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 10, Wx.inset, 4),
              child: WxInlineBusy(sessionWait),
            ),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                itemCount == 0
                    ? (_sessionPending
                        ? WxBusy(label: sessionWait)
                        : _EmptyChat(onPick: _send, temporary: widget.temporary))
                    : _messageList(itemCount),
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
          if (_decision != null)
            WxAppear(
              key: ValueKey('decision-${_decision!.payload?['requestId'] ?? _decision.hashCode}'),
              child: AgentDecisionCard(
                event: _decision!,
                onSubmit: _submitDecision,
              ),
            ),
          _Composer(
            controller: _input,
            focus: _focus,
            busy: _busy,
            queueCount: _queuedCount,
            preparing: _sessionPending,
            voiceReady: _voiceReady,
            voiceInputMode: _voiceInputMode,
            holding: _holding || _holdPending,
            holdCancel: _holdCancel,
            sttBusy: _sttBusy,
            holdLive: _holdLive,
            holdHint: _holdHint,
            voiceHoldTipVisible: _voiceHoldTipVisible,
            agentMode: _agentMode,
            onToggleVoiceInput: _toggleVoiceInput,
            onHoldStart: _beginHold,
            onHoldMove: _moveHold,
            onHoldEnd: _endHold,
            onCancelRecognize: _cancelSttRecognition,
            onSend: _send,
            onStop: _stop,
            draftBytes: [for (final draft in _draftImages) draft.bytes],
            imageWait: _uploadingImages
                ? '正在上传图片…'
                : _readingImages ? '正在读取图片…' : null,
            onPickImages: _pickImages,
            onRemoveDraft: (index) {
              if (index < 0 || index >= _draftImages.length) return;
              setState(() => _draftImages.removeAt(index));
            },
          ),
            ],
          ),
          if (!_busy && !_live)
            Positioned(
              left: 8,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom +
                  _kChatFabLift +
                  (_draftImages.isEmpty ? 0 : _kChatDraftStrip),
              child: Align(
                alignment: Alignment.bottomRight,
                child: BookQuickVoiceFab(
                  session: _quickVoice,
                  palette: _quickVoicePalette,
                  enabled: _voiceReady && !_sessionPending,
                ),
              ),
            ),
        ],
      ),
    ),
    );
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onPick, this.temporary = false});
  final void Function(String text)? onPick;
  final bool temporary;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(Wx.inset, 36, Wx.inset, 16),
      children: [
        Text(temporary ? '从空白开始。' : '从进度问起。', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          temporary ? '退出后清除对话，生成的产物默认保存到静态资源区。' : '连上本机问象后可直接问；否则会按本地进度简要回答。不编造。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 28),
        for (final q in temporary ? const ['帮我梳理一个想法', '帮我写一段文字', '帮我生成一个文件'] : _ChatPageState._suggestions)
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
    this.closing = false,
    this.onClose,
  });

  final ChatSession session;
  final bool selected;
  final VoidCallback? onOpen;
  final VoidCallback? onClose;
  final bool closing;

  @override
  Widget build(BuildContext context) {
    final title = session.title.isEmpty ? '新会话' : session.title;
    final when = formatRelativeTime(session.updatedAt.isNotEmpty ? session.updatedAt : session.createdAt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected ? Wx.raised : Colors.transparent,
        borderRadius: BorderRadius.circular(Wx.radius),
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(Wx.radius),
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
                  if (closing)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: WxInlineBusy('正在关闭…'),
                    )
                  else
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
        borderRadius: BorderRadius.circular(Wx.radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Wx.radius),
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

Widget? _queuedTurnActions({
  required VoidCallback? onEdit,
  required VoidCallback? onRemove,
}) {
  final edit = onEdit == null
      ? null
      : IconButton(
          key: const Key('wx-queue-edit'),
          tooltip: '编辑',
          visualDensity: VisualDensity.compact,
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined, size: 18),
        );
  final remove = onRemove == null
      ? null
      : IconButton(
          key: const Key('wx-queue-remove'),
          tooltip: '移出队列',
          visualDensity: VisualDensity.compact,
          onPressed: onRemove,
          icon: const Icon(Icons.close, size: 18, color: Wx.muted),
        );
  if (edit == null) return remove;
  if (remove == null) return edit;
  return Row(mainAxisSize: MainAxisSize.min, children: [edit, remove]);
}

class _EditableUserTurn extends StatefulWidget {
  const _EditableUserTurn({
    required this.message,
    required this.api,
    this.queued = false,
    required this.editing,
    this.status,
    this.onEdit,
    this.onCancel,
    this.onSubmit,
    this.onRemoveQueue,
  });

  final ChatMessage message;
  final WenxiangApi api;
  final bool queued;
  final bool editing;
  final Widget? status;
  final VoidCallback? onEdit;
  final VoidCallback? onCancel;
  final Future<void> Function(String text)? onSubmit;
  final VoidCallback? onRemoveQueue;

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
      voiceColor: Wx.muted,
      railColor: Wx.hairline,
      railWidth: 2,
      bottom: 20,
      footer: widget.status,
      trailing: widget.editing
          ? null
          : widget.queued
              ? _queuedTurnActions(
                  onEdit: widget.onEdit,
                  onRemove: widget.onRemoveQueue,
                )
              : widget.onEdit == null
                  ? null
                  : IconButton(
                      tooltip: '编辑',
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 18),
                    ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.message.images.isNotEmpty) ...[
            ChatImageStrip(images: widget.message.images, api: widget.api),
            const SizedBox(height: 8),
          ],
          if (widget.editing)
            Column(
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
                      key: Key(widget.queued ? 'wx-queue-edit-save' : 'wx-edit-send'),
                      onPressed: () => widget.onSubmit?.call(_edit.text),
                      child: Text(widget.queued ? '保存' : '发送'),
                    ),
                  ],
                ),
              ],
            )
          else if (widget.message.content.trim().isNotEmpty)
            SelectableText(
              widget.message.content,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: Wx.text,
                    height: 1.5,
                  ),
            ),
        ],
      ),
    );
  }
}

/// http(s), mailto, and tel only. Anything else stays in the answer.
Uri? chatAnswerLinkUri(String href) {
  final raw = href.replaceAll('\u200b', '').trim();
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasScheme) return null;
  switch (uri.scheme.toLowerCase()) {
    case 'http':
    case 'https':
    case 'mailto':
    case 'tel':
      return uri;
    default:
      return null;
  }
}

/// System long-press selects the answer text. Link taps open in the browser.
/// The whole reply is copied from the button under the answer.
class _AnswerMarkdown extends StatelessWidget {
  const _AnswerMarkdown({
    required this.api,
    required this.source,
    required this.mdStyle,
    this.openLink,
  });

  final WenxiangApi api;
  final ValueListenable<String> source;
  final WxMarkdownStyle mdStyle;
  final Future<bool> Function(Uri uri)? openLink;

  Future<void> _openLink(BuildContext context, String href) async {
    final uri = chatAnswerLinkUri(href);
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (uri == null) {
      messenger?.showSnackBar(const SnackBar(content: Text('无法打开链接')));
      return;
    }
    var opened = false;
    try {
      final open = openLink;
      opened = open != null
          ? await open(uri)
          : await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    if (!opened && context.mounted) {
      messenger?.showSnackBar(const SnackBar(content: Text('无法打开链接')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: WxChatMarkdownStream(
        source: source,
        mdStyle: mdStyle,
        api: api,
        onTapLink: (href, text) {
          unawaited(_openLink(context, href));
        },
      ),
    );
  }
}

class _FinishedTurn extends StatelessWidget {
  const _FinishedTurn({
    super.key,
    required this.api,
    required this.message,
    this.openAnswerLink,
    this.ttsVoice,
    this.appear = false,
    this.queued = false,
    this.editing = false,
    this.onEdit,
    this.onCancelEdit,
    this.onSubmitEdit,
    this.onRemoveQueue,
    this.onRetry,
    this.replyOutcome,
    this.checkingResult = false,
    this.onCheckResult,
  });
  final WenxiangApi api;
  final ChatMessage message;
  final Future<bool> Function(Uri uri)? openAnswerLink;
  final String? ttsVoice;
  final bool appear;
  final bool queued;
  final bool editing;
  final VoidCallback? onEdit;
  final VoidCallback? onCancelEdit;
  final Future<void> Function(String text)? onSubmitEdit;
  final VoidCallback? onRemoveQueue;
  final VoidCallback? onRetry;
  final ChatTurnOutcome? replyOutcome;
  final bool checkingResult;
  final VoidCallback? onCheckResult;

  Widget? _userStatus(BuildContext context) {
    final label = queued
        ? '排队中'
        : switch (message.outcome) {
            ChatTurnOutcome.stopped => '已停止',
            ChatTurnOutcome.queueCancelled => '已取消排队',
            ChatTurnOutcome.timedOut => '等待超时，尚未收到最终答复',
            null => null,
          };
    if (label == null) return null;
    final style =
        Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: style),
        if (checkingResult)
          WxInlineBusy('正在查看结果…', style: style)
        else if (onCheckResult != null)
          TextButton(onPressed: onCheckResult, child: const Text('查看结果')),
        if (onRetry != null)
          TextButton(onPressed: onRetry, child: const Text('重新发送')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (message.role == 'user') {
      final turn = _EditableUserTurn(
        message: message,
        api: api,
        queued: queued,
        editing: editing,
        status: _userStatus(context),
        onEdit: onEdit,
        onCancel: onCancelEdit,
        onSubmit: onSubmitEdit,
        onRemoveQueue: onRemoveQueue,
      );
      if (!appear) return turn;
      return WxAppear(child: turn);
    }
    if (message.role == 'error') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: WxErrorPanel(
          error: message.content,
          onRetry: onRetry,
          retryLabel: '重试此问题',
        ),
      );
    }
    final note = engineFootnote(message.engine);
    return _VoiceTurn(
      voice: replyOutcome == ChatTurnOutcome.stopped ||
              replyOutcome == ChatTurnOutcome.timedOut
          ? '问象 · 部分答复'
          : '问象',
      voiceColor: Wx.text,
      railColor: Wx.hairline,
      railWidth: 2,
      bottom: 16,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note.isNotEmpty)
            Text(
              note,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          WxAnswerActions(
            text: message.content,
            api: api,
            ttsVoice: ttsVoice,
          ),
        ],
      ),
      child: _AnswerMarkdown(
        api: api,
        source: ValueNotifier<String>(message.content),
        mdStyle: chatMarkdownStyle(Theme.of(context)),
        openLink: openAnswerLink,
      ),
    );
  }
}

/// Plain text while streaming — avoids markdown relayout jitter before the turn finishes.
String _livePhaseLabel(String phase) {
  switch (phase) {
    case 'repo':
      return '读仓库、整理上下文…';
    case 'agent':
      return '连接本机 Agent…';
    case 'generate':
      return '生成回答…';
    case 'hold':
      return '等待本机继续…';
    case 'connect':
    default:
      return '正在连接…';
  }
}

class _LiveTurn extends StatelessWidget {
  const _LiveTurn({
    super.key,
    required this.api,
    required this.text,
    this.openAnswerLink,
    required this.engine,
    required this.phase,
    required this.activity,
    required this.holdPollOk,
  });
  final WenxiangApi api;
  final Future<bool> Function(Uri uri)? openAnswerLink;
  final ValueNotifier<String> text;
  final ValueNotifier<String?> engine;
  final ValueNotifier<String> phase;
  final ValueNotifier<String> activity;
  final ValueNotifier<bool> holdPollOk;

  @override
  Widget build(BuildContext context) {
    final waiting = _WorkingNote(
      phase: phase,
      activity: activity,
      holdPollOk: holdPollOk,
    );
    return _VoiceTurn(
      voice: '问象',
      voiceColor: Wx.text,
      railColor: Wx.hairline,
      railWidth: 2,
      bottom: 16,
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
        builder: (context, value, child) => value.isEmpty ? waiting : child!,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _AnswerMarkdown(
              api: api,
              source: text,
              mdStyle: chatMarkdownStyle(Theme.of(context)),
              openLink: openAnswerLink,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _WorkingNote(
                phase: phase,
                activity: activity,
                holdPollOk: holdPollOk,
                hideWhenIdle: true,
              ),
            ),
          ],
        ),
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
    return WxReplyFrame(
      label: voice,
      labelColor: voiceColor,
      railColor: railColor,
      railWidth: railWidth,
      bottom: bottom,
      lead: 6,
      footer: footer,
      trailing: trailing,
      child: child,
    );
  }
}

const _workRowHeight = 22.0;
const _workRows = 3;
const _workPanelHeight = _workRowHeight * _workRows;

/// One visible step. The row stays a single line and always shows that step's newest text.
({String text, bool thought}) _workStep(String block) {
  final lines = block.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
  if (lines.isEmpty) return (text: '', thought: false);
  final head = lines.first;
  final thought = head == '思考' || head.startsWith('思考·') || head.startsWith('思考 ');
  if (!thought) return (text: _toolLiveLine(lines), thought: false);
  final inline = head.replaceFirst(RegExp(r'^思考[·\s]*'), '').trim();
  final body = lines.skip(1).join('\n').trim();
  final source = body.isNotEmpty ? body : inline;
  if (source.isEmpty) return (text: '…', thought: true);
  final latest = source.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).last;
  const max = 42;
  final text = latest.length <= max ? latest : '…${latest.substring(latest.length - max)}';
  return (text: text, thought: true);
}

/// Title until a newer command or output line arrives, then that newest line.
/// A long title must not push the new line off the row.
String _toolLiveLine(List<String> lines) {
  final head = lines.first;
  final latest = lines.last;
  if (latest == head || head.contains(latest)) return head;
  const sep = ' · ';
  const budget = 28;
  final combined = '$head$sep$latest';
  if (combined.length <= budget) return combined;
  return latest;
}

List<({String text, bool thought})> _workSteps(String activity, String fallback) {
  final raw = activity.trim();
  if (raw.isEmpty) return [(text: fallback, thought: false)];
  final steps = raw
      .split(RegExp(r'\n{2,}'))
      .map(_workStep)
      .where((step) => step.text.isNotEmpty)
      .toList();
  if (steps.isEmpty) return [(text: fallback, thought: false)];
  return steps;
}

class _WorkingNote extends StatelessWidget {
  const _WorkingNote({
    required this.phase,
    required this.activity,
    required this.holdPollOk,
    this.hideWhenIdle = false,
  });

  final ValueNotifier<String> phase;
  final ValueNotifier<String> activity;
  final ValueNotifier<bool> holdPollOk;
  final bool hideWhenIdle;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: phase,
      builder: (context, livePhase, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: holdPollOk,
          builder: (context, pollOk, _) {
            return ValueListenableBuilder<String>(
              valueListenable: activity,
              builder: (context, liveActivity, _) {
                if (hideWhenIdle &&
                    liveActivity.trim().isEmpty &&
                    livePhase != 'hold') {
                  return const SizedBox.shrink();
                }
                final steps = _workSteps(liveActivity, _livePhaseLabel(livePhase));
                final visible =
                    steps.length <= _workRows ? steps : steps.sublist(steps.length - _workRows);
                final pad = _workRows - visible.length;
                final holdPoll = livePhase == 'hold';
                return SizedBox(
                  key: const Key('wx-work-log'),
                  height: _workPanelHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < pad; i++) const SizedBox(height: _workRowHeight),
                      for (var i = 0; i < visible.length; i++)
                        _WorkRow(
                          text: visible[i].text,
                          thought: visible[i].thought,
                          active: i == visible.length - 1,
                          holdPoll: holdPoll && i == visible.length - 1,
                          holdPollFailed: holdPoll && !pollOk,
                        ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _WorkRow extends StatelessWidget {
  const _WorkRow({
    required this.text,
    required this.thought,
    required this.active,
    this.holdPoll = false,
    this.holdPollFailed = false,
  });

  final String text;
  final bool thought;
  final bool active;
  final bool holdPoll;
  final bool holdPollFailed;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: active ? Wx.text : Wx.muted,
      fontSize: 12,
      height: 1.2,
    );
    return SizedBox(
      height: _workRowHeight,
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Center(
              child: active
                  ? WxLoading(
                      key: const Key('wx-working-mark'),
                      size: 14,
                      color: holdPoll
                          ? (holdPollFailed ? Wx.danger : Wx.holdPoll)
                          : null,
                    )
                  : const _StepDot(),
            ),
          ),
          if (thought) ...[
            const Text(
              '思考',
              style: TextStyle(color: Wx.faint, fontSize: 11, height: 1),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Semantics(
              liveRegion: active,
              child: thought
                  ? _TailLine(text: text, style: style)
                  : Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
            ),
          ),
          if (active)
            ExcludeSemantics(
              child: _StepAge(token: text),
            ),
        ],
      ),
    );
  }
}

/// One line, left-aligned when it fits. When it doesn't, the start clips so the newest characters stay visible.
class _TailLine extends StatelessWidget {
  const _TailLine({required this.text, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: double.infinity);
        final fits = painter.width <= constraints.maxWidth;
        painter.dispose();
        if (fits) {
          return Text(text, maxLines: 1, softWrap: false, style: style);
        }
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerRight,
            minWidth: 0,
            maxWidth: double.infinity,
            child: Text(text, maxLines: 1, softWrap: false, style: style),
          ),
        );
      },
    );
  }
}

/// Seconds since this row's text last changed. A climbing number means the step has gone quiet.
class _StepAge extends StatefulWidget {
  const _StepAge({required this.token});

  final String token;

  @override
  State<_StepAge> createState() => _StepAgeState();
}

class _StepAgeState extends State<_StepAge> {
  Timer? _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant _StepAge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token == widget.token) return;
    _seconds = 0;
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _seconds += 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _seconds;
    final quiet = seconds >= 8;
    final label = seconds < 1
        ? ''
        : (seconds < 60 ? '$seconds秒' : '${seconds ~/ 60}分${(seconds % 60).toString().padLeft(2, '0')}');
    return SizedBox(
      width: 40,
      child: Text(
        label,
        key: const Key('wx-work-age'),
        textAlign: TextAlign.right,
        maxLines: 1,
        style: TextStyle(
          color: quiet ? Wx.accent : Wx.faint,
          fontSize: 11,
          height: 1,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _StepDot extends StatelessWidget {
  const _StepDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(color: Wx.faint, shape: BoxShape.circle),
    );
  }
}

class _AgentModeChip extends StatelessWidget {
  const _AgentModeChip({
    required this.api,
    required this.agentMode,
    required this.usage,
    required this.loading,
    required this.onRefreshUsage,
    required this.repoName,
    required this.enabled,
    required this.onChanged,
  });

  final WenxiangApi api;
  final bool agentMode;
  final Map<String, dynamic>? usage;
  final bool loading;
  final VoidCallback onRefreshUsage;
  final String repoName;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final label = agentMode ? 'Agent' : '只读';
    final windows = [usage?['primary'], usage?['secondary']]
        .whereType<Map>()
        .where((window) => window['usedPercent'] is num)
        .toList()
      ..sort((a, b) => ((b['windowDurationMins'] as num?) ?? 0)
          .compareTo((a['windowDurationMins'] as num?) ?? 0));
    final window = windows.isEmpty ? null : windows.first;
    final used = ((window?['usedPercent'] as num?) ?? 0).clamp(0, 100).toDouble();
    return Tooltip(
      message: agentMode ? 'Agent：可编辑 $repoName' : '$repoName 只读',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('wx-agent-mode'),
          onTap: enabled ? () => onChanged(!agentMode) : null,
          onLongPress: () {
            onRefreshUsage();
            showDialog<void>(context: context, builder: (context) => AgentDetailsDialog(
              scope: AskEngineScope.repo,
              api: api, agentMode: agentMode, initialUsage: usage,
            ));
          },
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: Wx.motion,
            curve: Wx.motionCurve,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: agentMode ? Wx.accent : Wx.hairline),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SizedBox(
                height: 32,
                child: Stack(
                alignment: Alignment.center,
                children: [
                  Positioned(
                    left: 8, right: 8, bottom: 3,
                    child: _QuotaSegments(
                      used: window == null ? null : used,
                      loading: loading,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 7),
                    child: Text(label, style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, height: 1,
                      color: agentMode ? Wx.accent : Wx.muted,
                    )),
                  ),
                ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Keep the quota slot mounted while only its paint changes.
class _QuotaSegments extends StatefulWidget {
  const _QuotaSegments({required this.used, required this.loading});
  final double? used;
  final bool loading;

  @override
  State<_QuotaSegments> createState() => _QuotaSegmentsState();
}

class _QuotaSegmentsState extends State<_QuotaSegments>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant _QuotaSegments oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.loading && !MediaQuery.disableAnimationsOf(context)) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _pulse,
    builder: (context, _) {
      final used = widget.used;
      return Semantics(
        label: 'Codex \u5269\u4f59\u989d\u5ea6',
        value: widget.loading ? '\u52a0\u8f7d\u4e2d' : used == null ? '\u6682\u4e0d\u53ef\u7528' : '${(100 - used).round()}%',
        child: SizedBox(
          height: 3,
          child: Row(
            key: const Key('wx-codex-usage'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < 5; i++) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(child: DecoratedBox(
                  key: ValueKey('wx-codex-usage-segment-$i'),
                  decoration: BoxDecoration(
                    color: widget.loading
                        ? Color.lerp(Wx.hairline, Wx.accent,
                            (1 - ((_pulse.value * 5 - i + 5) % 5) / 5) * 0.7)
                        : used != null && i < ((100 - used) / 20).ceil()
                            ? (used >= 90 ? Wx.danger : used >= 60 ? Wx.accent : Wx.ok)
                            : Wx.hairline,
                    borderRadius: BorderRadius.circular(1),
                  ),
                )),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.busy,
    this.queueCount = 0,
    this.preparing = false,
    required this.voiceReady,
    required this.voiceInputMode,
    required this.holding,
    required this.holdCancel,
    required this.sttBusy,
    required this.holdLive,
    required this.holdHint,
    required this.voiceHoldTipVisible,
    required this.agentMode,
    required this.onToggleVoiceInput,
    required this.onHoldStart,
    required this.onHoldMove,
    required this.onHoldEnd,
    required this.onCancelRecognize,
    required this.onSend,
    required this.onStop,
    required this.draftBytes,
    required this.imageWait,
    required this.onPickImages,
    required this.onRemoveDraft,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final int queueCount;
  final bool preparing;
  final bool voiceReady;
  final bool voiceInputMode;
  final bool holding;
  final bool holdCancel;
  final bool sttBusy;
  final String holdLive;
  final String holdHint;
  final bool voiceHoldTipVisible;
  final bool agentMode;
  final Future<void> Function() onToggleVoiceInput;
  final Future<void> Function(double globalY) onHoldStart;
  final void Function(double globalY) onHoldMove;
  final Future<void> Function() onHoldEnd;
  final VoidCallback onCancelRecognize;
  final Future<void> Function() onSend;
  final VoidCallback onStop;
  final List<Uint8List> draftBytes;
  final String? imageWait;
  final Future<void> Function() onPickImages;
  final ValueChanged<int> onRemoveDraft;

  bool _canSend(String draft) {
    if (preparing || imageWait != null) return false;
    if (voiceInputMode) return draftBytes.isNotEmpty;
    return draft.trim().isNotEmpty || draftBytes.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final voiceToggleLocked = preparing || sttBusy;
    final showKeyboard = !voiceInputMode;
    final padEnabled = voiceReady && !preparing;
    return ColoredBox(
      color: Wx.bg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (draftBytes.isNotEmpty) ...[
                ChatImageStrip(
                  images: const [],
                  draftBytes: draftBytes,
                  onRemove: imageWait == null ? onRemoveDraft : null,
                ),
                const SizedBox(height: 8),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    key: const Key('wx-voice-toggle'),
                    tooltip: !voiceReady
                        ? '语音未配置'
                        : voiceInputMode
                            ? '键盘输入'
                            : (busy ? '按住说下一条' : '按住说话'),
                    onPressed: voiceToggleLocked && voiceReady ? null : () => onToggleVoiceInput(),
                    icon: Icon(
                      voiceInputMode ? Icons.keyboard_outlined : Icons.mic_none_outlined,
                      color: !voiceReady ? Wx.faint : null,
                    ),
                  ),
                  IconButton(
                    key: const Key('wx-chat-attach'),
                    tooltip: imageWait ??
                        (draftBytes.length >= chatImageMaxCount
                            ? '最多 4 张'
                            : '上传图片'),
                    onPressed:
                        preparing || imageWait != null || holding || sttBusy
                            ? null
                            : () => onPickImages(),
                    icon: const Icon(Icons.image_outlined),
                  ),
                  Expanded(
                    child: AnimatedSize(
                      duration: Wx.motion,
                      curve: Wx.motionCurve,
                      alignment: Alignment.bottomCenter,
                      child: WxAppear(
                        key: ValueKey(showKeyboard ? 'keyboard' : 'voice'),
                        child: showKeyboard
                        ? TextField(
                            key: const Key('wx-chat-input'),
                            controller: controller,
                            focusNode: focus,
                            minLines: 1,
                            maxLines: 6,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) {
                              if (!preparing) onSend();
                            },
                            enabled: !preparing,
                            decoration: InputDecoration(
                              hintText: preparing
                                  ? '正在准备对话…'
                                  : busy
                                      ? '写下一条，答完自动问'
                                      : agentMode
                                          ? '让 Agent 改这个仓库'
                                          : '问这个仓库的进度',
                              filled: true,
                              fillColor: Wx.surface,
                            ),
                          )
                        : WxHoldToSpeakPad(
                            enabled: padEnabled,
                            holding: holding,
                            holdCancel: holdCancel,
                            sttBusy: sttBusy,
                            hint: !voiceReady
                                ? '语音未就绪'
                                : (sttBusy && holdLive.isNotEmpty)
                                    ? holdLive
                                    : holdHint.isNotEmpty
                                        ? holdHint
                                        : sttBusy
                                            ? '识别中，点按取消'
                                            : (busy ? '按住说下一条' : '按住 说话'),
                            onHoldStart: onHoldStart,
                            onHoldMove: onHoldMove,
                            onHoldEnd: onHoldEnd,
                            onCancelRecognize: sttBusy ? onCancelRecognize : null,
                          ),
                      ),
                    ),
                  ),
                  if (!busy) ...[
                    const SizedBox(width: 8),
                    ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) {
                        return SizedBox(
                          width: Wx.tap,
                          height: Wx.tap,
                          child: IconButton.filled(
                            key: const Key('wx-chat-send'),
                            tooltip: '发送',
                            onPressed: _canSend(controller.text) ? onSend : null,
                            icon: const Icon(Icons.arrow_upward, size: 20),
                          ),
                        );
                      },
                    ),
                  ],
                ],
              ),
              if (imageWait != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: WxInlineBusy(
                    imageWait!,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ListenableBuilder(
                    listenable: controller,
                    builder: (context, _) {
                      final draft = controller.text.trim();
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              queueCount > 0
                                  ? '还有 $queueCount 条排队，答完自动问'
                                  : voiceInputMode
                                      ? '按住说下一条，答完自动问'
                                      : voiceReady
                                          ? '可以先写下一条，或按住说话'
                                          : '可以先写下一条',
                              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.muted),
                            ),
                          ),
                          IconButton(
                            key: const Key('wx-chat-stop'),
                            tooltip: queueCount > 0 ? '停止当前并取消排队' : '停止当前',
                            visualDensity: VisualDensity.compact,
                            onPressed: onStop,
                            icon: const Icon(Icons.stop_circle_outlined, size: 26, color: Wx.text),
                          ),
                          const SizedBox(width: 4),
                          FilledButton.icon(
                            key: const Key('wx-chat-send'),
                            onPressed: _canSend(draft) ? onSend : null,
                            icon: const Icon(Icons.arrow_upward, size: 18),
                            label: const Text('排队'),
                          ),
                        ],
                      );
                    },
                  ),
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
      borderRadius: BorderRadius.circular(Wx.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Wx.radius),
        child: Container(
          key: const Key('wx-new-messages-pill'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Wx.radius),
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
              const Icon(Icons.south, size: 16, color: Wx.muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionView {
  TextEditingValue input = TextEditingValue.empty;
  final images = <_DraftImage>[];
  double offset = 0;
  bool readingImages = false;
  bool uploadingImages = false;
}

class _DraftImage {
  _DraftImage({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}
