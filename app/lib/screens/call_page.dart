import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/errors.dart';
import '../models.dart';
import '../theme.dart';
import '../voice/background_work.dart';
import '../voice/device_media.dart';
import '../voice/voice_client.dart';
import '../voice/voice_media.dart';
import '../widgets/wx_chrome.dart';

Future<void> openVoiceCall(
  BuildContext context, {
  required WenxiangApi api,
  RepoItem? repo,
  BookItem? book,
  String chapter = '',
  String? sessionId,
  VoiceMedia? media,
  VoiceCallClient? client,
  void Function(List<ChatMessage> captions)? onTranscript,
}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (routeContext) => CallPage(
        api: api,
        repo: repo,
        book: book,
        chapter: chapter,
        sessionId: sessionId,
        autoStart: true,
        media: media,
        client: client,
        onBack: () => Navigator.of(routeContext).pop(),
        onTranscript: onTranscript,
      ),
    ),
  );
}

class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.api,
    required this.onBack,
    this.repo,
    this.book,
    this.chapter = '',
    this.sessionId,
    this.onTranscript,
    this.media,
    this.client,
    this.autoStart = false,
  });

  final WenxiangApi api;
  final RepoItem? repo;
  final BookItem? book;
  final String chapter;
  final VoidCallback onBack;
  final String? sessionId;
  final void Function(List<ChatMessage> captions)? onTranscript;
  final VoiceMedia? media;
  final VoiceCallClient? client;
  final bool autoStart;

  @override
  State<CallPage> createState() => CallPageState();
}

class CallPageState extends State<CallPage> with TickerProviderStateMixin {
  late final VoiceMedia _media = widget.media ?? DeviceVoiceMedia(telephonyCapture: true);
  VoiceCallClient? _client;
  StreamSubscription<VoiceEvent>? _sub;
  StreamSubscription<Uint8List>? _micSub;
  late final AnimationController _orb = AnimationController(
    vsync: this,
    duration: Wx.breath,
  );
  late final AnimationController _ripple = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  String _phase = 'idle';
  String? _error;
  Object? _fault;
  bool _detailOpen = false;
  bool _live = false;
  bool _checking = true;
  bool _voiceReady = false;
  String _setupHint = '还没配语音密钥';
  final List<ChatMessage> _captions = [];
  String _userLive = '';
  String _assistantLive = '';
  bool _disposing = false;
  bool _backgroundHeld = false;
  bool _playing = false;
  Timer? _micRetry;
  Timer? _bargeMicCheck;
  Timer? _speakerIdleTimer;
  bool _watchingSpeaker = false;
  int _pcmSeq = 0;
  bool _watchBargeMic = false;
  int _bargeMicPeak = 0;
  int _listenHold = 0;
  int _micEpoch = 0;
  int _micReopens = 0;
  double _voiceLevel = 0;
  Timer? _voiceFade;

  bool get isLive => _live;

