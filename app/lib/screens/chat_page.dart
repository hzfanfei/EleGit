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

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  bool _busy = false;

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _busy = true;
    });
    _jump();
    try {
      final result = await widget.api.chat(
        owner: widget.repo.owner,
        repo: widget.repo.name,
        message: text,
        history: _messages.where((m) => m.role != 'error').toList(),
      );
      setState(() {
        _messages.add(ChatMessage(
          role: 'assistant',
          content: result.answer,
          engine: result.engine,
        ));
      });
    } catch (err) {
      setState(() {
        _messages.add(ChatMessage(role: 'error', content: err.toString()));
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      _jump();
    }
  }

  void _jump() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 80,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.repo.fullName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
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
                for (final message in _messages) _Bubble(message: message),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('本机正在根据 GitHub 上下文作答…'),
                  ),
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
  const _Bubble({required this.message});
  final ChatMessage message;

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
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              message.content,
              style: TextStyle(
                color: mine ? const Color(0xFF1A1408) : const Color(0xFFD7DEE6),
                height: 1.4,
              ),
            ),
            if (message.engine != null && message.engine!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  message.engine == 'local-progress'
                      ? '引擎：本地 GitHub 进度适配器'
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
