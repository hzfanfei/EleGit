import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/errors.dart';
import '../copy/voice_stt_copy.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../persist/book_chat_store.dart';
import '../theme.dart';
import '../utils/ask_live_phase.dart';
import '../voice/hold_to_speak_session.dart';
import '../voice/voice_stt_client.dart';
import 'wx_hold_to_speak.dart';
import 'wx_motion.dart';
import 'agent_decision_card.dart';
import 'wx_rich_text.dart';
import 'wx_typewriter_stream.dart';

enum BookAskScope { chapter, all }

enum BookAskSheetLevel { hidden, dock, half, full }

BookAskSheetLevel stepAskSheetUp(BookAskSheetLevel level) {
  switch (level) {
    case BookAskSheetLevel.hidden:
    case BookAskSheetLevel.dock:
      return BookAskSheetLevel.half;
    case BookAskSheetLevel.half:
      return BookAskSheetLevel.full;
    case BookAskSheetLevel.full:
      return BookAskSheetLevel.full;
  }
}

BookAskSheetLevel stepAskSheetDown(BookAskSheetLevel level) {
  switch (level) {
    case BookAskSheetLevel.full:
      return BookAskSheetLevel.half;
    case BookAskSheetLevel.half:
      return BookAskSheetLevel.hidden;
    case BookAskSheetLevel.dock:
    case BookAskSheetLevel.hidden:
      return BookAskSheetLevel.hidden;
  }
}

/// Expanded ask sheet (~3/4 viewport).
const kBookAskHalfFraction = 3 / 4;
const kBookAskFullFraction = 1.0;

double askBottomSafeInset(MediaQueryData media) {
  final view = media.viewPadding.bottom;
  return view > 0 ? view : media.padding.bottom;
}

double _askBottomSafeInset(BuildContext context) {
  return askBottomSafeInset(MediaQuery.of(context));
}

/// Space the reader must reserve for the ask sheet.
/// Ignores a leftover expanded measurement after collapsing to dock.
double bookReaderAskReserve({
  required BookAskSheetLevel level,
  required double viewportHeight,
  required double estimatedDockHeight,
  double measuredHeight = 0,
  double dockSlack = 32,
  double estimatedHiddenHeight = 0,
}) {
  switch (level) {
    case BookAskSheetLevel.hidden:
      return estimatedHiddenHeight;
    case BookAskSheetLevel.dock:
      if (measuredHeight > 0 &&
          (measuredHeight - estimatedDockHeight).abs() <= dockSlack) {
        return measuredHeight;
      }
      return estimatedDockHeight;
    case BookAskSheetLevel.half:
      return viewportHeight * kBookAskHalfFraction;
    case BookAskSheetLevel.full:
      return viewportHeight * kBookAskFullFraction;
  }
}

/// Bottom dock for Q&A while reading — compact by default, expands for full answers.
class BookAskPanel extends StatefulWidget {
  const BookAskPanel({
    super.key,
    required this.api,
    required this.book,
    required this.scrollController,
    required this.sheetSize,
    this.sheetController,
    this.sheetSnaps = const [0.0, kBookAskHalfFraction, kBookAskFullFraction],
    this.expanded,
    this.hidden = false,
    this.fullscreen = false,
    this.chapterHint = '',
    this.readingPlace,
    this.memory,
    this.sttClient,
    this.onRequestExpand,
    this.onRequestStepUp,
    this.onRequestCollapse,
  });

  final WenxiangApi api;
  final BookItem book;
  final ScrollController scrollController;
  final ValueNotifier<double> sheetSize;
  final DraggableScrollableController? sheetController;
  final List<double> sheetSnaps;
  final bool? expanded;
  final bool hidden;
  final bool fullscreen;
  final String chapterHint;
  final ValueNotifier<BookReadingPlace>? readingPlace;
  final AppMemory? memory;
  final VoiceSttClient? sttClient;
  final VoidCallback? onRequestExpand;
  final VoidCallback? onRequestStepUp;
  final VoidCallback? onRequestCollapse;

  /// Between hidden and three-quarters expanded.
  static const collapsedThreshold = 0.375;

  /// Tight dock: handle + title + composer + home-indicator inset.
  static double estimatedDockHeight(
    MediaQueryData media, {
    bool hasPeek = false,
    bool showLive = false,
  }) {
    const chrome = 8 + 11 + 43;
    const peek = 24.0;
    const live = 34.0;
    const composer = 60.0;
    return chrome +
        (hasPeek ? peek : 0) +
        (showLive ? live : 0) +
        composer +
        media.padding.bottom;
  }

  /// Hidden peek: handle + home-indicator inset so the user can pull it back.
  static double estimatedHiddenHeight(MediaQueryData media) {
    return 8 + 11 + askBottomSafeInset(media);
  }

  @override
  State<BookAskPanel> createState() => BookAskPanelState();
}

