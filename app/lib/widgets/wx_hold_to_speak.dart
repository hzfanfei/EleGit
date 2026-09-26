import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Live partial STT text above the composer — chip/bubble, not plain body text.
class WxHoldLiveChip extends StatelessWidget {
  const WxHoldLiveChip({
    super.key,
    required this.text,
    required this.recognizing,
    this.onCancelRecognize,
  });

  final String text;
  final bool recognizing;
  final VoidCallback? onCancelRecognize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canCancel = recognizing && onCancelRecognize != null;
    final body = Container(
        key: const Key('wx-hold-live-chip'),
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 220),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: Wx.raised,
          borderRadius: BorderRadius.circular(Wx.radius),
          border: Border.all(
            color: recognizing ? Wx.accent.withValues(alpha: 0.45) : Wx.hairline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  recognizing ? '识别中' : '听到',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: recognizing ? Wx.accent : Wx.muted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                  ),
                ),
                if (canCancel) ...[
                  const Spacer(),
                  Text(
                    '点按取消',
                    style: theme.textTheme.labelSmall?.copyWith(color: Wx.muted),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 168),
              child: SingleChildScrollView(
                child: Text(
                  text,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: Wx.text,
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    return Align(
      alignment: Alignment.centerLeft,
      child: canCancel
          ? Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onCancelRecognize!();
                },
                borderRadius: BorderRadius.circular(Wx.radius),
                child: body,
              ),
            )
          : body,
    );
  }
}

/// Doubao-style hold pad: pill, accent/cancel fills, wave while recording.
class WxHoldToSpeakPad extends StatefulWidget {
  const WxHoldToSpeakPad({
    super.key,
    required this.enabled,
    required this.holding,
    required this.holdCancel,
    required this.sttBusy,
    required this.hint,
    required this.onHoldStart,
    required this.onHoldMove,
    required this.onHoldEnd,
    this.onCancelRecognize,
  });

  final bool enabled;
  final bool holding;
  final bool holdCancel;
  final bool sttBusy;
  final String hint;
  final Future<void> Function(double globalY) onHoldStart;
  final void Function(double globalY) onHoldMove;
  final Future<void> Function() onHoldEnd;
  final VoidCallback? onCancelRecognize;

  @override
  State<WxHoldToSpeakPad> createState() => _WxHoldToSpeakPadState();
}

class _WxHoldToSpeakPadState extends State<WxHoldToSpeakPad>
    with SingleTickerProviderStateMixin {
  bool _pointerActive = false;
  AnimationController? _wave;

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
  }

  @override
  void didUpdateWidget(covariant WxHoldToSpeakPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wave = _wave;
    if (wave == null) return;
    if (widget.holding && !widget.holdCancel && !widget.sttBusy) {
      if (!wave.isAnimating) wave.repeat();
    } else {
      if (wave.isAnimating) wave.stop();
    }
  }

  @override
  void dispose() {
    _wave?.dispose();
    _wave = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final holding = widget.holding;
    final cancel = widget.holdCancel;
    final sttBusy = widget.sttBusy;

    Color bg;
    Color border;
    Color labelColor;

    if (!enabled) {
      bg = Wx.surface;
      border = Wx.hairline;
      labelColor = Wx.faint;
    } else if (cancel && holding) {
      bg = Wx.danger.withValues(alpha: 0.22);
      border = Wx.danger.withValues(alpha: 0.65);
      labelColor = Wx.text;
    } else if (holding) {
      bg = Wx.accent.withValues(alpha: 0.32);
      border = Wx.accent.withValues(alpha: 0.55);
      labelColor = Wx.text;
    } else if (sttBusy) {
      bg = Wx.raised;
      border = Wx.accent.withValues(alpha: 0.35);
      labelColor = Wx.text;
    } else {
      bg = Wx.surface;
      border = Wx.hairline;
      labelColor = Wx.text;
    }

    final scale = holding && !sttBusy ? 0.98 : 1.0;

    return Listener(
      key: const Key('wx-hold-speak'),
      behavior: HitTestBehavior.opaque,
      onPointerDown: enabled && sttBusy && widget.onCancelRecognize != null
          ? (_) {
              HapticFeedback.selectionClick();
              widget.onCancelRecognize!();
            }
          : enabled && !sttBusy
              ? (event) {
                  _pointerActive = true;
                  HapticFeedback.lightImpact();
                  widget.onHoldStart(event.position.dy);
                }
              : null,
      onPointerMove: enabled && _pointerActive
          ? (event) {
              widget.onHoldMove(event.position.dy);
            }
          : null,
      onPointerUp: enabled && _pointerActive
          ? (_) {
              _pointerActive = false;
              widget.onHoldEnd();
            }
          : null,
      onPointerCancel: enabled && _pointerActive
          ? (_) {
              _pointerActive = false;
              widget.onHoldEnd();
            }
          : null,
      child: AnimatedScale(
        scale: scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(Wx.radius),
            border: Border.all(color: border, width: holding || sttBusy ? 1.5 : 1),
            boxShadow: holding && !cancel
                ? [
                    BoxShadow(
                      color: Wx.accent.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (sttBusy) ...[
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: enabled ? Wx.accent : Wx.faint,
                  ),
                ),
                const SizedBox(width: 10),
              ] else if (holding && !cancel) ...[
                WxVoiceWaveBars(color: labelColor, animation: _wave!),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  widget.hint,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: labelColor,
                        fontWeight: holding || sttBusy ? FontWeight.w600 : FontWeight.w500,
                        letterSpacing: holding ? 0.2 : 0,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WxVoiceWaveBars extends StatelessWidget {
  const WxVoiceWaveBars({
    super.key,
    required this.color,
    required this.animation,
  });

  final Color color;
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(4, (i) {
            final t = animation.value * 2 * math.pi + i * 0.85;
            final h = 6 + (math.sin(t) + 1) * 5;
            return Padding(
              padding: EdgeInsets.only(right: i == 3 ? 0 : 3),
              child: Container(
                width: 3,
                height: h,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
