import 'dart:async';

import 'package:flutter/material.dart';

import '../api/link_quality.dart';
import '../api/link_route.dart';
import '../api/wenxiang_api.dart';
import '../theme.dart';

/// Game-style ping: route icon + signal bars + ms, probed via [WenxiangApi.probeHealth].
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

  String _msLabel() {
    if (_tier == LinkQualityTier.offline) return '断连';
    if (_tier == LinkQualityTier.unknown) return '--';
    return '${_rttMs ?? '--'}ms';
  }

  @override
  Widget build(BuildContext context) {
    final lan = isLanBaseUrl(widget.api.baseUrl);
    final routeIcon = lan ? Icons.wifi : Icons.cloud_outlined;
    final routeKey = lan ? 'wx-link-lan' : 'wx-link-tunnel';
    final color = _tierColor(_tier);
    final filled = linkQualityFilledBars(_tier);
    final msStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: widget.compact ? 11 : 12,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: color,
          height: 1.1,
        );

    return Tooltip(
      message: _tooltip(),
      child: Semantics(
        label: _tooltip().replaceAll('\n', ' '),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Icon(
              routeIcon,
              key: Key(routeKey),
              size: widget.compact ? 14 : 16,
              color: Wx.muted,
            ),
            const SizedBox(width: 4),
            _PingBars(filled: filled, activeColor: color, height: widget.compact ? 11 : 13),
            const SizedBox(width: 5),
            Text(
              _msLabel(),
              key: const Key('wx-link-ping-ms'),
              style: msStyle,
            ),
          ],
        ),
      ),
    );
  }
}

class _PingBars extends StatelessWidget {
  const _PingBars({
    required this.filled,
    required this.activeColor,
    required this.height,
  });

  final int filled;
  final Color activeColor;
  final double height;

  @override
  Widget build(BuildContext context) {
    const count = 4;
    const gap = 2.0;
    const barW = 3.0;
    final heights = [0.35, 0.55, 0.75, 1.0];
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < count; i++) ...[
            if (i > 0) const SizedBox(width: gap),
            Container(
              width: barW,
              height: height * heights[i],
              decoration: BoxDecoration(
                color: i < filled ? activeColor : Wx.hairline,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
