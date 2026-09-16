import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/errors.dart';
import '../copy/time.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../voice/voice_client.dart';
import '../voice/voice_media.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_rich_text.dart';
import 'call_page.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.api,
    required this.repo,
    required this.onBack,
    this.memory,
    this.voiceMedia,
    this.voiceClient,
  });

  final WenxiangApi api;
  final RepoItem repo;
  final VoidCallback onBack;
  final AppMemory? memory;
  final VoiceMedia? voiceMedia;
  final VoiceCallClient? voiceClient;

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
  final ValueNotifier<String> _liveText = ValueNotifier('');
  final ValueNotifier<String?> _liveEngine = ValueNotifier(null);
  String? _sessionId;
  bool _live = false;
  bool _busy = false;
  String? _lastUser;
  String _voiceHint = '还没配语音密钥';

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
    _restoreLocal();
    _loadSessions();
    _loadVoice();
  }

  Future<void> _loadVoice() async {
    try {
      final status = await widget.api.status();
      if (!mounted) return;
      setState(() {
        _voiceHint = status.voiceReady ? '通话' : (status.voiceHint.isEmpty ? '还没配语音密钥' : status.voiceHint);
      });
    } catch (_) {}
  }

  Future<void> _openCall() async {
    if (_busy) widget.api.cancelChat();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) => CallPage(
          api: widget.api,
          repo: widget.repo,
          sessionId: _sessionId,
          media: widget.voiceMedia,
          client: widget.voiceClient,
          onBack: () => Navigator.of(context).pop(),
          onTranscript: (captions) {
            if (captions.isEmpty) return;
            setState(() {
              _messages.addAll(captions);
            });
            _persist();
          },
        ),
      ),
    );
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
    } catch (_) {
      // Chat can still send without a sessionId; the server will open an implicit one.
    }
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
      });
      _liveText.value = '';
      _liveEngine.value = null;
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
    });
    _liveText.value = '';
    _liveEngine.value = null;
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
        _liveText.value = '';
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

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    _lastUser = text;
    HapticFeedback.selectionClick();
    _liveText.value = '';
    _liveEngine.value = null;
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _live = true;
      _busy = true;
    });
    _jump(force: true);

    final history = _messages.where((m) => m.role != 'error').toList();

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
        if (event.type == 'delta' && event.text.isNotEmpty) {
          _liveText.value += event.text;
          _jump();
        } else if (event.type == 'start' && event.engine != null) {
          _liveEngine.value = event.engine;
        } else if (event.type == 'done') {
          _liveEngine.value = event.engine ?? _liveEngine.value;
          if (event.text.isNotEmpty && _liveText.value.isEmpty) {
            _liveText.value = event.text;
          }
        } else if (event.type == 'error') {
          throw ApiException(event.error ?? '问答失败');
        }
      }
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: _liveText.value,
          engine: _liveEngine.value,
        ));
        _live = false;
      });
      await _persist();
    } on OperationCancelled {
      if (!mounted) return;
      setState(() {
        if (_liveText.value.isNotEmpty) {
          _messages.add(ChatMessage(
            role: 'assistant',
            content: _liveText.value,
            engine: _liveEngine.value,
          ));
        }
        _live = false;
      });
      await _persist();
    } catch (err) {
      if (!mounted) return;
      final shown = humanizeError(err);
      setState(() {
        if (_liveText.value.isEmpty) {
          _messages.add(ChatMessage(role: 'error', content: shown));
        } else {
          _messages.add(ChatMessage(
            role: 'assistant',
            content: _liveText.value,
            engine: _liveEngine.value,
          ));
          _messages.add(ChatMessage(role: 'error', content: shown));
        }
        _live = false;
      });
      await _persist();
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _live = false;
        });
      }
      _jump();
    }
  }

  void _stop() {
    if (!_busy) return;
    widget.api.cancelChat();
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return true;
    final pos = _scroll.position;
    return pos.pixels >= pos.maxScrollExtent - 96;
  }

  void _jump({bool force = false}) {
    if (!force && !_nearBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
      );
    });
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
                  Text('历史会话', style: Theme.of(context).textTheme.titleMedium),
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
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    _liveText.dispose();
    _liveEngine.dispose();
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
      body: Column(
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
                onPressed: _busy ? null : _newSession,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: '历史会话',
                onPressed: _openSessions,
                icon: const Icon(Icons.history),
              ),
              IconButton(
                key: const Key('wx-call'),
                tooltip: _voiceHint,
                onPressed: _openCall,
                icon: const Icon(Icons.call_outlined),
              ),
            ],
          ),
          const WxHairline(),
          Expanded(
            child: itemCount == 0
                ? _EmptyChat(
                    onPick: _busy ? null : _send,
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(Wx.inset, 20, Wx.inset, 16),
                    itemCount: itemCount,
                    itemBuilder: (context, index) {
                      if (index < _messages.length) {
                        final message = _messages[index];
                        return _FinishedTurn(
                          key: ValueKey('m-$index-${message.role}'),
                          message: message,
                          onRetry: message.role == 'error' && _lastUser != null && !_busy
                              ? () => _send(_lastUser)
                              : null,
                        );
                      }
                      return _LiveTurn(
                        text: _liveText,
                        engine: _liveEngine,
                      );
                    },
                  ),
          ),
          const WxHairline(),
          _Composer(
            controller: _input,
            focus: _focus,
            busy: _busy,
            onSend: _send,
            onStop: _stop,
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
          '回答来自本机仓库和 GitHub，不编造。',
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

class _FinishedTurn extends StatelessWidget {
  const _FinishedTurn({super.key, required this.message, this.onRetry});
  final ChatMessage message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (message.role == 'user') {
      return _VoiceTurn(
        voice: '你问',
        voiceColor: Wx.accent,
        railColor: Wx.accent,
        railWidth: 3,
        bottom: 20,
        child: SelectableText(
          message.content,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Wx.text,
                height: 1.5,
              ),
        ),
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
      footer: message.engine != null && message.engine!.isNotEmpty
          ? Text(
              message.engine == 'local-progress' ? '来自本地进度适配器' : '来自 ${message.engine}',
              style: Theme.of(context).textTheme.labelSmall,
            )
          : null,
      child: WxReadableText(message.content),
    );
  }
}

