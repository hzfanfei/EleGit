import 'dart:async';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';
import '../voice/book_quick_voice_session.dart';
import 'voice_caption_panel.dart';
import 'wx_chrome.dart';
import 'wx_hold_to_speak.dart';

/// Outer padding under the mic, the mic itself, and a gap so the last line
/// of text ends above the button.
const kQuickVoiceFabBottomPad = 12.0;
const kQuickVoiceMicSize = 48.0;
const kQuickVoiceFabClearance = kQuickVoiceFabBottomPad + kQuickVoiceMicSize + 8;

/// Floating mic for book quick voice Q&A — hold to talk, no transcript UI.
class BookQuickVoiceFab extends StatefulWidget {
  const BookQuickVoiceFab({
    super.key,
    required this.session,
    required this.palette,
    required this.enabled,
    this.bottomInset = 0,
  });

  final QuickVoiceFabHost session;
  final ReaderPalette palette;
  final bool enabled;
  final double bottomInset;

  @override
  State<BookQuickVoiceFab> createState() => _BookQuickVoiceFabState();
}

class _BookQuickVoiceFabState extends State<BookQuickVoiceFab>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: Wx.breath,
  )..repeat(reverse: true);

  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );

  int? _pointerDownMs;
  double? _pointerDownY;
  bool _tapCancelArm = false;
  bool _fingerDown = false;
  Timer? _promoteHold;

  static const _tapMaxMs = 320;
  static const _tapMaxMove = 28.0;

  @override
  void dispose() {
    _promoteHold?.cancel();
    _pulse.dispose();
    _wave.dispose();
    super.dispose();
  }

  Future<void> _startHold(double globalY) async {
    HapticFeedback.lightImpact();
    await widget.session.pointerDown(globalY);
    if (!mounted || !_fingerDown) {
      await widget.session.pointerUp();
    }
  }

  Future<void> _onMicPointerUp(double globalY) async {
    final downMs = _pointerDownMs;
    final downY = _pointerDownY;
    final tapArm = _tapCancelArm;
    _promoteHold?.cancel();
    _promoteHold = null;
    _fingerDown = false;
    _pointerDownMs = null;
    _pointerDownY = null;
    _tapCancelArm = false;

    if (tapArm && downMs != null && downY != null) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - downMs;
      if (elapsed <= _tapMaxMs && (downY - globalY).abs() <= _tapMaxMove) {
        HapticFeedback.lightImpact();
        await widget.session.cancelActiveFlow();
        return;
      }
    }
    await widget.session.pointerUp();
  }

  void _syncWave(BookQuickVoicePhase phase, bool holding) {
    final listenWave =
        holding && phase == BookQuickVoicePhase.listening && !widget.session.hold.holdCancel;
    if (listenWave) {
      if (!_wave.isAnimating) _wave.repeat();
    } else if (_wave.isAnimating) {
      _wave.stop();
    }
  }

  Color _accentFor(BookQuickVoicePhase phase) {
    final hold = widget.session.hold;
    if (hold.holdCancel && hold.holding) return const Color(0xFFE85D4C);
    switch (phase) {
      case BookQuickVoicePhase.speaking:
        return widget.palette.ink.withValues(alpha: 0.88);
      case BookQuickVoicePhase.thinking:
        return widget.palette.ink.withValues(alpha: 0.82);
      case BookQuickVoicePhase.recognizing:
        return widget.palette.ink.withValues(alpha: 0.78);
      case BookQuickVoicePhase.listening:
        return widget.palette.ink;
      case BookQuickVoicePhase.idle:
        return widget.palette.ink.withValues(alpha: 0.72);
    }
  }

  Widget? _statusLeading(BookQuickVoicePhase phase) {
    final hold = widget.session.hold;
    if (hold.holding && phase == BookQuickVoicePhase.listening && !hold.holdCancel) {
      return WxVoiceWaveBars(color: widget.palette.ink, animation: _wave);
    }
    if (phase == BookQuickVoicePhase.recognizing ||
        hold.sttBusy ||
        phase == BookQuickVoicePhase.thinking ||
        hold.holdPending) {
      return const WxLoading(size: 16);
    }
    if (phase == BookQuickVoicePhase.speaking) {
      return Icon(Icons.graphic_eq_rounded, size: 16, color: widget.palette.ink);
    }
    return null;
  }

  bool _showWaitMs(BookQuickVoicePhase phase) {
    final hold = widget.session.hold;
    if (hold.holding && phase == BookQuickVoicePhase.listening) return false;
    return phase == BookQuickVoicePhase.recognizing ||
        phase == BookQuickVoicePhase.thinking ||
        hold.sttBusy ||
        hold.holdPending;
  }

  IconData _micIcon(BookQuickVoicePhase phase) {
    switch (phase) {
      case BookQuickVoicePhase.speaking:
        return Icons.graphic_eq_rounded;
      case BookQuickVoicePhase.thinking:
        return Icons.auto_awesome_rounded;
      case BookQuickVoicePhase.recognizing:
        return Icons.transcribe_rounded;
      case BookQuickVoicePhase.listening:
        return Icons.mic_rounded;
      case BookQuickVoicePhase.idle:
        return Icons.mic_none_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = widget.session.phase;
    final hold = widget.session.hold;
    _syncWave(phase, hold.holding);
    final accent = _accentFor(phase);
    final showStatus = widget.session.showsStatus;
    final label = widget.session.statusLabel;
    final active =
        showStatus && phase != BookQuickVoicePhase.idle || hold.holding || hold.sttBusy;
    final pulseActive = active &&
        (phase == BookQuickVoicePhase.listening ||
            phase == BookQuickVoicePhase.speaking ||
            phase == BookQuickVoicePhase.thinking);
    final statusLeading = _statusLeading(phase);
    final caption = widget.session.voiceCaption;
    final showCaption = widget.session.showsVoiceCaption;
    final maxCaptionW = MediaQuery.sizeOf(context).width * 0.72;

    return Padding(
      padding: EdgeInsets.only(right: 14, bottom: kQuickVoiceFabBottomPad + widget.bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          AnimatedSize(
            duration: Wx.motion,
            curve: Wx.motionCurve,
            alignment: Alignment.bottomCenter,
            child: showCaption
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: VoiceCaptionPanel(
                      text: caption,
                      palette: widget.palette,
                      maxWidth: maxCaptionW,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
          AnimatedSize(
            duration: Wx.motion,
            curve: Wx.motionCurve,
            alignment: Alignment.centerRight,
            child: showStatus && label.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (_showWaitMs(phase))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4, right: 2),
                            child: WaitMsTicker(
                              key: const Key('wx-wait-ms'),
                              color: widget.palette.ink.withValues(alpha: 0.55),
                            ),
                          ),
                        Material(
                      elevation: 2,
                      shadowColor: Colors.black26,
                      color: widget.palette.paper.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(Wx.radius),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Wx.radius),
                          border: Border.all(color: accent.withValues(alpha: 0.35)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (statusLeading != null) ...[
                              statusLeading,
                              const SizedBox(width: 8),
                            ],
                            Text(
                              label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: widget.palette.ink.withValues(alpha: 0.92),
                                letterSpacing: 0.2,
                              ),
                            ),
                          ],
                        ),
                      ),
                        ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: widget.enabled
                ? (e) {
                    _pointerDownMs = DateTime.now().millisecondsSinceEpoch;
                    _pointerDownY = e.position.dy;
                    _fingerDown = true;
                    _tapCancelArm = widget.session.tapToCancelActive;
                    if (_tapCancelArm) {
                      _promoteHold?.cancel();
                      _promoteHold = Timer(const Duration(milliseconds: _tapMaxMs), () {
                        if (!mounted || !_fingerDown) return;
                        _tapCancelArm = false;
                        unawaited(_startHold(_pointerDownY ?? e.position.dy));
                      });
                      return;
                    }
                    unawaited(_startHold(e.position.dy));
                  }
                : null,
            onPointerMove: widget.enabled
                ? (e) {
                    if (_tapCancelArm) return;
                    widget.session.pointerMove(e.position.dy);
                  }
                : null,
            onPointerUp: widget.enabled
                ? (e) => unawaited(_onMicPointerUp(e.position.dy))
                : null,
            onPointerCancel: widget.enabled
                ? (e) => unawaited(_onMicPointerUp(e.position.dy))
                : null,
            child: Semantics(
              button: true,
              label: label.isNotEmpty ? label : '按住快问快答',
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final opacity = pulseActive ? 0.72 + _pulse.value * 0.28 : 1.0;
                  return Opacity(opacity: opacity, child: child);
                },
                child: Material(
                  elevation: 0,
                  color: widget.palette.paper.withValues(alpha: 0.94),
                  shape: CircleBorder(
                    side: BorderSide(
                      color: active
                          ? accent.withValues(alpha: 0.55)
                          : widget.palette.ink.withValues(alpha: 0.12),
                      width: active ? 2 : 1,
                    ),
                  ),
                  child: SizedBox(
                    key: const Key('wx-quick-voice-mic'),
                    width: kQuickVoiceMicSize,
                    height: kQuickVoiceMicSize,
                    child: Icon(
                      _micIcon(phase),
                      size: 24,
                      color: widget.enabled ? accent : widget.palette.muted,
                    ),
                  ),
                ),
              ),
            ),
          ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Live elapsed wait time (milliseconds precision) above the status chip.
class WaitMsTicker extends StatefulWidget {
  const WaitMsTicker({super.key, required this.color});

  final Color color;

  @override
  State<WaitMsTicker> createState() => _WaitMsTickerState();
}

class _WaitMsTickerState extends State<WaitMsTicker> {
  final Stopwatch _watch = Stopwatch()..start();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 32), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seconds = _watch.elapsedMilliseconds / 1000;
    return Text(
      '${seconds.toStringAsFixed(3)}s',
      key: const Key('wx-wait-ms-text'),
      style: TextStyle(
        fontSize: 10,
        height: 1,
        fontFeatures: const [FontFeature.tabularFigures()],
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
        color: widget.color,
      ),
    );
  }
}
