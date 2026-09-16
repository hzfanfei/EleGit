import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../voice/device_media.dart';
import '../voice/voice_client.dart';
import '../voice/voice_media.dart';
import '../widgets/wx_chrome.dart';

class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.api,
    required this.repo,
    required this.onBack,
    this.sessionId,
    this.onTranscript,
    this.media,
    this.client,
    this.autoStart = false,
  });

  final WenxiangApi api;
  final RepoItem repo;
  final VoidCallback onBack;
  final String? sessionId;
  final void Function(List<ChatMessage> captions)? onTranscript;
  final VoiceMedia? media;
  final VoiceCallClient? client;
  final bool autoStart;

  @override
  State<CallPage> createState() => CallPageState();
}

class CallPageState extends State<CallPage> with SingleTickerProviderStateMixin {
  late final VoiceMedia _media = widget.media ?? DeviceVoiceMedia();
  VoiceCallClient? _client;
  StreamSubscription<VoiceEvent>? _sub;
  StreamSubscription<Uint8List>? _micSub;
  late final AnimationController _orb = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  String _phase = 'idle';
  String? _error;
  bool _live = false;
  bool _checking = true;
  bool _voiceReady = false;
  String _setupHint = '还没配语音密钥';
  final List<ChatMessage> _captions = [];
  String _userLive = '';
  String _assistantLive = '';
  bool _disposing = false;

  bool get isLive => _live;

