import 'package:flutter/material.dart';
import 'package:flutter_mermaid/flutter_mermaid.dart';

import '../theme.dart';
import 'wx_rich_text.dart';

/// Renders a ```mermaid fence via [flutter_mermaid], with streaming fallback.
class WxMermaidBlock extends StatelessWidget {
  const WxMermaidBlock({
    super.key,
    required this.code,
    required this.closed,
    required this.style,
    this.monoStyle,
  });

  final String code;
  final bool closed;
  final MermaidStyle style;
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
          child: MermaidDiagram(
            code: trimmed,
            style: style,
            errorBuilder: (context, error) {
              return Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Mermaid 无法解析',
                      style: TextStyle(
                        color: Wx.muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        fontFamilyFallback: Wx.fontFallback,
                      ),
                    ),
                    const SizedBox(height: 8),
                    WxFencedCode(
                      code: trimmed,
                      language: 'mermaid',
                      framed: false,
                      style: monoStyle ?? const TextStyle(fontFamily: 'ui-monospace', fontSize: 13),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