class BookAskPanelState extends State<BookAskPanel> with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final List<ChatMessage> _messages = [];
  late final WxTypewriterStream _typewriter;
  late final HoldToSpeakSession _hold;
  late final AnimationController _pulse;
  final _livePhase = ValueNotifier<String>('connect');
  final _liveActivity = ValueNotifier<String>('');
  final _phaseElapsed = ValueNotifier<int>(0);
  Timer? _livePhaseTimer;
  String _livePhaseChapter = '';
  String? _sessionId;
  bool _live = false;
  bool _busy = false;
  bool _voiceReady = false;
  bool _voiceInputMode = false;
  String _voiceHint = '';
  String? _peekAnswer;
  ChatStreamEvent? _decision;
  int? _appearUserAt;
  BookChatStore _store = BookChatStore.empty();
  String _anchorId = 'start';
  BookReadingPlace _place = const BookReadingPlace();
  BookAskScope _scope = BookAskScope.chapter;

  bool get _expanded =>
      widget.expanded ?? widget.sheetSize.value > BookAskPanel.collapsedThreshold;

  BookReadingPlace get _effectivePlace =>
      widget.readingPlace?.value ?? BookReadingPlace(chapter: widget.chapterHint);

  @override
  void initState() {
    super.initState();
    _restoreLocal();
    widget.readingPlace?.addListener(_onReadingPlaceChanged);
    _pulse = AnimationController(vsync: this, duration: Wx.breath)
      ..repeat(reverse: true);
    _typewriter = WxTypewriterStream(onReveal: () {
      if (mounted) setState(() {});
      _scrollToEnd();
    });
    _hold = HoldToSpeakSession(
      api: widget.api,
      sttClient: widget.sttClient,
      onChanged: () {
        if (mounted) setState(() {});
      },
      onTranscript: (text) => _send(text),
      onError: (msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
        );
      },
    );
    widget.sheetSize.addListener(_onSheetSize);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncAnchorFromPlace(_effectivePlace, initial: true);
      _ensureSession();
      _loadVoice();
    });
  }

  @override
  void didUpdateWidget(covariant BookAskPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.readingPlace != widget.readingPlace) {
      oldWidget.readingPlace?.removeListener(_onReadingPlaceChanged);
      widget.readingPlace?.addListener(_onReadingPlaceChanged);
    }
    if (oldWidget.chapterHint != widget.chapterHint && widget.readingPlace == null) {
      _syncAnchorFromPlace(_effectivePlace);
    }
  }

  void _onReadingPlaceChanged() {
    _syncAnchorFromPlace(_effectivePlace);
  }

  void _restoreLocal() {
    final stored = widget.memory?.loadBookChats(widget.book.id);
    if (stored == null) return;
    if (stored.anchors.isEmpty && (stored.sessionId == null || stored.sessionId!.isEmpty)) {
      return;
    }
    _store = stored;
    _sessionId = stored.sessionId;
  }

  void _syncAnchorFromPlace(BookReadingPlace place, {bool initial = false}) {
    final nextId = bookAnchorId(place);
    if (nextId == _anchorId) {
      _place = place;
      return;
    }
    if (!initial) {
      _flushAnchorToStore();
    }
    _anchorId = nextId;
    _place = place;
    _messages
      ..clear()
      ..addAll(_store.messagesForAnchor(_anchorId));
    _peekAnswer = _store.lastAssistantPeek(_anchorId);
    if (mounted) setState(() {});
  }

  void _flushAnchorToStore() {
    if (_messages.isEmpty && !_store.anchors.containsKey(_anchorId)) return;
    _store = _store.upsertAnchorMessages(
      anchorId: _anchorId,
      place: _place,
      messages: List<ChatMessage>.from(_messages),
    );
  }

  Future<void> _persistStore() async {
    _flushAnchorToStore();
    _store = BookChatStore(
      sessionId: _sessionId,
      activeAnchorId: _anchorId,
      anchors: _store.anchors,
    );
    await widget.memory?.saveBookChats(widget.book.id, _store);
  }

  /// Chat history for quick-voice API context (current anchor or stored chapter).
  List<ChatMessage> chatHistoryForVoice(BookReadingPlace place) {
    final anchorId = bookAnchorId(place);
    if (anchorId == _anchorId) {
      return _messages.where((m) => m.role != 'error').toList();
    }
    return _store.messagesForAnchor(anchorId).where((m) => m.role != 'error').toList();
  }

  /// Persist a completed quick-voice turn into the same store as typed Q&A.
  Future<void> recordVoiceTurn({
    required BookReadingPlace place,
    required String question,
    required String answer,
    String? engine,
    String? sessionId,
  }) async {
    final anchorId = bookAnchorId(place);
    final base = anchorId == _anchorId
        ? List<ChatMessage>.from(_messages)
        : List<ChatMessage>.from(_store.messagesForAnchor(anchorId));
    base.addAll([
      ChatMessage(role: 'user', content: question, via: 'voice'),
      ChatMessage(role: 'assistant', content: answer, engine: engine, via: 'voice'),
    ]);
    _store = _store.upsertAnchorMessages(
      anchorId: anchorId,
      place: place,
      messages: base,
    );
    if (sessionId != null && sessionId.isNotEmpty) {
      _sessionId = sessionId;
    }
    if (anchorId == _anchorId) {
      _messages
        ..clear()
        ..addAll(base);
      _appearUserAt = _messages.length >= 2 ? _messages.length - 2 : null;
      _peekAnswer = answer;
      _place = place;
    }
    await _persistStore();
    if (mounted) setState(() {});
  }

  void _onSheetSize() {
    if (mounted) setState(() {});
  }

  Future<void> _ensureSession() async {
    try {
      var list = await widget.api.listBookSessions(widget.book.id);
      final keep = _sessionId;
      if (keep != null && keep.isNotEmpty && list.any((s) => s.id == keep)) {
        return;
      }
      if (list.isEmpty) {
        final created = await widget.api.createBookSession(widget.book.id);
        list = [created];
      }
      if (!mounted) return;
      setState(() {
        _sessionId = list.firstWhere((s) => s.active, orElse: () => list.first).id;
      });
      unawaited(_persistStore());
    } catch (_) {}
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
        _voiceHint = '语音暂不可用';
      });
    }
  }

  String _withReadingContext(String message) {
    final hint = _place.chapter.trim();
    final cfi = _place.epubCfi?.trim() ?? '';
    if (hint.isEmpty && cfi.isEmpty) return message;
    final buf = StringBuffer(message);
    buf.write('\n\n（阅读位置');
    if (hint.isNotEmpty) buf.write('：$hint');
    if (cfi.isNotEmpty) buf.write(hint.isEmpty ? ' CFI：$cfi' : ' · $cfi');
    buf.write('）');
    return buf.toString();
  }

  Future<void> _submitDecision({
    required String kind,
    required bool skip,
    required bool accept,
    required List<Map<String, dynamic>> answers,
  }) async {
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
    if (!mounted) return;
    setState(() => _decision = null);
  }

  Future<void> _send([String? text]) async {
    final raw = (text ?? _input.text).trim();
    if (raw.isEmpty || _busy) return;
    final message = _withReadingContext(raw);
    HapticFeedback.lightImpact();
    _input.clear();
    _livePhaseChapter = _place.chapter.trim();
    _livePhase.value = 'book';
    _liveActivity.value = '';
    _phaseElapsed.value = 0;
    _startLivePhaseFallback();
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: raw));
      _appearUserAt = _messages.length - 1;
      _busy = true;
      _live = true;
      _peekAnswer = null;
      _decision = null;
    });
    if (!_expanded) _expandForAnswer();
    _scrollToEnd();
    _typewriter.reset();
    try {
      await for (final event in widget.api.bookChatStream(
        bookId: widget.book.id,
        message: message,
        history: _messages.where((m) => m.role != 'error').toList(),
        sessionId: _sessionId,
        chapter: _place.chapter.trim().isEmpty ? null : _place.chapter.trim(),
      )) {
        if (!mounted) return;
        if (event.sessionId != null && event.sessionId!.isNotEmpty) {
          _sessionId = event.sessionId;
        }
        switch (event.type) {
          case 'status':
            final phase = event.phase?.trim() ?? '';
            final detail = event.detail?.trim() ?? '';
            if (phase == 'activity') {
              _liveActivity.value = detail;
            } else if (phase.isNotEmpty) {
              _livePhase.value = phase;
              if (detail.isNotEmpty) _liveActivity.value = detail;
            }
            break;
          case 'ask':
          case 'plan':
            setState(() => _decision = event);
            break;
          case 'delta':
            _typewriter.push(event.text);
            break;
          case 'done':
            _typewriter.flushNow();
            final answer = _typewriter.fullText;
            setState(() {
              if (answer.isNotEmpty) {
                _messages.add(ChatMessage(
                  role: 'assistant',
                  content: answer,
                  engine: event.engine,
                ));
                _peekAnswer = answer;
              }
              _live = false;
            });
            _typewriter.reset();
            break;
          case 'error':
            setState(() {
              _messages.add(ChatMessage(role: 'error', content: event.error ?? '问书失败'));
              _live = false;
            });
            _typewriter.reset();
            break;
        }
      }
    } on OperationCancelled {
      if (!mounted) return;
      _typewriter.flushNow();
      final partial = _typewriter.fullText;
      setState(() {
        if (partial.isNotEmpty) {
          _messages.add(ChatMessage(role: 'assistant', content: partial));
          _peekAnswer = partial;
        }
        _live = false;
      });
      _typewriter.reset();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(role: 'error', content: humanizeError(err)));
        _live = false;
      });
      _typewriter.reset();
    } finally {
      _stopLivePhaseFallback();
      if (mounted) {
        setState(() {
          _busy = false;
          _live = false;
        });
        unawaited(_persistStore());
      }
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    if (!_expanded) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.scrollController.hasClients) return;
      widget.scrollController.animateTo(
        widget.scrollController.position.maxScrollExtent,
        duration: Wx.motion,
        curve: Wx.motionCurve,
      );
    });
  }

  void _toggleVoice() {
    if (!_voiceReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_voiceHint.isEmpty ? '语音未配置' : _voiceHint)),
      );
      return;
    }
    if (_busy || _hold.active) return;
    HapticFeedback.selectionClick();
    setState(() => _voiceInputMode = !_voiceInputMode);
  }

  void _expandForAnswer() {
    HapticFeedback.lightImpact();
    widget.onRequestExpand?.call();
  }

  void _stepUp() {
    HapticFeedback.lightImpact();
    (widget.onRequestStepUp ?? widget.onRequestExpand)?.call();
  }

  void _onChromeDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -240) {
      _stepUp();
    } else if (velocity > 240) {
      widget.onRequestCollapse?.call();
    }
  }

  Widget _sheetChrome({required Widget child, bool tapToExpand = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: (_) {},
      onVerticalDragEnd: _onChromeDragEnd,
      onTap: widget.hidden
          ? widget.onRequestStepUp
          : (tapToExpand ? _expandForAnswer : widget.onRequestCollapse),
      child: child,
    );
  }

  void _setScope(BookAskScope scope) {
    if (_scope == scope) return;
    HapticFeedback.selectionClick();
    setState(() => _scope = scope);
    if (scope == BookAskScope.all) {
      _expandForAnswer();
    }
  }

  void _reloadCurrentAnchorFromStore() {
    _messages
      ..clear()
      ..addAll(_store.messagesForAnchor(_anchorId));
    _peekAnswer = _store.lastAssistantPeek(_anchorId);
  }

  Future<void> _applyStore(BookChatStore next) async {
    _store = next;
    _reloadCurrentAnchorFromStore();
    if (mounted) setState(() {});
    await _persistStore();
  }

  Future<void> _deleteTurn(BookQaTurn turn) async {
    if (_busy) return;
    final next = _store.deleteTurn(turn.anchorId, turn.userMessageIndex);
    await _applyStore(next);
  }

  Future<void> _confirmDeleteTurn(BookQaTurn turn) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条问答？'),
        content: Text(
          turn.user.content.length > 80 ? '${turn.user.content.substring(0, 80)}…' : turn.user.content,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await _deleteTurn(turn);
  }

  Future<void> _confirmDeleteCurrentChapter() async {
    if (_busy) return;
    final label = _place.chapter.trim().isEmpty ? '当前位置' : _place.chapter.trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除本章全部问答？'),
        content: Text('将清除「$label」下的所有问书记录，且无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除本章')),
        ],
      ),
    );
    if (ok != true) return;
    final next = _store.removeAnchor(_anchorId);
    await _applyStore(next);
  }

  Future<void> _confirmDeleteAllBook() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除全书问书记录？'),
        content: Text('将清除《${widget.book.title}》的全部本地问答，且无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('全部删除')),
        ],
      ),
    );
    if (ok != true) return;
    final next = _store.clearAnchors();
    await _applyStore(next);
  }

  Future<void> _onHistoryMenu(String value) async {
    switch (value) {
      case 'chapter':
        await _confirmDeleteCurrentChapter();
        break;
      case 'all':
        await _confirmDeleteAllBook();
        break;
    }
  }

  BookQaTurn _turnAtChapterIndex(int userIndex) {
    final replies = <ChatMessage>[];
    var j = userIndex + 1;
    while (j < _messages.length && _messages[j].role != 'user') {
      replies.add(_messages[j]);
      j++;
    }
    return BookQaTurn(
      anchorId: _anchorId,
      chapter: _place.chapter.trim().isEmpty ? '未标注章节' : _place.chapter.trim(),
      userMessageIndex: userIndex,
      user: _messages[userIndex],
      replies: replies,
      updatedAt: _store.anchors[_anchorId]?.updatedAt ?? '',
    );
  }

  void _setLivePhase(String phase) {
    if (phase.isEmpty || _livePhase.value == phase) return;
    _livePhase.value = phase;
  }

  void _startLivePhaseFallback() {
    _livePhaseTimer?.cancel();
    final sentAt = DateTime.now();
    _livePhaseTimer = Timer.periodic(const Duration(milliseconds: 400), (timer) {
      if (!mounted || !_live || _typewriter.visible.value.isNotEmpty) {
        timer.cancel();
        return;
      }
      final elapsed = DateTime.now().difference(sentAt);
      _phaseElapsed.value = elapsed.inSeconds;
      final next = nextAskLiveFallbackPhase(
        current: _livePhase.value,
        elapsed: elapsed,
        book: true,
      );
      if (next != null) _setLivePhase(next);
    });
  }

  void _stopLivePhaseFallback() {
    _livePhaseTimer?.cancel();
    _livePhaseTimer = null;
    _phaseElapsed.value = 0;
    _livePhaseChapter = '';
  }

  @override
  void dispose() {
    _stopLivePhaseFallback();
    widget.readingPlace?.removeListener(_onReadingPlaceChanged);
    unawaited(_persistStore());
    widget.sheetSize.removeListener(_onSheetSize);
    _livePhase.dispose();
    _liveActivity.dispose();
    _phaseElapsed.dispose();
    _pulse.dispose();
    _hold.dispose();
    _input.dispose();
    _typewriter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expanded = _expanded;
    final showLive = (_hold.holding || _hold.sttBusy) && _hold.holdLive.isNotEmpty;
    final hasPeek = _peekAnswer != null || _live;

    return ClipRRect(
      borderRadius: BorderRadius.vertical(top: Radius.circular(widget.fullscreen ? 0 : Wx.radius)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Wx.raised.withValues(alpha: 0.92),
                Wx.bg.withValues(alpha: 0.97),
              ],
            ),
            border: Border(
              top: BorderSide(color: Wx.accent.withValues(alpha: _live || _busy ? 0.45 : 0.22)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: (widget.hidden || !expanded)
              ? SizedBox.expand(
                  child: _sheetChrome(
                    tapToExpand: true,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: _DragHandle(
                          expanded: false,
                          hidden: widget.hidden,
                        ),
                      ),
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    _sheetChrome(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            height: widget.fullscreen
                                ? MediaQuery.viewPaddingOf(context).top + 6
                                : 10,
                          ),
                          _DragHandle(expanded: true, fullscreen: widget.fullscreen),
                          _AskHeaderRow(
                            theme: theme,
                            expanded: true,
                            fullscreen: widget.fullscreen,
                            place: _place,
                            live: _live || _busy,
                            hasPeek: hasPeek,
                            showAllScope: false,
                            onAllScope: () => _setScope(BookAskScope.all),
                            onExpandAnswer: _expandForAnswer,
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Wx.inset, 0, 8, 6),
                      child: Row(
                        children: [
                          _ScopeChip(
                            label: '本章',
                            selected: _scope == BookAskScope.chapter,
                            onTap: () => _setScope(BookAskScope.chapter),
                          ),
                          const SizedBox(width: 8),
                          _ScopeChip(
                            label: '历史',
                            selected: _scope == BookAskScope.all,
                            onTap: () => _setScope(BookAskScope.all),
                          ),
                          const Spacer(),
                          if (_store.hasAnyMessages)
                            PopupMenuButton<String>(
                              tooltip: '管理记录',
                              icon: Icon(Icons.more_horiz, color: Wx.muted.withValues(alpha: 0.95)),
                              onSelected: _onHistoryMenu,
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: 'chapter',
                                  enabled: _store.anchors.containsKey(_anchorId) &&
                                      (_store.messagesForAnchor(_anchorId).isNotEmpty),
                                  child: const Text('删除本章记录'),
                                ),
                                const PopupMenuItem(
                                  value: 'all',
                                  child: Text('删除全书记录'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    if (_scope == BookAskScope.all)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 8),
                        child: Text(
                          '仅切换本地问书记录视图，提问仍基于当前阅读位置。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Wx.faint,
                            height: 1.35,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    Expanded(
                      child: _scope == BookAskScope.all
                          ? _AllQaHistoryList(
                              scrollController: widget.scrollController,
                              turns: listAllBookQaTurns(_store),
                              live: _live,
                              typewriter: _typewriter,
                              phase: _livePhase,
                              activity: _liveActivity,
                              elapsed: _phaseElapsed,
                              chapter: _livePhaseChapter,
                              onDeleteTurn: _confirmDeleteTurn,
                            )
                          : ListView.builder(
                              controller: widget.scrollController,
                              padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 8),
                              itemCount: _messages.length + (_live ? 1 : 0),
                              itemBuilder: (context, index) {
                                if (_live && index == _messages.length) {
                                  return _AskBubble(
                                    role: 'assistant',
                                    streaming: true,
                                    child: _BookAskLiveText(
                                      typewriter: _typewriter,
                                      phase: _livePhase,
                                      activity: _liveActivity,
                                      elapsed: _phaseElapsed,
                                      chapter: _livePhaseChapter,
                                    ),
                                  );
                                }
                                final msgIndex = index;
                                final msg = _messages[msgIndex];
                                final row = _ChapterMessageRow(
                                  message: msg,
                                  onDelete: msg.role == 'user' && !_busy
                                      ? () =>
                                          unawaited(_confirmDeleteTurn(_turnAtChapterIndex(msgIndex)))
                                      : null,
                                  child: _MessageBody(message: msg),
                                );
                                if (msg.role == 'user' && msgIndex == _appearUserAt) {
                                  return WxAppear(child: row);
                                }
                                return row;
                              },
                            ),
                    ),
                    if (_decision != null)
                      WxAppear(
                        key: ValueKey('book-decision-${_decision!.payload?['requestId'] ?? _decision.hashCode}'),
                        child: AgentDecisionCard(
                          event: _decision!,
                          onSubmit: _submitDecision,
                        ),
                      ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        14,
                        0,
                        14,
                        8 +
                            (MediaQuery.viewInsetsOf(context).bottom > 0
                                ? 0
                                : _askBottomSafeInset(context)),
                      ),
                      child: _ComposerIsland(
                        voiceInputMode: _voiceInputMode,
                        voiceReady: _voiceReady,
                        busy: _busy,
                        hold: _hold,
                        input: _input,
                        onToggleVoice: _toggleVoice,
                        onSend: () => _send(),
                        onStop: () => widget.api.cancelChat(sessionId: _sessionId),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.expanded, this.fullscreen = false, this.hidden = false});

  final bool expanded;
  final bool fullscreen;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: hidden
          ? '上滑回到问书'
          : fullscreen
          ? '下滑回到半屏'
          : (expanded ? '上滑全屏，下滑收起' : '上滑展开解答，下滑隐藏'),
      child: Container(
        width: 44,
        height: 5,
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: Wx.muted.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }
}

class _AskHeaderRow extends StatelessWidget {
  const _AskHeaderRow({
    required this.theme,
    required this.expanded,
    this.fullscreen = false,
    required this.place,
    required this.live,
    required this.hasPeek,
    required this.showAllScope,
    required this.onAllScope,
    required this.onExpandAnswer,
  });

  final ThemeData theme;
  final bool expanded;
  final bool fullscreen;
  final BookReadingPlace place;
  final bool live;
  final bool hasPeek;
  final bool showAllScope;
  final VoidCallback onAllScope;
  final VoidCallback onExpandAnswer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Wx.inset, expanded ? 4 : 2, Wx.inset, expanded ? 6 : 4),
      child: Row(
        children: [
          _AskBadge(live: live),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              fullscreen
                  ? (place.chapter.isEmpty ? '全屏解答 · 下滑回到半屏' : '全屏 · ${place.chapter}')
                  : expanded
                      ? (place.chapter.isEmpty ? '解答区 · 上滑全屏' : '本章 · ${place.chapter}')
                      : (place.chapter.isEmpty ? '问书 · 上滑展开' : '本章问书 · ${place.chapter}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: Wx.muted,
                fontSize: 12,
                letterSpacing: 0.25,
              ),
            ),
          ),
          if (expanded && showAllScope)
            TextButton(
              onPressed: onAllScope,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('历史'),
            ),
          if (!expanded && hasPeek)
            TextButton(
              onPressed: onExpandAnswer,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('展开'),
            ),
        ],
      ),
    );
  }
}

