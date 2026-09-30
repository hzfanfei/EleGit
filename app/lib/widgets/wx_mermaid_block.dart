import 'package:flutter/material.dart';

import '../theme.dart';
import 'wx_mermaid_webview.dart';
import 'wx_rich_text.dart';

/// Renders ```mermaid fences with [WxMermaidWebView] (mermaid.js).
class WxMermaidBlock extends StatelessWidget {
  const WxMermaidBlock({
    super.key,
    required this.code,
    required this.closed,
    required this.theme,
    this.monoStyle,
  });

  final String code;
  final bool closed;
  final WxMermaidWebTheme theme;
  final TextStyle? monoStyle;

  static bool isMermaidLanguage(String name) {
    return name.trim().toLowerCase() == 'mermaid';
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = code.trim();
    if (!closed || trimmed.isEmpty) {
      return WxFencedCode(
        code: trimmed.isEmpty ? '…' : trimmed,
        language: 'mermaid',
        blockKey: const Key('wx-mermaid-pending'),
        style: monoStyle ?? const TextStyle(fontFamily: 'ui-monospace', fontSize: 13),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DecoratedBox(
        key: const Key('wx-mermaid-diagram'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Wx.radius),
          border: Border.all(color: Wx.hairline),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Wx.radius),
          child: WxMermaidWebView(
            code: trimmed,
            theme: theme,
            monoStyle: monoStyle,
          ),
        ),
      ),
    );
  }
}
