import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

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
    this.clientFactory,
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
  final VoiceCallClient Function()? clientFactory;
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
  late final AnimationController _thinkMistScroll = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  final List<String> _thinkMistLines = [];

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
  String _currentUserLine = '';
  String _assistantPreview = '';
  String _segmentCaption = '';
  String _voiceCaption = '';
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
  int _linkResets = 0;
  static const _maxLinkResets = 6;
  bool _closing = false;
  bool _relinking = false;
  bool _watchPostPlaybackMic = false;
  int _postPlaybackPeak = 0;
  double _voiceLevel = 0;
  Timer? _voiceFade;
  /// Server can mark the turn done before the first downlink PCM arrives (common on a cold first reply).
  bool _answerAudioDone = false;
  bool _playbackEndPending = false;

  bool get isLive => _live;

  int get linkResets => _linkResets;

  bool get _assistantSubtitleActive =>
      _assistantPreview.isNotEmpty || _voiceCaption.isNotEmpty || _segmentCaption.isNotEmpty;

  /// Server final caption often lands before the phone finishes TTS; keep the live line until drain.
  bool get _holdAssistantCaptionForPlayback =>
      _live &&
      (_playing ||
          _phase == 'speaking' ||
          _answerAudioDone ||
          _playbackEndPending);

  void _clearAssistantSubtitle() {
    _assistantPreview = '';
    _segmentCaption = '';
    _voiceCaption = '';
  }

  void _clearThinkMist() {
    _thinkMistLines.clear();
    if (_thinkMistScroll.isAnimating) _thinkMistScroll.stop();
  }

  void _pushThinkMistLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    if (_thinkMistLines.isNotEmpty && _thinkMistLines.last == line) return;
    _thinkMistLines.add(line);
    if (_thinkMistLines.length > 20) {
      _thinkMistLines.removeRange(0, _thinkMistLines.length - 20);
    }
  }

  void _armThinkMist() {
    _clearThinkMist();
    if (!_thinkMistScroll.isAnimating) _thinkMistScroll.repeat();
  }

  void _onCaptionSegment(String text) {
    final chunk = text.trim();
    if (chunk.isEmpty) return;
    _segmentCaption = chunk;
  }

  void Function()? _playbackStartForCaption(String captionAtEnqueue) {
    if (captionAtEnqueue.isEmpty) return null;
    return () {
      if (!mounted || _disposing) return;
      setState(() {
        _voiceCaption = captionAtEnqueue;
        _assistantPreview = '';
      });
    };
  }

  void _finalizeAssistantCaption(String text, {String? engine}) {
    if (text.trim().isEmpty) return;
    _captions.add(ChatMessage(role: 'assistant', content: text.trim(), engine: engine));
    if (_holdAssistantCaptionForPlayback) {
      _assistantPreview = '';
      return;
    }
    _clearAssistantSubtitle();
  }

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
    _linkResets = 0;
    _closing = false;
    _openSocket(_newClient());
    if (_live) _armMic();
  }

  VoiceCallClient _newClient() {
    return widget.client ?? widget.clientFactory?.call() ?? SocketVoiceClient(widget.api.voiceUri());
  }

  void _sayHello(VoiceCallClient client) {
    if (widget.book != null) {
      client.hello(
        bookId: widget.book!.id,
        chapter: widget.chapter,
      );
      return;
    }
    client.hello(
      owner: widget.repo?.owner ?? '',
      repo: widget.repo?.name ?? '',
    );
  }

  void _openSocket(VoiceCallClient client) {
    _client = client;
    try {
      _sub = client.connect().listen(
        _onEvent,
        onError: (Object err) => _onSocketGone(err),
        onDone: () => _onSocketGone(null),
      );
      _sayHello(client);
    } catch (err) {
      _drop(cause: err);
    }
  }

  /// The bytes stuck in a send buffer are only dropped by tearing the socket down.
  /// Open another one and keep the call, instead of ending it on the first stall.
  void _onSocketGone(Object? cause) {
    if (!_live || _closing || _relinking || _disposing) return;
    if (widget.client != null || _linkResets >= _maxLinkResets) {
      _drop(cause: cause);
      return;
    }
    _linkResets += 1;
    // onDone is still on the stack. Cancelling that subscription here never finishes.
    Timer(Duration.zero, () {
      if (!_live || _closing || _disposing) return;
      _relink();
    });
  }

  void _relink() {
    _relinking = true;
    _cancelPlaybackEnd();
    _speakerIdleTimer?.cancel();
    _speakerIdleTimer = null;
    final previous = _sub;
    _sub = null;
    _client?.hangup();
    unawaited(previous?.cancel());
    unawaited(_media.stopPlayback().catchError((_) {}));
    _relinking = false;
    if (!_live || _closing || _disposing || !mounted) return;
    setState(() {
      _phase = 'listening';
      _playing = false;
      _clearAssistantSubtitle();
    });
    _openSocket(_newClient());
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
    if (event.type == 'activity') {
      setState(() => _pushThinkMistLine(event.text));
      return;
    }
    if (event.type == 'caption' && event.text.isNotEmpty) {
      setState(() {
        if (event.role == 'user') {
          _userLive = event.text;
          if (event.finalCaption) {
            _captions.add(ChatMessage(role: 'user', content: event.text));
            _currentUserLine = event.text.trim();
            _userLive = '';
            _clearAssistantSubtitle();
          }
        } else {
          if (event.finalCaption) {
            _finalizeAssistantCaption(event.text, engine: event.engine);
          } else if (event.segmentCaption) {
            _onCaptionSegment(event.text);
          } else if (event.previewCaption || _phase == 'thinking') {
            _assistantPreview = event.text;
          } else {
            _onCaptionSegment(event.text);
          }
        }
      });
      return;
    }
    if (event.type == 'pcm' && event.pcm != null && _shouldPlayDownlink(event.pcm!)) {
      _pcmSeq++;
      _speakerIdleTimer?.cancel();
      if (!_playing) {
        setState(() {
          _phase = 'speaking';
          _playing = true;
        });
      }
      final captionAtEnqueue = _segmentCaption;
      unawaited(
        _media.playPcm(
          event.pcm!,
          sampleRate: event.outputRate,
          segmentCaption: captionAtEnqueue,
          onPlaybackStart: _playbackStartForCaption(captionAtEnqueue),
        ),
      );
      _watchSpeakerIdle();
      if (_answerAudioDone) {
        _schedulePlaybackEnd();
      }
    }
  }

  /// State JSON can lag binary PCM after a relink; still play answer audio for this turn.
  bool _shouldPlayDownlink(Uint8List pcm) {
    if (pcm.isEmpty || !_live) return false;
    if (_phase == 'speaking' || _phase == 'thinking') return true;
    if (_phase == 'listening' &&
        (_answerAudioDone || _playbackEndPending || _assistantSubtitleActive || _playing)) {
      return true;
    }
    return false;
  }

  /// Only barge / hangup / relink should bump [_listenHold] and drop a pending drain.
  void _cancelPlaybackEnd() {
    _listenHold += 1;
    _playbackEndPending = false;
    _answerAudioDone = false;
  }

  void _schedulePlaybackEnd() {
    if (_playbackEndPending) return;
    _playbackEndPending = true;
    final hold = _listenHold;
    unawaited(_listenWhenPlaybackEnds(hold));
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
      _cancelPlaybackEnd();
      _clearThinkMist();
      setState(() {
        _phase = 'listening';
        _playing = false;
        _clearAssistantSubtitle();
      });
      unawaited(_media.stopPlayback());
      _checkMicAfterBarge();
      return;
    }
    if (next == 'audio_done') {
      _answerAudioDone = true;
      if (_phase == 'speaking') {
        _schedulePlaybackEnd();
        return;
      }
      if (_phase == 'thinking') {
        return;
      }
    }
    if ((next == 'listening' || next == 'audio_done') && _phase == 'speaking') {
      _schedulePlaybackEnd();
      return;
    }
    setState(() {
      _phase = next == 'audio_done' ? 'listening' : next;
      if (next == 'thinking') {
        _answerAudioDone = false;
        _playbackEndPending = false;
        _clearAssistantSubtitle();
        _armThinkMist();
      }
      if (next == 'listening' || next == 'barge') {
        _clearThinkMist();
      }
      if (next == 'listening' || next == 'thinking' || next == 'audio_done') {
        _playing = false;
      }
    });
  }

  /// Server marks the turn done as soon as audio is sent. Stay on 在说 until the phone finishes playing it.
  Future<void> _listenWhenPlaybackEnds(int hold) async {
    try {
      await _media.waitForPlaybackQueue();
      if (!mounted || _disposing || hold != _listenHold) return;
      await Future<void>.delayed(const Duration(milliseconds: 90));
    } catch (_) {}
    _playbackEndPending = false;
    if (!mounted || _disposing || hold != _listenHold) return;
    if (_phase != 'speaking' && !_answerAudioDone) return;
    _answerAudioDone = false;
    _client?.played();
    setState(() {
      _phase = 'listening';
      _playing = false;
      _clearAssistantSubtitle();
    });
    unawaited(_maybeReopenMicAfterPlayback(hold));
  }

  /// Full stop/start after every answer drops short follow-ups on some OEM mics.
  Future<void> _maybeReopenMicAfterPlayback(int hold) async {
    if (!_live || _disposing || hold != _listenHold) return;
    _postPlaybackPeak = 0;
    _watchPostPlaybackMic = true;
    await Future<void>.delayed(const Duration(milliseconds: 420));
    _watchPostPlaybackMic = false;
    if (!_live || _disposing || hold != _listenHold) return;
    if (_postPlaybackPeak >= _deadMicPeak) return;
    await _reopenMicAfterSpeaker();
  }

  void _userTapBarge() {
    if (!_live || _disposing) return;
    if (!_playing && _phase != 'speaking' && _phase != 'thinking') return;
    _cancelPlaybackEnd();
    setState(() {
      _phase = 'listening';
      _playing = false;
      _clearAssistantSubtitle();
    });
    unawaited(_media.stopPlayback());
    _client?.barge();
    _checkMicAfterBarge();
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
      if (_watchPostPlaybackMic && peak > _postPlaybackPeak) _postPlaybackPeak = peak;
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
    _closing = true;
    _freeBackground();
    _cancelPlaybackEnd();
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
    _watchPostPlaybackMic = false;
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
    _thinkMistScroll.dispose();
    super.dispose();
  }

  String get _callTitle {
    if (widget.book != null) {
      return widget.book!.title.isEmpty ? '问书' : widget.book!.title;
    }
    return widget.repo?.fullName ?? '通话';
  }

  bool get _thinking => statusLabel == '思考中';

  bool get _speakingStatus => _live && _playing;

  /// Whole assistant reply (including short gaps between TTS chunks): headline shows captions, not「在说」.
  bool get _assistantHeadlineCaptions => _live && (_playing || _phase == 'speaking');

  TextStyle? _assistantHeadlineCaptionStyle(BuildContext context) {
    return Theme.of(context).textTheme.headlineMedium?.copyWith(
          height: 1.45,
          fontWeight: FontWeight.w500,
        );
  }

  /// Bottom stage: status when idle, large scrollable caption while speaking.
  Widget _callStageBody(BuildContext context) {
    final line = _assistantSubtitleLine.trim();
    final speakingNow = _assistantHeadlineCaptions;
    final bodyLarge = Theme.of(context).textTheme.titleLarge?.copyWith(
          height: 1.5,
          fontWeight: FontWeight.w500,
        );

    Widget centerChild;
    if (line.isNotEmpty) {
      centerChild = Text(
        line,
        textAlign: TextAlign.start,
        style: speakingNow ? _assistantHeadlineCaptionStyle(context) : bodyLarge,
      );
    } else {
      centerChild = const SizedBox.shrink();
    }

    return Semantics(
      label: line.isEmpty && speakingNow ? '问象在说' : (line.isEmpty ? null : line),
      container: true,
      child: KeyedSubtree(
        key: const Key('call-status-slot'),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(2, 4, 2, 20),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 24),
                child: Align(
                  alignment: line.isNotEmpty ? Alignment.topLeft : Alignment.center,
                  child: centerChild,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _callTextStage(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _callStageBody(context)),
            if (!_live) _faultDetail(context),
          ],
        ),
      ),
    );
  }

  static const _orbSize = 168.0;
  static const _orbBlockHeight = 196.0;

  Widget _callOrbBlock(BuildContext context, {required bool speaking, required bool listening}) {
    return SizedBox(
      height: _orbBlockHeight,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onDoubleTap: _userTapBarge,
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                if (_voiceLevel > 0)
                  SizedBox(
                    key: const Key('call-voice-ripple'),
                    width: _orbSize,
                    height: _orbSize,
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
                            ? 0.72 + (_orb.value * 0.45)
                            : 1.0;
                    return Opacity(opacity: opacity, child: child);
                  },
                  child: Container(
                    width: _orbSize,
                    height: _orbSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: speaking ? const Color(0x38C9845A) : Wx.raised,
                      border: Border.all(
                        color: speaking ? Wx.accent : Wx.hairline,
                        width: speaking ? 2 : 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Wx.accent.withValues(alpha: speaking ? 0.12 : 0.04),
                          blurRadius: speaking ? 28 : 16,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: _thinking
                        ? Semantics(
                            label: statusLabel,
                            excludeSemantics: true,
                            child: Stack(
                              alignment: Alignment.center,
                              clipBehavior: Clip.none,
                              children: [
                                ClipOval(
                                  child: _CallThinkingMist(
                                    key: const Key('call-thinking-mist'),
                                    lines: _thinkMistLines,
                                    scroll: _thinkMistScroll,
                                  ),
                                ),
                                const WxLoading(size: 56),
                              ],
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
          if (_live && listening)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '在听',
                key: const Key('call-listening-under-orb'),
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Wx.muted,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.5,
                    ),
              ),
            )
          else if (_live && (_playing || _phase == 'speaking' || _phase == 'thinking'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '双击球打断',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint),
              ),
            ),
        ],
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
              padding: const EdgeInsets.fromLTRB(Wx.inset, 10, Wx.inset, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _userSpeechStrip(context),
                  const SizedBox(height: 12),
                  _callOrbBlock(context, speaking: speaking, listening: listening),
                  _callTextStage(context),
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

  String get _userSubtitleLine {
    if (_userLive.isNotEmpty) return _userLive;
    return _currentUserLine;
  }

  /// Live STT / last user utterance: one tail line, top-left under the header.
  String _userCornerLine() {
    if (!_live) return '';
    final raw = _userSubtitleLine.trim();
    if (raw.isEmpty) return '';
    final parts = raw.split(RegExp(r'[\r\n]+'));
    for (var i = parts.length - 1; i >= 0; i--) {
      final line = parts[i].trim();
      if (line.isNotEmpty) return line;
    }
    return raw;
  }

  Widget _userSpeechStrip(BuildContext context) {
    final line = _userCornerLine();
    final liveStt = _userLive.isNotEmpty;
    final body = Theme.of(context).textTheme.bodyMedium;
    return SizedBox(
      height: 38,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          line,
          key: const Key('call-user-typing-corner'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.left,
          style: body?.copyWith(
            height: 1.35,
            color: line.isEmpty
                ? Wx.faint.withValues(alpha: _live ? 0.45 : 0.25)
                : (liveStt ? Wx.text : Wx.muted),
            fontWeight: liveStt ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  String get _assistantSubtitleLine {
    if (_voiceCaption.isNotEmpty) return _voiceCaption;
    if (_segmentCaption.isNotEmpty) return _segmentCaption;
    return _assistantPreview;
  }

}

/// Soft, blurred tool/thought lines scroll behind the seal while the agent works.
class _CallThinkingMist extends StatelessWidget {
  const _CallThinkingMist({super.key, required this.lines, required this.scroll});

  final List<String> lines;
  final Animation<double> scroll;

  static const _placeholders = [
    '理解你的问题',
    '检索仓库与进度',
    '读文件 · 搜索 · 终端',
    '整理可口语化的回答',
  ];

  @override
  Widget build(BuildContext context) {
    final source = lines.isEmpty ? _placeholders : lines;
    final doubled = [...source, ...source];
    const rowH = 18.0;
    final blockH = source.length * rowH;
    final textStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 9.5,
          height: 1.35,
          letterSpacing: 0.2,
          color: Wx.muted.withValues(alpha: 0.72),
        );
    return SizedBox(
      width: 168,
      height: 168,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            colors: [
              Wx.accent.withValues(alpha: 0.06),
              Wx.surface.withValues(alpha: 0.0),
            ],
            radius: 0.92,
          ),
        ),
        child: AnimatedBuilder(
          animation: scroll,
          builder: (context, _) {
            final y = -scroll.value * blockH;
            return ClipRect(
              child: Transform.translate(
                offset: Offset(0, y),
                child: ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: 2.2, sigmaY: 2.2),
                  child: Opacity(
                    opacity: 0.42,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 22),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in doubled)
                            SizedBox(
                              height: rowH,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  line,
                                  maxLines: 1,
                                  overflow: TextOverflow.fade,
                                  softWrap: false,
                                  style: textStyle,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
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