class _AskBadge extends StatelessWidget {
  const _AskBadge({required this.live});

  final bool live;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Wx.motion,
      curve: Wx.motionCurve,
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: live ? Wx.accent.withValues(alpha: 0.22) : Wx.surface,
        borderRadius: BorderRadius.circular(Wx.radius),
        border: Border.all(color: live ? Wx.accent.withValues(alpha: 0.55) : Wx.hairline),
      ),
      child: Text(
        '问',
        style: TextStyle(
          fontFamily: Wx.serif,
          fontFamilyFallback: Wx.fontFallback,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: live ? Wx.accent : Wx.muted,
          height: 1,
        ),
      ),
    );
  }
}

class _CollapsedHint extends StatelessWidget {
  const _CollapsedHint({required this.voiceReady});

  final bool voiceReady;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          voiceReady ? Icons.graphic_eq_rounded : Icons.chat_bubble_outline,
          size: 18,
          color: Wx.faint,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            voiceReady ? '按住下方说话，松手即问' : '输入问题，或配置语音后按住说话',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.faint, height: 1.35),
          ),
        ),
      ],
    );
  }
}

class _AnswerPeekCard extends StatelessWidget {
  const _AnswerPeekCard({
    required this.pulse,
    required this.streaming,
    required this.onTap,
    this.text,
    this.staticText,
  });

