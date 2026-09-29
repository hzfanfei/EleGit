import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/link_quality.dart';
import '../api/link_route.dart';
import '../api/wenxiang_api.dart';
import '../theme.dart';

/// LAN: wifi arcs only. Tunnel: cloud on top + short signal bars at bottom.
class WxLinkQualityMark extends StatefulWidget {
  const WxLinkQualityMark({
    super.key,
    required this.api,
    this.compact = true,
  });

  final WenxiangApi api;
  final bool compact;

  @override
  State<WxLinkQualityMark> createState() => _WxLinkQualityMarkState();
}

class _WxLinkQualityMarkState extends State<WxLinkQualityMark> {
  static const _probeEvery = Duration(seconds: 4);

  LinkQualityTier _tier = LinkQualityTier.unknown;
  int? _rttMs;
  bool _probing = false;
  Timer? _timer;
  int _probeGen = 0;

  @override
  void initState() {
    super.initState();
    widget.api.linkEpoch.addListener(_onLinkChanged);
    _timer = Timer.periodic(_probeEvery, (_) => _probe());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_probe());
    });
  }

  @override
  void didUpdateWidget(covariant WxLinkQualityMark oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api) {
      oldWidget.api.linkEpoch.removeListener(_onLinkChanged);
      widget.api.linkEpoch.addListener(_onLinkChanged);
      unawaited(_probe());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.api.linkEpoch.removeListener(_onLinkChanged);
    super.dispose();
  }

  void _onLinkChanged() {
    if (!mounted) return;
    setState(() {
      _tier = LinkQualityTier.unknown;
      _rttMs = null;
    });
    unawaited(_probe());
  }

  Future<void> _probe() async {
    if (_probing) return;
    _probing = true;
    final gen = ++_probeGen;
    try {
      final result = await widget.api.probeHealth();
      if (!mounted || gen != _probeGen) return;
      setState(() {
        _tier = linkQualityTier(ok: result.ok, rttMs: result.rttMs);
        _rttMs = result.ok ? result.rttMs : null;
      });
    } finally {
      _probing = false;
    }
  }

  Color _tierColor(LinkQualityTier tier) {
    switch (tier) {
      case LinkQualityTier.good:
        return Wx.ok;
      case LinkQualityTier.fair:
        return Wx.accent;
      case LinkQualityTier.poor:
        return const Color(0xFFD4A574);
      case LinkQualityTier.offline:
        return Wx.danger;
      case LinkQualityTier.unknown:
        return Wx.faint;
    }
  }

  String _tooltip() {
    final route = linkRouteLabel(widget.api.baseUrl);
    final quality = linkQualityTierLabel(_tier);
    if (_tier == LinkQualityTier.offline) {
      return '$route · $quality\n无法访问问象 /health';
    }
    if (_tier == LinkQualityTier.unknown) {
      return '$route · 正在测量延迟…';
    }
    return '$route · ${_rttMs}ms · $quality';
  }

  @override
  Widget build(BuildContext context) {
    final lan = isLanBaseUrl(widget.api.baseUrl);
    final routeKey = lan ? 'wx-link-lan' : 'wx-link-tunnel';
    final w = widget.compact ? 20.0 : 22.0;
    final h = lan ? w : (widget.compact ? 22.0 : 24.0);

    return Tooltip(
      message: _tooltip(),
      child: Semantics(
        label: _tooltip().replaceAll('\n', ' '),
        child: CustomPaint(
          key: Key(routeKey),
          size: Size(w, h),
          painter: _LinkQualityGlyphPainter(
            tunnel: !lan,
            filledBars: linkQualityFilledBars(_tier),
            activeColor: _tierColor(_tier),
            idleColor: Wx.hairline,
            routeColor: _tier == LinkQualityTier.offline
                ? Wx.danger
                : (_tier == LinkQualityTier.unknown ? Wx.faint : Wx.muted),
            offline: _tier == LinkQualityTier.offline,
          ),
        ),
      ),
    );
  }
}

class _LinkQualityGlyphPainter extends CustomPainter {
  _LinkQualityGlyphPainter({
    required this.tunnel,
    required this.filledBars,
    required this.activeColor,
    required this.idleColor,
    required this.routeColor,
    required this.offline,
  });

  final bool tunnel;
  final int filledBars;
  final Color activeColor;
  final Color idleColor;
  final Color routeColor;
  final bool offline;

  static const _arcCount = 4;
  static const _start = -math.pi * 0.75;
  static const _sweep = math.pi * 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final stroke = w * 0.11;

    if (tunnel) {
      _paintCloud(canvas, w, h, stroke);
      _paintShortBars(canvas, w, h);
      if (offline) _paintSlash(canvas, w, h, stroke);
      return;
    }

    final arcPaint = (Color c) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;

    final origin = Offset(w * 0.5, h * 0.88);
    final maxR = w * 0.46;
    for (var i = 0; i < _arcCount; i++) {
      final t = (i + 1) / _arcCount;
      final r = maxR * t;
      final lit = !offline && i < filledBars;
      final color = offline ? idleColor : (lit ? activeColor : idleColor);
      canvas.drawArc(
        Rect.fromCircle(center: origin, radius: r),
        _start,
        _sweep,
        false,
        arcPaint(color),
      );
    }
    if (offline) _paintSlash(canvas, w, h, stroke);
  }

  void _paintCloud(Canvas canvas, double w, double h, double stroke) {
    final fill = Paint()
      ..color = routeColor.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;
    final outline = Paint()
      ..color = routeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.8
      ..strokeJoin = StrokeJoin.round;

    final top = h * 0.06;
    final bottom = h * 0.58;
    final path = Path()
      ..moveTo(w * 0.2, bottom)
      ..cubicTo(w * 0.06, bottom, w * 0.04, top + h * 0.18, w * 0.18, top + h * 0.12)
      ..cubicTo(w * 0.16, top, w * 0.34, top - h * 0.02, w * 0.44, top + h * 0.1)
      ..cubicTo(w * 0.52, top - h * 0.04, w * 0.72, top - h * 0.02, w * 0.78, top + h * 0.14)
      ..cubicTo(w * 0.94, top + h * 0.12, w * 0.98, bottom - h * 0.06, w * 0.84, bottom)
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, outline);
  }

  void _paintShortBars(Canvas canvas, double w, double h) {
    const count = 4;
    const gap = 2.0;
    final barW = w * 0.14;
    final maxBarH = h * 0.22;
    final baseY = h * 0.96;
    final heights = [0.45, 0.65, 0.85, 1.0];
    final totalW = count * barW + (count - 1) * gap;
    var x = (w - totalW) / 2;

    for (var i = 0; i < count; i++) {
      final barH = maxBarH * heights[i];
      final lit = !offline && i < filledBars;
      final paint = Paint()
        ..color = offline ? idleColor : (lit ? activeColor : idleColor);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, baseY - barH, barW, barH),
        const Radius.circular(1),
      );
      canvas.drawRRect(r, paint);
      x += barW + gap;
    }
  }

  void _paintSlash(Canvas canvas, double w, double h, double stroke) {
    final slash = Paint()
      ..color = Wx.danger
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(w * 0.2, h * 0.15), Offset(w * 0.8, h * 0.85), slash);
  }

  @override
  bool shouldRepaint(covariant _LinkQualityGlyphPainter old) {
    return old.tunnel != tunnel ||
        old.filledBars != filledBars ||
        old.activeColor != activeColor ||
        old.idleColor != idleColor ||
        old.routeColor != routeColor ||
        old.offline != offline;
  }
}
