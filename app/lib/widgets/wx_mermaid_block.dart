import 'package:flutter/material.dart';
import 'package:flutter_mermaid/flutter_mermaid.dart';

import '../theme.dart';
import '../utils/wx_mermaid_normalize.dart';
import 'wx_rich_text.dart';

/// Visual shell so chart pixels sit in a dedicated region, not mixed with prose.
class WxMermaidFigure extends StatelessWidget {
  const WxMermaidFigure({
    super.key,
    required this.child,
    this.subtitle,
    this.shellColor,
    this.diagramKey,
  });

  final Widget child;
  final String? subtitle;
  final Color? shellColor;
  final Key? diagramKey;

  @override
  Widget build(BuildContext context) {
    final bg = shellColor ?? Wx.raised;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: DecoratedBox(
        key: diagramKey ?? const Key('wx-mermaid-diagram'),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Wx.radius),
          border: Border.all(color: Wx.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.account_tree_outlined, size: 16, color: Wx.muted),
                  const SizedBox(width: 8),
                  Text(
                    '图表',
                    style: TextStyle(
                      color: Wx.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.35,
                      fontFamilyFallback: Wx.fontFallback,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      subtitle!,
                      style: TextStyle(
                        color: Wx.faint,
                        fontSize: 11,
                        fontFamilyFallback: Wx.fontFallback,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const ColoredBox(
              color: Wx.hairline,
              child: SizedBox(height: 1),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 12),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a ```mermaid fence via [flutter_mermaid], with streaming fallback.
class WxMermaidBlock extends StatelessWidget {
  const WxMermaidBlock({
    super.key,
    required this.code,
    required this.closed,
    required this.style,
    this.monoStyle,
    this.shellColor,
  });

  final String code;
  final bool closed;
  final MermaidStyle style;
  final TextStyle? monoStyle;
  final Color? shellColor;

  static bool isMermaidLanguage(String name) {
    return name.trim().toLowerCase() == 'mermaid';
  }

  Widget _pendingBody() {
    return WxMermaidFigure(
      subtitle: '生成中',
      shellColor: shellColor,
      child: SizedBox(
        height: 96,
        child: Center(
          child: Text(
            '正在绘制图表…',
            style: TextStyle(
              color: Wx.muted,
              fontSize: 13,
              fontFamilyFallback: Wx.fontFallback,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = normalizeMermaidForFlutter(code.trim());
    if (!closed || trimmed.isEmpty) {
      return _pendingBody();
    }

    return WxMermaidFigure(
      shellColor: shellColor,
      child: RepaintBoundary(
        child: MermaidDiagram(
          code: trimmed,
          style: style,
          loadingBuilder: (context) => SizedBox(
            height: 120,
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Wx.muted.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
          errorBuilder: (context, error) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Mermaid 无法解析（已尝试兼容 ChatGPT 语法）',
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
            );
          },
        ),
      ),
    );
  }
}
