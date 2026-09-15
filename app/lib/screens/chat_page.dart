import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.api,
    required this.repo,
    required this.onBack,
  });

  final WenxiangApi api;
  final RepoItem repo;
  final VoidCallback onBack;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with SingleTickerProviderStateMixin {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, List<ChatMessage>> _transcripts = {};
  final List<ChatSession> _sessions = [];
  String? _sessionId;
  bool _busy = false;
  late final AnimationController _caret = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  )..repeat(reverse: true);

  List<ChatMessage> get _messages =>
      _transcripts.putIfAbsent(_sessionId ?? '', () => <ChatMessage>[]);

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    try {
      var list = await widget.api.listSessions(widget.repo.owner, widget.repo.name);
      if (list.isEmpty) {
        final created = await widget.api.createSession(widget.repo.owner, widget.repo.name);
        list = [created];
      }
      if (!mounted) return;
      setState(() {
        _sessions
          ..clear()
          ..addAll(list);
        _sessionId = list.firstWhere((s) => s.active, orElse: () => list.first).id;
      });
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
      });
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.toString())));
    }
  }

  Future<void> _switchSession(ChatSession session) async {
    setState(() => _sessionId = session.id);
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
        }
      });
      if (_sessions.isEmpty) await _newSession();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.toString())));
    }
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    final assistant = ChatMessage(role: 'assistant', content: '', streaming: true);
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _messages.add(assistant);
      _busy = true;
    });
    _jump();
    try {
      await for (final event in widget.api.chatStream(
        owner: widget.repo.owner,
        repo: widget.repo.name,
        message: text,
        sessionId: _sessionId,
        history: _messages
            .where((m) => m.role != 'error' && !(m.role == 'assistant' && m.streaming))
            .toList(),
      )) {
        if (!mounted) return;
        if (event.sessionId != null && event.sessionId!.isNotEmpty) {
          _sessionId = event.sessionId;
        }
        if (event.type == 'delta' && event.text.isNotEmpty) {
          setState(() => assistant.content += event.text);
          _jump();
        } else if (event.type == 'start' && event.engine != null) {
          setState(() => assistant.engine = event.engine);
        } else if (event.type == 'done') {
          setState(() {
            assistant.streaming = false;
            assistant.engine = event.engine ?? assistant.engine;
            if (event.text.isNotEmpty && assistant.content.isEmpty) {
              assistant.content = event.text;
            }
          });
        } else if (event.type == 'error') {
          throw ApiException(event.error ?? '问答失败');
        }
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        assistant.streaming = false;
        if (assistant.content.isEmpty) {
          assistant.content = err.toString();
        } else {
          _messages.add(ChatMessage(role: 'error', content: err.toString()));
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          assistant.streaming = false;
          _busy = false;
        });
      }
      _jump();
    }
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 120,
        duration: const Duration(milliseconds: 90),
        curve: Curves.linear,
      );
    });
  }

  Future<void> _openSessions() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(title: Text('历史会话')),
              if (_sessions.isEmpty)
                const ListTile(title: Text('还没有会话')),
              for (final session in _sessions)
                ListTile(
                  selected: session.id == _sessionId,
                  title: Text(session.title),
                  subtitle: Text(session.id),
                  onTap: () {
                    Navigator.pop(context);
                    _switchSession(session);
                  },
                  trailing: IconButton(
                    tooltip: '关闭会话',
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      Navigator.pop(context);
                      await _closeSession(session);
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _caret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _sessions.cast<ChatSession?>().firstWhere(
          (s) => s?.id == _sessionId,
          orElse: () => null,
        )?.title;
    return Scaffold(
      appBar: AppBar(
        title: Text(title == null || title == '新会话' ? widget.repo.fullName : title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
        actions: [
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
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              children: [
                if (_messages.isEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final q in const [
                        '这个仓库最近在做什么？',
                        '本机检出里 README 怎么写的？',
                        '有哪些开放的 PR？',
                      ])
                        ActionChip(label: Text(q), onPressed: () => _send(q)),
                    ],
                  ),
                for (final message in _messages)
                  _Bubble(message: message, caret: _caret),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: '问进度，像在 Cursor 里一样',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy ? null : _send,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.caret});
  final ChatMessage message;
  final Animation<double> caret;

  @override
  Widget build(BuildContext context) {
    final mine = message.role == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFFE4B15A) : const Color(0xFF1A2128),
          borderRadius: BorderRadius.circular(14),
          boxShadow: message.streaming
              ? const [BoxShadow(color: Color(0x33E4B15A), blurRadius: 16)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FadeTransition(
              opacity: message.streaming ? caret : const AlwaysStoppedAnimation(1),
              child: SelectableText.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: message.content.isEmpty && message.streaming ? '▍' : message.content,
                      style: TextStyle(
                        color: mine ? const Color(0xFF1A1408) : const Color(0xFFD7DEE6),
                        height: 1.45,
                        fontSize: 16,
                      ),
                    ),
                    if (message.streaming && message.content.isNotEmpty)
                      const TextSpan(
                        text: '▍',
                        style: TextStyle(color: Color(0xFFE4B15A), fontSize: 16),
                      ),
                  ],
                ),
              ),
            ),
            if (!message.streaming && message.engine != null && message.engine!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  message.engine == 'local-progress'
                      ? '引擎：本地进度适配器'
                      : '引擎：${message.engine}',
                  style: TextStyle(
                    fontSize: 11,
                    color: mine ? const Color(0xFF3D2E10) : const Color(0xFF8BA4B8),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