  @override
  void initState() {
    super.initState();
    _orb.repeat(reverse: true);
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final status = await widget.api.status();
      if (!mounted || _disposing) return;
      setState(() {
        _checking = false;
        _voiceReady = status.voiceReady;
        _setupHint = status.voiceReady ? '' : (status.voiceHint.isEmpty ? '还没配语音密钥' : status.voiceHint);
        if (!status.voiceReady) _error = _setupHint;
      });
      if (widget.autoStart && status.voiceReady) {
        await startCall();
      }
    } catch (_) {
      if (!mounted || _disposing) return;
      setState(() {
        _checking = false;
        _error = '通话断了';
      });
    }
  }

  String get statusLabel {
    if (_error != null && !_live) return _error!;
    switch (_phase) {
      case 'connecting':
        return '连接中';
      case 'listening':
        return '在听';
      case 'speaking':
        return '在说';
      case 'barge':
        return '你打断了';
      default:
        return _voiceReady ? '' : (_error ?? '还没配语音密钥');
    }
  }

  Future<void> startCall() async {
    if (_live) return;
    if (!_voiceReady) {
      setState(() => _error = _setupHint.isEmpty ? '还没配语音密钥' : _setupHint);
      return;
    }
    setState(() {
      _error = null;
      _phase = 'connecting';
      _live = true;
    });
    final allowed = await _media.requestMic();
    if (!mounted) return;
    if (!allowed) {
      setState(() {
        _live = false;
        _phase = 'idle';
        _error = '需要麦克风才能通话';
      });
      return;
    }
    final client = widget.client ?? SocketVoiceClient(widget.api.voiceUri());
    _client = client;
    try {
      _sub = client.connect().listen(_onEvent, onError: (_) => _drop(), onDone: () {
        if (_live) _drop();
      });
      client.hello(owner: widget.repo.owner, repo: widget.repo.name, sessionId: widget.sessionId);
      _micSub = _media.startMic().listen(client.sendPcm, onError: (_) {
        setState(() {
          _error = '需要麦克风才能通话';
        });
      });
    } catch (_) {
      _drop(hint: '通话断了');
    }
  }

  void _onEvent(VoiceEvent event) {
    if (!mounted || _disposing) return;
    if (event.type == 'error') {
      final hint = event.hint?.isNotEmpty == true
          ? event.hint!
          : (event.code == 'unconfigured' ? '还没配语音密钥' : '通话断了');
      setState(() {
        _error = hint;
        if (event.code == 'unconfigured' || event.code == 'mic') {
          _live = false;
          _phase = 'idle';
        }
      });
      if (event.code == 'unconfigured') hangup(pop: false);
      return;
    }
    if (event.type == 'state' && event.state != null) {
      setState(() {
        _phase = _mapState(event.state!);
        if (_phase == 'listening') _assistantLive = '';
      });
      if (_phase == 'barge') {
        unawaited(_media.stopPlayback());
      }
      return;
    }
    if (event.type == 'caption' && event.text.isNotEmpty) {
      setState(() {
        if (event.role == 'user') {
          _userLive = event.text;
          if (event.finalCaption) {
            _captions.add(ChatMessage(role: 'user', content: event.text));
            _userLive = '';
          }
        } else {
          _assistantLive = event.text;
          if (event.finalCaption) {
            _captions.add(ChatMessage(role: 'assistant', content: event.text, engine: event.engine));
            _assistantLive = '';
          }
        }
      });
      return;
    }
    if (event.type == 'pcm' && event.pcm != null) {
      unawaited(_media.playPcm(event.pcm!, sampleRate: event.outputRate));
    }
  }

  String _mapState(String raw) {
    switch (raw) {
      case 'connecting':
        return 'connecting';
      case 'listening':
        return 'listening';
      case 'speaking':
        return 'speaking';
      case 'barge':
        return 'barge';
      default:
        return _phase;
    }
  }

  void _drop({String hint = '通话断了'}) {
    hangup(pop: false);
    if (!mounted) return;
    setState(() => _error = hint);
  }

  void hangup({bool pop = false}) {
    _sub?.cancel();
    _sub = null;
    _micSub?.cancel();
    _micSub = null;
    _client?.hangup();
    unawaited(_media.stopMic());
    unawaited(_media.stopPlayback());
    if (_captions.isNotEmpty) {
      widget.onTranscript?.call(List<ChatMessage>.from(_captions));
      _captions.clear();
    }
    _live = false;
    _phase = 'idle';
    if (!_disposing && mounted) {
      setState(() {});
    }
    if (pop && mounted) widget.onBack();
  }

  void barge() {
    if (_phase != 'speaking') return;
    HapticFeedback.selectionClick();
    _client?.barge();
    unawaited(_media.stopPlayback());
    setState(() => _phase = 'barge');
  }

  Future<void> retry() async {
    setState(() {
      _error = null;
      _checking = true;
    });
    await _loadStatus();
    if (_voiceReady) await startCall();
  }

  @override
  void dispose() {
    _disposing = true;
    hangup(pop: false);
    if (widget.media == null) _media.dispose();
    _orb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final speaking = _phase == 'speaking';
    final listening = _phase == 'listening';
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            onBack: () => hangup(pop: true),
            backTooltip: '挂断并返回',
            title: widget.repo.fullName,
          ),
          const WxHairline(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 8),
              child: Column(
                children: [
                  const Spacer(),
                  GestureDetector(
                    onTap: speaking ? barge : null,
                    child: AnimatedBuilder(
                      animation: _orb,
                      builder: (context, _) {
                        final pulse = speaking
                            ? 0.78 + (_orb.value * 0.22)
                            : listening
                                ? 0.88 + (_orb.value * 0.08)
                                : 0.92;
                        final size = 168.0 * pulse;
                        return Container(
                          width: size,
                          height: size,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: speaking ? const Color(0x38C9845A) : Wx.raised,
                            border: Border.all(
                              color: speaking ? Wx.accent : Wx.hairline,
                              width: speaking ? 2 : 1,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    _checking ? '连接中' : statusLabel,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const Spacer(),
                  SizedBox(
                    height: 92,
                    child: ListView(
                      reverse: true,
                      children: [
                        if (_assistantLive.isNotEmpty) _caption('问象', _assistantLive),
                        if (_userLive.isNotEmpty) _caption('你', _userLive),
                        for (final item in _captions.reversed.take(2))
                          _caption(item.role == 'user' ? '你' : '问象', item.content),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const WxHairline(),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 16),
              child: Column(
                children: [
                  if (_error != null && !_live)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: WxErrorPanel(error: _error!, onRetry: retry),
                    ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _live ? () => hangup(pop: true) : (_checking ? null : startCall),
                      child: Text(_live ? '挂断' : '开始通话'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _caption(String who, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        '$who  $text',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}
