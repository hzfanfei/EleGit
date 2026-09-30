import 'package:flutter/material.dart';
import 'package:flutter_mermaid/flutter_mermaid.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';

/// Chat and book reader share [GptMarkdown]; this bundles body text + theme.
@immutable
class WxMarkdownStyle {
  const WxMarkdownStyle({
    required this.body,
    required this.gptTheme,
    required this.styleSheet,
    required this.mermaidStyle,
    required this.mermaidShellColor,
  });

  final TextStyle body;
  final GptMarkdownThemeData gptTheme;
  final GptMarkdownStyleSheet styleSheet;
  final MermaidStyle mermaidStyle;

  /// Raised card behind mermaid (distinct from chat bubble / reader paper).
  final Color mermaidShellColor;
}

WxMarkdownStyle chatMarkdownStyle(ThemeData theme) {
  final body = TextStyle(
    fontSize: 16,
    height: 1.55,
    color: Wx.text,
    fontFamilyFallback: Wx.fontFallback,
  );
  final codeFill = Wx.raised;
  final gptTheme = GptMarkdownThemeData(
    brightness: Brightness.dark,
    linkColor: Wx.accent,
    linkHoverColor: Wx.accent,
    hrLineColor: Wx.hairline,
    hrLineThickness: 0.6,
    hrLinePadding: const EdgeInsets.symmetric(vertical: 8),
    autoAddDividerLineAfterH1: false,
    h1: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.3,
      color: Wx.text,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h2: TextStyle(
      fontSize: 19,
      fontWeight: FontWeight.w700,
      height: 1.3,
      color: Wx.text,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h3: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: Wx.text,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h4: body.copyWith(fontSize: 16, fontWeight: FontWeight.w600, height: 1.35),
    h5: body.copyWith(fontWeight: FontWeight.w600),
    h6: body.copyWith(fontWeight: FontWeight.w600),
    inlineCode: InlineCodeStyle(
      fontFamily: 'ui-monospace',
      fontSizeFactor: 0.88,
      color: Wx.text,
      backgroundColor: codeFill,
    ),
  );
  return WxMarkdownStyle(
    body: body,
    gptTheme: gptTheme,
    mermaidStyle: MermaidStyle.dark(),
    mermaidShellColor: Wx.surface,
    styleSheet: GptMarkdownStyleSheet(
      link: LinkStyle(
        color: Wx.accent,
        decoration: TextDecoration.underline,
        decorationThickness: 1,
      ),
      blockQuote: BlockQuoteStyle(
        barWidth: 3,
        barColor: Wx.accent.withValues(alpha: 0.55),
        backgroundColor: Wx.surface,
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        margin: const EdgeInsets.symmetric(vertical: 4),
        textStyle: body.copyWith(color: Wx.muted, fontSize: 15.5),
      ),
      list: ListStyle(
        bulletColor: Wx.muted,
        markerTextStyle: body.copyWith(color: Wx.muted, fontSize: 14, height: 1.4),
        indent: 22,
      ),
      codeBlock: CodeBlockStyle(
        backgroundColor: codeFill,
        borderColor: Wx.hairline,
        borderWidth: 1,
        borderRadius: Radius.circular(Wx.radius),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        fontFamily: 'ui-monospace',
        fontSize: 14,
        textColor: Wx.text,
        showCopyButton: false,
        highlightWhileStreaming: true,
      ),
      table: TableStyle(
        borderColor: Wx.hairline,
        borderWidth: 0.6,
        cellPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        headerBackground: Wx.raised,
        headerTextStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14.5,
          color: Wx.text,
        ),
        rowStripeColor: const Color(0x121C1F24),
      ),
      hr: const HrStyle(thickness: 0.6, color: Wx.hairline),
    ),
  );
}

