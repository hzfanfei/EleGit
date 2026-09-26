import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/errors.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/agent_decision_card.dart';
import '../widgets/wx_chat_markdown_stream.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_typewriter_stream.dart';

class BookChatPage extends StatefulWidget {
  const BookChatPage({
    super.key,
    required this.api,
    required this.book,
    required this.onBack,
  });

  final WenxiangApi api;
  final BookItem book;
  final VoidCallback onBack;

  @override
  State<BookChatPage> createState() => _BookChatPageState();
}

class _BookChatPageState extends State<BookChatPage> {
  static const _suggestions = [
    '这本书主要讲什么？',
    '第一章有哪些要点？',
    '用三句话概括全书。',
  ];

  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<ChatMessage> _messages = [];
  late final WxTypewriterStream _typewriter;
  final _liveActivity = ValueNotifier<String>('');
  String? _sessionId;
  bool _live = false;
  bool _busy = false;
  ChatStreamEvent? _decision;

  @override
  void initState() {
    super.initState();
    _typewriter = WxTypewriterStream(onReveal: () {
      if (mounted) setState(() {});
      _jumpToLatest();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureSession();
      widget.api.warmBookSession(widget.book.id).catchError((_) {});
    });
  }

  Future<void> _ensureSession() async {
    try {
      var list = await widget.api.listBookSessions(widget.book.id);
      if (list.isEmpty) {
        final created = await widget.api.createBookSession(widget.book.id);
        list = [created];
      }
      if (!mounted) return;
      setState(() => _sessionId = list.first.id);
    } catch (_) {}
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
    final message = (text ?? _input.text).trim();
    if (message.isEmpty || _busy) return;
    HapticFeedback.lightImpact();
    _input.clear();
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: message));
      _busy = true;
      _live = true;
      _decision = null;
    });
    _liveActivity.value = '';
    _jumpToLatest();
    _typewriter.reset();
    try {
      await for (final event in widget.api.bookChatStream(
        bookId: widget.book.id,
        message: message,
        history: _messages.where((m) => m.role != 'error').toList(),
        sessionId: _sessionId,
      )) {
        if (!mounted) return;
        if (event.sessionId != null && event.sessionId!.isNotEmpty) {
          _sessionId = event.sessionId;
        }
        switch (event.type) {
          case 'status':
            final phase = event.phase?.trim() ?? '';
            final detail = event.detail?.trim() ?? '';
            if (phase == 'activity' || detail.isNotEmpty) {
              _liveActivity.value = detail;
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
      if (mounted) {
        setState(() {
          _busy = false;
          _live = false;
        });
      }
      _jumpToLatest();
    }
  }

  void _jumpToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _typewriter.dispose();
    _liveActivity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            showMark: false,
            title: widget.book.title,
            subtitle: widget.book.author.isEmpty ? '问书' : widget.book.author,
            onBack: widget.onBack,
          ),
          const WxHairline(),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 12),
              itemCount: _messages.length + (_live ? 1 : 0) + (_messages.isEmpty ? 1 : 0),
              itemBuilder: (context, index) {
                if (_messages.isEmpty && index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '从书的内容问起，回答依据本机书稿。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Wx.faint),
                    ),
                  );
                }
                final base = _messages.isEmpty ? 1 : 0;
                if (_live && index == base + _messages.length) {
                  return _Bubble(
                    role: 'assistant',
                    child: ValueListenableBuilder<String>(
                      valueListenable: _typewriter.visible,
                      builder: (context, text, _) {
                        if (text.isEmpty) {
                          return ValueListenableBuilder<String>(
                            valueListenable: _liveActivity,
                            builder: (context, activity, _) {
                              return Text(
                                activity.isEmpty ? '正在问书…' : activity,
                                style: const TextStyle(color: Wx.muted, height: 1.45),
                              );
                            },
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            WxChatMarkdownStream(
                              source: _typewriter.visible,
                              styleSheet: chatMarkdownStyle(Theme.of(context)),
                              showCaret: true,
                            ),
                            ValueListenableBuilder<String>(
                              valueListenable: _liveActivity,
                              builder: (context, activity, _) {
                                if (activity.isEmpty) return const SizedBox.shrink();
                                return Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    activity,
                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                          color: Wx.muted,
                                          height: 1.4,
                                        ),
                                  ),
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  );
                }
                final msg = _messages[index - base];
                return _Bubble(
                  role: msg.role,
                  child: WxChatMarkdownStream(
                    source: ValueNotifier<String>(msg.content),
                    styleSheet: chatMarkdownStyle(Theme.of(context)),
                    showCaret: false,
                  ),
                );
              },
            ),
          ),
          if (_messages.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _suggestions
                    .map(
                      (s) => ActionChip(
                        label: Text(s),
                        onPressed: _busy ? null : () => _send(s),
                      ),
                    )
                    .toList(),
              ),
            ),
          if (_decision != null)
            AgentDecisionCard(
              event: _decision!,
              onSubmit: _submitDecision,
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _busy ? null : (_) => _send(),
                      decoration: const InputDecoration(hintText: '问这本书…'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _busy ? () => widget.api.cancelChat(sessionId: _sessionId) : () => _send(),
                    icon: Icon(_busy ? Icons.stop : Icons.arrow_upward),
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
  const _Bubble({required this.role, required this.child});

  final String role;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isUser = role == 'user';
    final isError = role == 'error';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: isError
              ? Wx.danger.withValues(alpha: 0.12)
              : (isUser ? Wx.accent.withValues(alpha: 0.14) : Wx.hairline.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(Wx.radius),
        ),
        child: child,
      ),
    );
  }
}