  @override
  void initState() {
    super.initState();
    _orb.repeat(reverse: true);
    _ripple.repeat();
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
    } catch (err) {
      if (!mounted || _disposing) return;
      setState(() {
        _checking = false;
        _error = '通话断了';
        _fault = err;
        _detailOpen = false;
      });
    }
  }

  /// Live call shows only three labels: 在听 while the mic takes a turn, 思考中 until
  /// playback starts or while the speaker sits idle mid-reply, 在说 only while audio plays.
  String get statusLabel {
    if (_checking && !_live) return '';
    if (_error != null && !_live) return _error!;
    if (_live) {
      if (_playing) return '在说';
      if (_phase == 'thinking' || _phase == 'speaking') return '思考中';
      return '在听';
    }
    return _voiceReady ? '' : (_error ?? '还没配语音密钥');
  }

  String get mainActionLabel {
    if (_live) return '挂断';
    if (_error != null || !_voiceReady) return '重试';
    return '开始通话';
  }

  void _holdBackground() {
    if (_backgroundHeld) return;
    _backgroundHeld = true;
    unawaited(BackgroundWork.acquire(microphone: true));
  }

  void _freeBackground() {
    if (!_backgroundHeld) return;
    _backgroundHeld = false;
    unawaited(BackgroundWork.release(microphone: true));
  }

  Future<void> startCall() async {
    if (_live) return;
    if (!_voiceReady) {
      setState(() => _error = _setupHint.isEmpty ? '还没配语音密钥' : _setupHint);
      return;
    }
    setState(() {
      _error = null;
      _fault = null;
      _detailOpen = false;
      _phase = 'connecting';
      _playing = false;
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
    _holdBackground();
    final client = widget.client ?? SocketVoiceClient(widget.api.voiceUri());
    _client = client;
    try {
      _sub = client.connect().listen(_onEvent, onError: (Object err) => _drop(cause: err), onDone: () {
        if (_live) _drop();
      });
      if (widget.book != null) {
        client.hello(
          bookId: widget.book!.id,
          chapter: widget.chapter,
          sessionId: widget.sessionId,
        );
      } else {
        client.hello(
          owner: widget.repo?.owner ?? '',
          repo: widget.repo?.name ?? '',
          sessionId: widget.sessionId,
        );
      }
      _armMic();
    } catch (err) {
      _drop(cause: err);
    }
  }

  void _onEvent(VoiceEvent event) {
    if (!mounted || _disposing) return;
    if (event.type == 'error') {
      final hint = event.hint?.isNotEmpty == true
          ? event.hint!
          : (event.code == 'unconfigured' ? '还没配语音密钥' : '通话断了');
      final raw = event.detail?.trim() ?? '';
      _fail(hint, cause: raw.isEmpty ? null : raw);
      return;
    }
    if (event.type == 'state' && event.state != null) {
      _applyState(_mapState(event.state!));
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
    if (event.type == 'pcm' && event.pcm != null && (_phase == 'speaking' || _phase == 'thinking')) {
      _pcmSeq++;
      _speakerIdleTimer?.cancel();
      if (!_playing) {
        setState(() {
          _phase = 'speaking';
          _playing = true;
        });
      }
      unawaited(_media.playPcm(event.pcm!, sampleRate: event.outputRate));
      _watchSpeakerIdle();
    }
  }

  /// After a lead-in like 我看一下 the agent can run tools for a while in silence.
  /// A 在说 over a quiet speaker looked frozen, so show the thinking seal until audio comes back.
  void _watchSpeakerIdle() {
    if (_watchingSpeaker) return;
    _watchingSpeaker = true;
    final seq = _pcmSeq;
    _media.waitForPlaybackQueue().catchError((_) {}).whenComplete(() {
      _watchingSpeaker = false;
      if (!mounted || _disposing || !_playing || _phase != 'speaking') return;
      if (seq != _pcmSeq) {
        _watchSpeakerIdle();
        return;
      }
      _speakerIdleTimer?.cancel();
      _speakerIdleTimer = Timer(_speakerIdle, () {
        _speakerIdleTimer = null;
        if (!mounted || _disposing || seq != _pcmSeq || !_playing || _phase != 'speaking') return;
        setState(() => _playing = false);
      });
    });
  }

  /// Gaps between sentences of one reply stay under this, so they keep 在说.
  static const _speakerIdle = Duration(milliseconds: 700);

  void _applyState(String next) {
    if (next == 'barge') {
      _listenHold++;
      setState(() {
        _phase = 'listening';
        _playing = false;
        _assistantLive = '';
      });
      unawaited(_media.stopPlayback());
      _checkMicAfterBarge();
      return;
    }
    if ((next == 'listening' || next == 'audio_done') && _phase == 'speaking') {
      final hold = ++_listenHold;
      unawaited(_listenWhenPlaybackEnds(hold));
      return;
    }
    _listenHold++;
    setState(() {
      _phase = next == 'audio_done' ? 'listening' : next;
      if (next == 'listening' || next == 'thinking' || next == 'audio_done') {
        _playing = false;
        _assistantLive = '';
      }
    });
  }

  /// Server marks the turn done as soon as audio is sent. Stay on 在说 until the phone finishes playing it.
  Future<void> _listenWhenPlaybackEnds(int hold) async {
    try {
      await _media.waitForPlaybackQueue();
    } catch (_) {}
    if (!mounted || _disposing || hold != _listenHold || _phase != 'speaking') return;
    _client?.played();
    setState(() {
      _phase = 'listening';
      _playing = false;
      _assistantLive = '';
    });
    unawaited(_reopenMicAfterSpeaker());
  }

  /// A barge means the mic just heard the user over the speaker, mid-sentence.
  /// Restarting it here dropped the rest of that sentence, so keep it open.
  /// On vivo the mic can still go mute once the speaker stops. The voice that broke
  /// through at the barge itself proves nothing, so only frames after [_bargeMicGrace] count.
  void _checkMicAfterBarge() {
    _bargeMicCheck?.cancel();
    _bargeMicPeak = 0;
    _watchBargeMic = false;
    final epoch = _micEpoch;
    _bargeMicCheck = Timer(_bargeMicGrace, () {
      _watchBargeMic = true;
      _bargeMicCheck = Timer(_bargeMicWindow - _bargeMicGrace, () {
        _bargeMicCheck = null;
        _watchBargeMic = false;
        if (!_live || _disposing || epoch != _micEpoch) return;
        if (_bargeMicPeak < _deadMicPeak) unawaited(_reopenMicAfterSpeaker());
      });
    });
  }

  static const _bargeMicGrace = Duration(milliseconds: 300);
  static const _bargeMicWindow = Duration(milliseconds: 900);

  /// Room noise on a live phone mic peaks well above this; a suppressed one sends near-zero.
  static const _deadMicPeak = 200;

  /// A spoken word on this phone sits above this. Silence, and a mic the echo
  /// cancel has wiped to zero, stay under it, so the rings mean the voice was captured.
  static const _voiceSeenPeak = 800;

  void _noteHeard(int peak) {
    if (!_live || peak < _voiceSeenPeak) return;
    _voiceLevel = (0.45 + (peak - _voiceSeenPeak) / 8000).clamp(0.45, 1.0);
    final first = _voiceFade == null;
    _voiceFade?.cancel();
    _voiceFade = Timer(const Duration(milliseconds: 280), () {
      _voiceFade = null;
      _voiceLevel = 0;
      if (mounted && !_disposing) setState(() {});
    });
    if (first && mounted && !_disposing) setState(() {});
  }

  /// The call mic stays suppressed after the speaker. Open it again so the next sentence is recorded.
  Future<void> _reopenMicAfterSpeaker() async {
    if (!_live || _disposing) return;
    final epoch = ++_micEpoch;
    await _micSub?.cancel();
    _micSub = null;
    await _media.stopMic();
    if (!_live || _disposing || epoch != _micEpoch) return;
    _armMic();
  }

  /// A recorder glitch used to hang the call up. Reopen unless it never really started.
  void _armMic() {
    final epoch = ++_micEpoch;
    final started = DateTime.now();
    var frames = 0;
    _micSub?.cancel();
    _micSub = _media.startMic().listen((pcm) {
      frames += 1;
      _micReopens = 0;
      final peak = pcm16Peak(pcm);
      if (_watchBargeMic && peak > _bargeMicPeak) _bargeMicPeak = peak;
      _noteHeard(peak);
      _client?.sendPcm(pcm);
    }, onError: (_) {
      _reviveMic(epoch, started, frames);
    }, onDone: () {
      _reviveMic(epoch, started, frames);
    });
  }

  void _reviveMic(int epoch, DateTime started, int frames) {
    if (epoch != _micEpoch || !_live || _disposing) return;
    final brief = frames == 0 && DateTime.now().difference(started) < const Duration(milliseconds: 300);
    if (brief) return;
    if (_micReopens >= 2) {
      _fail('需要麦克风才能通话');
      return;
    }
    _micReopens += 1;
    _micRetry?.cancel();
    _micRetry = Timer(const Duration(milliseconds: 350), () {
      if (!_live || _disposing || epoch != _micEpoch) return;
      _armMic();
    });
  }

  void _fail(String hint, {Object? cause}) {
    hangup(pop: false);
    if (!mounted || _disposing) return;
    setState(() {
      _error = hint;
      _fault = cause;
      _detailOpen = false;
    });
  }

  String _mapState(String raw) {
    switch (raw) {
      case 'connecting':
        return 'connecting';
      case 'listening':
        return 'listening';
      case 'thinking':
        return 'thinking';
      case 'speaking':
        return 'speaking';
      case 'barge':
        return 'barge';
      case 'audio_done':
        return 'audio_done';
      default:
        return _phase;
    }
  }

  void _drop({String hint = '通话断了', Object? cause}) {
    hangup(pop: false);
    if (!mounted) return;
    setState(() {
      _error = hint;
      _fault = cause;
      _detailOpen = false;
    });
  }

  void hangup({bool pop = false}) {
    _freeBackground();
    _listenHold++;
    _micEpoch++;
    _micRetry?.cancel();
    _micRetry = null;
    _bargeMicCheck?.cancel();
    _bargeMicCheck = null;
    _speakerIdleTimer?.cancel();
    _speakerIdleTimer = null;
    _voiceFade?.cancel();
    _voiceFade = null;
    _voiceLevel = 0;
    _watchBargeMic = false;
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
    _playing = false;
    if (!_disposing && mounted) {
      setState(() {});
    }
    if (pop && mounted) widget.onBack();
  }

  Future<void> retry() async {
    setState(() {
      _error = null;
      _fault = null;
      _detailOpen = false;
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
    _ripple.dispose();
    super.dispose();
  }

  String get _callTitle {
    if (widget.book != null) {
      return widget.book!.title.isEmpty ? '问书' : widget.book!.title;
    }
    return widget.repo?.fullName ?? '通话';
  }

  bool get _thinking => statusLabel == '思考中';

  /// 思考中 is the breathing seal inside the orb, so the label goes blank. The slot keeps
  /// one height during a call so 在听/在说 do not jump.
  Widget _status(BuildContext context) {
    final style = Theme.of(context).textTheme.headlineMedium;
    final lineHeight = (style?.fontSize ?? 28) * (style?.height ?? 1.2);
    return SizedBox(
      height: _live ? lineHeight : null,
      child: Center(
        child: _thinking ? null : Text(statusLabel, textAlign: TextAlign.center, style: style),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final speaking = _playing;
    final listening = _live && !_playing && _phase != 'thinking' && _phase != 'speaking';
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            onBack: () => hangup(pop: true),
            backTooltip: '挂断并返回',
            title: _callTitle,
          ),
          const WxHairline(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 8),
              child: Column(
                children: [
                  const Spacer(),
                  Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: [
                      if (_voiceLevel > 0)
                        SizedBox(
                          key: const Key('call-voice-ripple'),
                          width: 168,
                          height: 168,
                          child: AnimatedBuilder(
                            animation: _ripple,
                            builder: (context, _) => CustomPaint(
                              painter: _VoiceRipplePainter(
                                t: _ripple.value,
                                level: _voiceLevel,
                                color: Wx.accent,
                              ),
                            ),
                          ),
                        ),
                      AnimatedBuilder(
                        animation: _orb,
                        builder: (context, child) {
                          final opacity = speaking
                              ? 0.55 + (_orb.value * 0.45)
                              : listening
                                  ? 0.72 + (_orb.value * 0.28)
                                  : 1.0;
                          return Opacity(opacity: opacity, child: child);
                        },
                        child: Container(
                          width: 168,
                          height: 168,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: speaking ? const Color(0x38C9845A) : Wx.raised,
                            border: Border.all(
                              color: speaking ? Wx.accent : Wx.hairline,
                              width: speaking ? 2 : 1,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: _thinking
                              ? Semantics(
                                  label: statusLabel,
                                  excludeSemantics: true,
                                  child: const WxLoading(size: 56),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  _status(context),
                  if (!_live) _faultDetail(context),
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
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _live
                      ? () => hangup(pop: true)
                      : (_checking ? null : (_error != null || !_voiceReady ? retry : startCall)),
                  child: Text(mainActionLabel),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _faultDetail(BuildContext context) {
    final fault = _fault;
    if (fault == null) return const SizedBox.shrink();
    final detail = errorDetail(fault);
    if (detail == null) return const SizedBox.shrink();
    return Column(
      children: [
        if (_detailOpen) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 120),
            child: SingleChildScrollView(
              child: SelectableText(
                detail,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Wx.muted,
                      height: 1.45,
                    ),
              ),
            ),
          ),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(
              onPressed: () => setState(() => _detailOpen = !_detailOpen),
              child: Text(_detailOpen ? '收起详情' : '详情'),
            ),
            if (_detailOpen)
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: detail));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已复制')),
                  );
                },
                child: const Text('复制'),
              ),
          ],
        ),
      ],
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

/// Three rings leave the orb edge and fade. Louder speech reaches farther.
class _VoiceRipplePainter extends CustomPainter {
  _VoiceRipplePainter({required this.t, required this.level, required this.color});

  final double t;
  final double level;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    const edge = 84.0;
    final reach = 26 + 24 * level;
    for (var i = 0; i < 3; i++) {
      final p = (t + i / 3) % 1.0;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withValues(alpha: (1 - p) * 0.55 * level);
      canvas.drawCircle(center, edge + reach * p, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceRipplePainter old) =>
      old.t != t || old.level != level || old.color != color;
}
