import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../persist/book_reader_prefs.dart';
import '../voice/book_quick_voice_session.dart';
import 'wx_hold_to_speak.dart';

/// Floating mic for book quick voice Q&A — hold to talk, no transcript UI.
class BookQuickVoiceFab extends StatefulWidget {
  const BookQuickVoiceFab({
    super.key,
    required this.session,
    required this.palette,
    required this.enabled,
    this.bottomInset = 0,
  });

  final BookQuickVoiceSession session;
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
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );

  @override
  void dispose() {
    _pulse.dispose();
    _wave.dispose();
    super.dispose();
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
    if (phase == BookQuickVoicePhase.recognizing || hold.sttBusy) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: widget.palette.ink.withValues(alpha: 0.85),
        ),
      );
    }
    if (phase == BookQuickVoicePhase.thinking) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: widget.palette.ink.withValues(alpha: 0.75),
        ),
      );
    }
    if (phase == BookQuickVoicePhase.speaking) {
      return Icon(Icons.graphic_eq_rounded, size: 16, color: widget.palette.ink);
    }
    if (hold.holdPending) {
      return SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: widget.palette.muted,
        ),
      );
    }
    return null;
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

    return Padding(
      padding: EdgeInsets.only(right: 14, bottom: 12 + widget.bottomInset),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerRight,
            child: showStatus && label.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Material(
                      elevation: 2,
                      shadowColor: Colors.black26,
                      color: widget.palette.paper.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
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
                  )
                : const SizedBox.shrink(),
          ),
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: widget.enabled
                ? (e) {
                    HapticFeedback.lightImpact();
                    unawaited(widget.session.pointerDown(e.position.dy));
                  }
                : null,
            onPointerMove:
                widget.enabled ? (e) => widget.session.pointerMove(e.position.dy) : null,
            onPointerUp: widget.enabled ? (_) => unawaited(widget.session.pointerUp()) : null,
            onPointerCancel:
                widget.enabled ? (_) => unawaited(widget.session.pointerUp()) : null,
            child: Semantics(
              button: true,
              label: label.isNotEmpty ? label : '按住快问快答',
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (context, child) {
                  final scale = pulseActive ? 1.0 + _pulse.value * 0.06 : 1.0;
                  return Transform.scale(scale: scale, child: child);
                },
                child: Material(
                  elevation: active ? 4 : 2,
                  shadowColor: Colors.black26,
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
                    width: 48,
                    height: 48,
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
    );
  }
}