WxMarkdownStyle bookReaderMarkdownStyle({
  required ThemeData theme,
  required ReaderPalette palette,
  required ReaderSettings settings,
}) {
  final codeFill = Color.lerp(palette.paper, palette.ink, 0.07) ?? palette.paper;
  final quoteFill = Color.lerp(palette.paper, palette.ink, 0.05) ?? palette.paper;
  final headerFill = Color.lerp(palette.paper, palette.ink, 0.11) ?? palette.paper;
  final border = palette.ink.withValues(alpha: 0.14);
  final body = TextStyle(
    fontSize: settings.fontSize,
    height: settings.lineHeight,
    letterSpacing: 0.12,
    color: palette.ink,
    fontFamilyFallback: Wx.fontFallback,
  );
  TextStyle heading(double size) => TextStyle(
        fontFamily: Wx.serif,
        fontFamilyFallback: Wx.fontFallback,
        fontSize: size,
        fontWeight: FontWeight.w600,
        letterSpacing: size >= 24 ? 0.6 : 0.35,
        height: 1.35,
        color: palette.ink,
      );
  final gptTheme = GptMarkdownThemeData(
    brightness: theme.brightness,
    linkColor: Wx.accent,
    linkHoverColor: Wx.accent,
    hrLineColor: border,
    hrLineThickness: 0.6,
    autoAddDividerLineAfterH1: false,
    h1: heading(settings.fontSize + 8),
    h2: heading(settings.fontSize + 4),
    h3: heading(settings.fontSize + 2),
    h4: heading(settings.fontSize + 1),
    h5: heading(settings.fontSize),
    h6: heading(settings.fontSize),
    inlineCode: InlineCodeStyle(
      fontFamily: 'ui-monospace',
      fontSizeFactor: 0.86,
      color: palette.ink,
      backgroundColor: codeFill,
    ),
  );
  final mermaidBg = palette.paper.toARGB32();
  final mermaidStyle = MermaidStyle.neutral().copyWith(
    backgroundColor: mermaidBg,
  );
  final mermaidShell = Color.lerp(palette.paper, palette.ink, 0.06) ?? palette.paper;
  return WxMarkdownStyle(
    body: body,
    gptTheme: gptTheme,
    mermaidStyle: mermaidStyle,
    mermaidShellColor: mermaidShell,
    styleSheet: GptMarkdownStyleSheet(
      link: LinkStyle(
        color: Wx.accent,
        decoration: TextDecoration.underline,
      ),
      blockQuote: BlockQuoteStyle(
        barWidth: 3,
        barColor: Wx.accent.withValues(alpha: 0.55),
        backgroundColor: quoteFill,
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        textStyle: body.copyWith(color: palette.muted, fontSize: settings.fontSize - 0.5),
      ),
      list: ListStyle(
        bulletColor: palette.muted,
        markerTextStyle: body.copyWith(
          color: palette.muted,
          fontSize: (body.fontSize ?? 16) - 1,
          height: 1.4,
        ),
        indent: 22,
      ),
      codeBlock: CodeBlockStyle(
        backgroundColor: codeFill,
        borderColor: border,
        borderWidth: 1,
        borderRadius: Radius.circular(Wx.radius),
        fontSize: settings.fontSize * 0.86,
        textColor: palette.ink,
        showCopyButton: false,
      ),
      table: TableStyle(
        borderColor: border,
        borderWidth: 0.6,
        cellPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        headerBackground: headerFill,
        headerTextStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: settings.fontSize * 0.9,
          color: palette.ink,
        ),
        rowStripeColor: palette.ink.withValues(alpha: 0.045),
      ),
      hr: HrStyle(thickness: 0.6, color: border),
      heading: HeadingStyle(
        padding: EdgeInsets.only(top: settings.fontSize * 0.5, bottom: 4),
      ),
    ),
  );
}

TextStyle bookReaderChapterStyle({
  required ReaderPalette palette,
  required ReaderSettings settings,
}) {
  return TextStyle(
    fontFamily: Wx.serif,
    fontFamilyFallback: Wx.fontFallback,
    fontSize: settings.fontSize + 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    height: 1.35,
    color: palette.ink,
  );
}