  final Animation<double> pulse;
  final bool streaming;
  final ValueListenable<String>? text;
  final String? staticText;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final glow = streaming ? 0.25 + pulse.value * 0.2 : 0.12;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Wx.radius),
            child: Ink(
              decoration: BoxDecoration(
                color: Wx.surface.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(Wx.radius),
                border: Border.all(color: Wx.accent.withValues(alpha: glow)),
              ),
              child: child,
            ),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    streaming ? '正在回答' : '最新解答',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Wx.accent,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (streaming && text != null)
                    ValueListenableBuilder<String>(
                      valueListenable: text!,
                      builder: (_, value, __) => Text(
                        value.isEmpty ? '…' : value,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Wx.text,
                          height: 1.4,
                        ),
                      ),
                    )
                  else
                    Text(
                      staticText ?? '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Wx.text,
                        height: 1.4,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.unfold_more_rounded, size: 20, color: Wx.muted.withValues(alpha: 0.9)),
          ],
        ),
      ),
    );
  }
}

class _ComposerIsland extends StatelessWidget {
  const _ComposerIsland({
    required this.voiceInputMode,
    required this.voiceReady,
    required this.busy,
    required this.hold,
    required this.input,
    required this.onToggleVoice,
    required this.onSend,
    required this.onStop,
  });

