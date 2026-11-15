import 'dart:async';

import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chat_markdown_stream.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_speak_answer.dart';
import '../widgets/wx_hold_to_speak.dart';
import '../voice/hold_to_speak_session.dart';

class TemporaryChatPage extends StatefulWidget {
  const TemporaryChatPage({super.key, required this.api, required this.onBack});

  final WenxiangApi api;
  final VoidCallback onBack;

  @override
  State<TemporaryChatPage> createState() => _TemporaryChatPageState();
}

class _TemporaryChatPageState extends State<TemporaryChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _liveText = ValueNotifier<String>('');
  final List<ChatMessage> _messages = [];
  String? _id;
  String? _error;
  bool _busy = false;
  bool _stopping = false;
  Timer? _heartbeat;
  late final HoldToSpeakSession _hold;
  bool _voiceMode = false;
  String? _model;

  @override
  void initState() {
    super.initState();
    _hold = HoldToSpeakSession(
      api: widget.api,
      onChanged: () { if (mounted) setState(() {}); },
      onTranscript: (text) { if (mounted) { _input.text = text; unawaited(_send()); } },
      onError: (message) { if (mounted) setState(() => _error = message); },
    );
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final id = await widget.api.createTemporaryChat();
      if (!mounted) {
        await widget.api.closeTemporaryChat(id);
        return;
      }
      setState(() => _id = id);
      _heartbeat = Timer.periodic(const Duration(minutes: 1), (_) {
        widget.api.pingTemporaryChat(id).catchError((_) {});
      });
    } catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  Future<void> _selectModel() async {
    try {
      final data = await widget.api.codexModels();
      if (!mounted) return;
      final models = (data['models'] as List? ?? []).whereType<Map>().toList();
      final selected = await showModalBottomSheet<String>(context: context, builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('选择临时会话模型')),
          ListTile(title: const Text('跟随默认模型'), trailing: _model == null ? const Icon(Icons.check) : null, onTap: () => Navigator.pop(context, '')),
          for (final model in models)
            ListTile(title: Text('${model['label'] ?? model['id']}'), trailing: model['id'] == _model ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, model['id'].toString())),
        ]),
      ));
      if (selected != null && mounted) setState(() => _model = selected.isEmpty ? null : selected);
    } catch (err) { if (mounted) setState(() => _error = '获取模型失败：$err'); }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final id = _id;
    if (text.isEmpty || id == null || _busy) return;
    _input.clear();
    _liveText.value = '';
    setState(() {
      _error = null;
      _busy = true;
      _stopping = false;
      _messages.add(ChatMessage(role: 'user', content: text));
    });
    _scrollDown();
    var sawError = false;
    try {
      await for (final event in widget.api.temporaryChatStream(id, text, model: _model)) {
        if (!mounted) return;
        if (event.type == 'delta') {
          _liveText.value += event.text;
          _scrollDown();
        } else if (event.type == 'error') {
          sawError = true;
          if (!_stopping) setState(() => _error = event.error ?? '回答失败');
        }
      }
    } catch (err) {
      if (mounted && !sawError && !_stopping) setState(() => _error = err.toString());
    } finally {
      if (mounted) {
        final answer = _liveText.value;
        setState(() {
          if (answer.isNotEmpty) _messages.add(ChatMessage(role: 'assistant', content: answer));
          _busy = false;
          _stopping = false;
        });
        _liveText.value = '';
        _scrollDown();
      }
    }
  }

  Future<void> _stop() async {
    final id = _id;
    if (id == null || _stopping) return;
    setState(() => _stopping = true);
    try {
      await widget.api.stopTemporaryChat(id);
    } catch (err) {
      if (mounted) setState(() { _stopping = false; _error = err.toString(); });
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    _hold.dispose();
    _heartbeat?.cancel();
    final id = _id;
    if (id != null) unawaited(widget.api.closeTemporaryChat(id));
    _input.dispose();
    _scroll.dispose();
    _liveText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        WxPageHeader(showMark: false, title: '临时会话', subtitle: '不关联项目，退出后丢弃', onBack: widget.onBack),
        const WxHairline(),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: _busy ? null : _selectModel,
          icon: const Icon(Icons.tune), label: Text(_model ?? '选择模型'),
        )),
        Expanded(
          child: ListView(
            controller: _scroll,
            padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 12),
            children: [
              if (_messages.isEmpty)
                const Text('从空白开始，退出后对话将清除。', style: TextStyle(color: Wx.muted)),
              for (final message in _messages)
                _MessageBubble(message: message, api: widget.api),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: ValueListenableBuilder<String>(
                    valueListenable: _liveText,
                    builder: (context, value, _) => value.isEmpty
                        ? const Text('正在回答…', style: TextStyle(color: Wx.muted))
                        : WxChatMarkdownStream(source: _liveText, mdStyle: chatMarkdownStyle(Theme.of(context)), api: widget.api, showCaret: true),
                  ),
                ),
              if (_error != null) WxErrorPanel(error: _error!),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 12),
            child: Row(children: [
              IconButton(
                tooltip: _voiceMode ? '键盘输入' : '按住说话',
                onPressed: _busy || _hold.active ? null : () => setState(() => _voiceMode = !_voiceMode),
                icon: Icon(_voiceMode ? Icons.keyboard_alt_outlined : Icons.mic_outlined),
              ),
              Expanded(child: _voiceMode ? WxHoldToSpeakPad(
                enabled: _id != null && (!_busy || _hold.sttBusy),
                holding: _hold.holding, holdCancel: _hold.holdCancel, sttBusy: _hold.sttBusy,
                hint: _hold.holdLive.isNotEmpty ? _hold.holdLive : _hold.holdHint.isNotEmpty ? _hold.holdHint : '按住 说话',
                onHoldStart: _hold.beginHold, onHoldMove: _hold.moveHold, onHoldEnd: _hold.endHold,
                onCancelRecognize: _hold.sttBusy ? () => unawaited(_hold.cancelRecognition()) : null,
              ) : TextField(
                controller: _input, minLines: 1, maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: _busy ? null : (_) => _send(),
                decoration: const InputDecoration(hintText: '输入问题…'),
              )),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: _busy ? '停止' : '发送',
                onPressed: _busy ? (_stopping ? null : _stop) : (_id == null ? null : _send),
                icon: Icon(_busy ? Icons.stop : Icons.arrow_upward),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.api});
  final ChatMessage message;
  final WenxiangApi api;

  @override
  Widget build(BuildContext context) {
    final user = message.role == 'user';
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: user ? Wx.accent.withValues(alpha: 0.14) : Wx.hairline.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(Wx.radius),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          WxChatMarkdownStream(source: ValueNotifier<String>(message.content), mdStyle: chatMarkdownStyle(Theme.of(context)), api: api, showCaret: false),
          if (!user) WxAnswerActions(text: message.content, api: api),
        ]),
      ),
    );
  }
}
