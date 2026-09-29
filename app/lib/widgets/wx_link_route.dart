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

  final _anchorKey = GlobalKey();

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

  Future<void> _showDetailPopover() async {
    final anchor = _anchorKey.currentContext;
    if (anchor == null || !mounted) return;
    final box = anchor.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final overlayBox =
        Overlay.of(anchor).context.findRenderObject() as RenderBox;
    final bottomRight =
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlayBox);
    final screenW = overlayBox.size.width;
    const panelW = 248.0;
    var left = bottomRight.dx - panelW + 8;
    if (left < 8) left = 8;
    if (left + panelW > screenW - 8) left = screenW - panelW - 8;
    final top = bottomRight.dy + 6;

    await showGeneralDialog<void>(
      context: anchor,
      barrierDismissible: true,
      barrierLabel: '关闭连通详情',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, _, __) {
        return _LinkQualityPopoverLayer(
          left: left,
          top: top,
          width: panelW,
          api: widget.api,
          initialTier: _tier,
          initialRttMs: _rttMs,
          tierColorOf: _tierColor,
          onClose: () => Navigator.of(dialogContext).pop(),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final lan = isLanBaseUrl(widget.api.baseUrl);
    final routeKey = lan ? 'wx-link-lan' : 'wx-link-tunnel';
    final w = widget.compact ? 20.0 : 22.0;
    final h = lan ? w : (widget.compact ? 22.0 : 24.0);

    return Tooltip(
      message: '${_tooltip()}\n点击查看详情',
      child: Semantics(
        button: true,
        label: '${_tooltip().replaceAll('\n', ' ')}，点击查看详情',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: _anchorKey,
            onTap: _showDetailPopover,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(6),
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
          ),
        ),
      ),
    );
  }
}

class _LinkQualityPopoverLayer extends StatefulWidget {
  const _LinkQualityPopoverLayer({
    required this.left,
    required this.top,
    required this.width,
    required this.api,
    required this.initialTier,
    required this.initialRttMs,
    required this.tierColorOf,
    required this.onClose,
  });

  final double left;
  final double top;
  final double width;
  final WenxiangApi api;
  final LinkQualityTier initialTier;
  final int? initialRttMs;
  final Color Function(LinkQualityTier tier) tierColorOf;
  final VoidCallback onClose;

  @override
  State<_LinkQualityPopoverLayer> createState() => _LinkQualityPopoverLayerState();
}

class _LinkQualityPopoverLayerState extends State<_LinkQualityPopoverLayer> {
  late LinkQualityTier _tier;
  int? _rttMs;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _tier = widget.initialTier;
    _rttMs = widget.initialRttMs;
    widget.api.linkEpoch.addListener(_onLinkChanged);
    unawaited(_probe());
  }

  @override
  void dispose() {
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
    setState(() => _probing = true);
    try {
      final result = await widget.api.probeHealth();
      if (!mounted) return;
      setState(() {
        _tier = linkQualityTier(ok: result.ok, rttMs: result.rttMs);
        _rttMs = result.ok ? result.rttMs : null;
      });
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
          ),
        ),
        Positioned(
          left: widget.left,
          top: widget.top,
          width: widget.width,
          child: Material(
            elevation: 8,
            color: Wx.raised,
            shadowColor: Colors.black54,
            borderRadius: BorderRadius.circular(Wx.radius),
            child: GestureDetector(
              onTap: () {},
              child: _LinkQualityDetailPanel(
                key: const Key('wx-link-quality-popover'),
                api: widget.api,
                tier: _tier,
                rttMs: _rttMs,
                probing: _probing,
                tierColor: widget.tierColorOf(_tier),
                onRetest: _probe,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LinkQualityDetailPanel extends StatelessWidget {
  const _LinkQualityDetailPanel({
    super.key,
    required this.api,
    required this.tier,
    required this.rttMs,
    required this.probing,
    required this.tierColor,
    required this.onRetest,
  });

  final WenxiangApi api;
  final LinkQualityTier tier;
  final int? rttMs;
  final bool probing;
  final Color tierColor;
  final Future<void> Function() onRetest;

  @override
  Widget build(BuildContext context) {
    final route = linkRouteLabel(api.baseUrl);
    final quality = linkQualityTierLabel(tier);
    final latency = tier == LinkQualityTier.offline
        ? '无法连通'
        : (tier == LinkQualityTier.unknown
            ? (probing ? '测量中…' : '—')
            : '${rttMs ?? '—'} ms');

    TextStyle labelStyle = Theme.of(context).textTheme.labelSmall!.copyWith(color: Wx.muted);
    TextStyle valueStyle = Theme.of(context).textTheme.bodySmall!;

    Widget row(String label, String value, {Color? valueColor}) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 52, child: Text(label, style: labelStyle)),
            Expanded(
              child: Text(
                value,
                style: valueStyle.copyWith(color: valueColor ?? Wx.text),
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('连通详情', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          row('路由', route),
          row('地址', api.baseUrl),
          row('延迟', latency, valueColor: tierColor),
          row('质量', quality, valueColor: tierColor),
          Text(
            '每 4 秒探测 GET /health',
            style: labelStyle.copyWith(fontSize: 10),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: probing ? null : () => unawaited(onRetest()),
              child: Text(probing ? '检测中…' : '立即检测'),
            ),
          ),
        ],
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