  final bool voiceInputMode;
  final bool voiceReady;
  final bool busy;
  final HoldToSpeakSession hold;
  final TextEditingController input;
  final VoidCallback onToggleVoice;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Wx.surface.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(Wx.radius),
        border: Border.all(color: Wx.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: voiceInputMode ? '键盘输入' : '按住说话',
              visualDensity: VisualDensity.compact,
              onPressed: (busy || hold.active) && voiceReady ? null : onToggleVoice,
              icon: Icon(
                voiceInputMode ? Icons.keyboard_alt_outlined : Icons.mic_rounded,
                size: 22,
                color: !voiceReady
                    ? Wx.faint
                    : (voiceInputMode ? Wx.accent : Wx.text),
              ),
            ),
            Expanded(
              child: AnimatedSize(
                duration: Wx.motion,
                curve: Wx.motionCurve,
                alignment: Alignment.bottomCenter,
                child: WxAppear(
                  key: ValueKey(voiceInputMode ? 'voice' : 'keyboard'),
                  child: voiceInputMode
                  ? WxHoldToSpeakPad(
                      enabled: voiceReady && ((!busy) || hold.sttBusy),
                      holding: hold.holding,
                      holdCancel: hold.holdCancel,
                      sttBusy: hold.sttBusy,
                      hint: !voiceReady
                          ? '语音未就绪'
                          : busy
                              ? '回答中…'
                              : (hold.sttBusy && hold.holdLive.isNotEmpty)
                                  ? hold.holdLive
                                  : hold.holdHint.isNotEmpty
                                      ? hold.holdHint
                                      : (hold.sttBusy ? '识别中，点按取消' : '按住 说话'),
                      onHoldStart: hold.beginHold,
                      onHoldMove: hold.moveHold,
                      onHoldEnd: hold.endHold,
                      onCancelRecognize:
                          hold.sttBusy ? () => unawaited(hold.cancelRecognition()) : null,
                    )
                  : TextField(
                      controller: input,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: busy ? null : (_) => onSend(),
                      decoration: const InputDecoration(
                        hintText: '问这段内容…',
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                      ),
                    ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            SizedBox(
              width: 44,
              height: 44,
              child: busy
                  ? IconButton(
                      tooltip: '停止',
                      onPressed: onStop,
                      icon: const Icon(Icons.stop_circle_outlined, color: Wx.accent),
                    )
                  : IconButton.filled(
                      tooltip: '发送',
                      onPressed: voiceInputMode ? null : onSend,
                      style: IconButton.styleFrom(
                        backgroundColor: Wx.accent,
                        foregroundColor: Wx.onAccent,
                      ),
                      icon: const Icon(Icons.arrow_upward, size: 20),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookAskLiveText extends StatelessWidget {
  const _BookAskLiveText({
    required this.typewriter,
    required this.phase,
    required this.activity,
    required this.elapsed,
    required this.chapter,
  });

  final WxTypewriterStream typewriter;
  final ValueNotifier<String> phase;
  final ValueNotifier<String> activity;
  final ValueNotifier<int> elapsed;
  final String chapter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<String>(
      valueListenable: typewriter.visible,
      builder: (_, text, __) {
        if (text.isNotEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: WxReadableText(text)),
                  const SizedBox(width: 6),
                  _JumpToEndButton(typewriter: typewriter),
                ],
              ),
              ValueListenableBuilder<String>(
                valueListenable: activity,
                builder: (_, liveActivity, __) {
                  if (liveActivity.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      liveActivity,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: Wx.muted,
                        height: 1.4,
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        }
        return ValueListenableBuilder<String>(
          valueListenable: activity,
          builder: (_, liveActivity, __) {
            if (liveActivity.isNotEmpty) {
              return Semantics(
                liveRegion: true,
                child: Text(
                  liveActivity,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Wx.muted,
                    height: 1.45,
                  ),
                ),
              );
            }
            return ValueListenableBuilder<String>(
              valueListenable: phase,
              builder: (_, livePhase, __) {
                return ValueListenableBuilder<int>(
                  valueListenable: elapsed,
                  builder: (_, elapsedSec, __) {
                    return Semantics(
                      liveRegion: true,
                      child: Text(
                        askLivePhaseLabel(
                          livePhase,
                          book: true,
                          chapter: chapter,
                          secondsElapsed: elapsedSec,
                        ),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Wx.muted,
                          height: 1.45,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _JumpToEndButton extends StatelessWidget {
  const _JumpToEndButton({required this.typewriter});

  final WxTypewriterStream typewriter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => typewriter.animateToEnd(
        budget: const Duration(milliseconds: 400),
      ),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          '⏩ 跳到末尾',
          style: theme.textTheme.labelSmall?.copyWith(
            color: Wx.faint,
            letterSpacing: 0.2,
          ),
        ),
      ),
    );
  }
}

class _AskBubble extends StatelessWidget {
  const _AskBubble({
    required this.role,
    required this.child,
    this.streaming = false,
  });

  final String role;
  final Widget child;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    final isError = role == 'error';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 480),
        decoration: BoxDecoration(
          color: isError
              ? Wx.danger.withValues(alpha: 0.12)
              : (isUser
                  ? Wx.accent.withValues(alpha: 0.16)
                  : Wx.hairline.withValues(alpha: 0.45)),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(Wx.radius),
            topRight: const Radius.circular(Wx.radius),
            bottomLeft: Radius.circular(isUser ? Wx.radius : 3),
            bottomRight: Radius.circular(isUser ? 3 : Wx.radius),
          ),
          border: streaming
              ? Border.all(color: Wx.accent.withValues(alpha: 0.35))
              : null,
        ),
        child: child,
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Wx.accent.withValues(alpha: 0.2) : Wx.surface,
      borderRadius: BorderRadius.circular(Wx.radius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Wx.radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? Wx.accent : Wx.muted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
          ),
        ),
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final voice = message.via == 'voice';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (voice)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mic_none_rounded, size: 13, color: Wx.muted),
                const SizedBox(width: 4),
                Text(
                  '快问快答',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Wx.muted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        WxReadableText(message.content),
      ],
    );
  }
}

class _ChapterMessageRow extends StatelessWidget {
  const _ChapterMessageRow({
    required this.message,
    required this.child,
    this.onDelete,
  });

  final ChatMessage message;
  final Widget child;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _AskBubble(role: message.role, child: child),
        ),
        if (onDelete != null)
          IconButton(
            tooltip: '删除这条问答',
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
            icon: Icon(Icons.delete_outline, size: 18, color: Wx.faint.withValues(alpha: 0.9)),
          ),
      ],
    );
  }
}

class _AllQaHistoryList extends StatelessWidget {
  const _AllQaHistoryList({
    required this.scrollController,
    required this.turns,
    required this.live,
    required this.typewriter,
    required this.phase,
    required this.activity,
    required this.elapsed,
    required this.chapter,
    required this.onDeleteTurn,
  });

  final ScrollController scrollController;
  final List<BookQaTurn> turns;
  final bool live;
  final WxTypewriterStream typewriter;
  final ValueNotifier<String> phase;
  final ValueNotifier<String> activity;
  final ValueNotifier<int> elapsed;
  final String chapter;
  final Future<void> Function(BookQaTurn turn) onDeleteTurn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (turns.isEmpty && !live) {
      return Center(
        child: Padding(
          padding: Wx.pagePadding,
          child: Text(
            '还没有问书记录。在本章提问后会按章节保存在本地。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint, height: 1.45),
          ),
        ),
      );
    }

    final extra = live ? 1 : 0;
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 8),
      itemCount: turns.length + extra,
      itemBuilder: (context, index) {
        if (live && index == turns.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _AskBubble(
              role: 'assistant',
              streaming: true,
              child: _BookAskLiveText(
                typewriter: typewriter,
                phase: phase,
                activity: activity,
                elapsed: elapsed,
                chapter: chapter,
              ),
            ),
          );
        }
        final turn = turns[index];
        final showHeader = index == 0 || turn.chapter != turns[index - 1].chapter;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              Padding(
                padding: EdgeInsets.only(top: index == 0 ? 0 : 14, bottom: 8),
                child: Text(
                  turn.chapter,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Wx.accent,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            _QaTurnCard(
              turn: turn,
              onDelete: () => onDeleteTurn(turn),
            ),
          ],
        );
      },
    );
  }
}

