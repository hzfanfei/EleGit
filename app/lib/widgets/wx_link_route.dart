import 'package:flutter/material.dart';

import '../api/link_route.dart';
import '../theme.dart';

/// Wifi means the phone is on the LAN. Cloud means the request goes through the tunnel.
class WxLinkRouteMark extends StatelessWidget {
  const WxLinkRouteMark({super.key, required this.baseUrl});

  final String baseUrl;

  @override
  Widget build(BuildContext context) {
    final lan = isLanBaseUrl(baseUrl);
    final label = linkRouteLabel(baseUrl);
    return Tooltip(
      message: label,
      child: Icon(
        lan ? Icons.wifi : Icons.cloud_outlined,
        key: Key(lan ? 'wx-link-lan' : 'wx-link-tunnel'),
        size: 16,
        color: lan ? Wx.ok : Wx.accent,
        semanticLabel: label,
      ),
    );
  }
}