class _LiveTurn extends StatelessWidget {
  const _LiveTurn({required this.text, required this.engine});
  final ValueNotifier<String> text;
  final ValueNotifier<String?> engine;

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
          if (value == null || value.isEmpty) return const SizedBox.shrink();
          return Text(
            value == 'local-progress' ? '来自本地进度适配器' : '来自 $value',
            style: Theme.of(context).textTheme.labelSmall,
          );
        },
      ),
      child: ValueListenableBuilder<String>(
        valueListenable: text,
        builder: (context, value, _) {
          if (value.isEmpty) {
            return const Row(
              children: [
                Text(
                  '正在写…',
                  style: TextStyle(color: Wx.muted, fontSize: 16, height: 1.55),
                ),
                SizedBox(width: 8),
                _Caret(),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WxReadableText(value),
              const SizedBox(height: 6),
              const _Caret(),
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
    this.bottom = 24,
  });

  final String voice;
  final Color voiceColor;
  final Color railColor;
  final double railWidth;
  final Widget child;
  final Widget? footer;
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
                  Text(
                    voice,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: voiceColor,
                          fontSize: ask ? 12 : 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: ask ? 0.4 : 0.8,
                        ),
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
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final Future<void> Function() onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Wx.bg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Wx.inset, 10, 12, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focus,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) {
                    if (!busy) onSend();
                  },
                  decoration: InputDecoration(
                    hintText: busy ? '生成中，可先写下一条' : '问进度，像在 Cursor 里一样',
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
                        onPressed: onSend,
                        icon: const Icon(Icons.arrow_upward, size: 20),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