class _QaTurnCard extends StatefulWidget {
  const _QaTurnCard({
    required this.turn,
    required this.onDelete,
  });

  final BookQaTurn turn;
  final VoidCallback onDelete;

  @override
  State<_QaTurnCard> createState() => _QaTurnCardState();
}

class _QaTurnCardState extends State<_QaTurnCard> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final turn = widget.turn;
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Wx.surface.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(Wx.radius),
        border: Border.all(color: Wx.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => setState(() => _open = !_open),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(Wx.radius),
                    bottomLeft: Radius.circular(Wx.radius),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _AskBubble(
                          role: 'user',
                          child: _MessageBody(message: turn.user),
                        ),
                        AnimatedSize(
                          duration: Wx.motion,
                          curve: Wx.motionCurve,
                          alignment: Alignment.topCenter,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_open)
                                for (final reply in turn.replies)
                                  _AskBubble(
                                    role: reply.role,
                                    child: _MessageBody(message: reply),
                                  )
                              else if (turn.replies.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '展开回答',
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Wx.faint,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: _open ? '收起回答' : '展开回答',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _open = !_open),
                    icon: Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: Wx.muted,
                    ),
                  ),
                  IconButton(
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onDelete,
                    icon: Icon(Icons.delete_outline, size: 18, color: Wx.faint),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
