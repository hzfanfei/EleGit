import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';
import '../widgets/wx_rich_text.dart';

MarkdownStyleSheet bookReaderMarkdownStyle({
  required ThemeData theme,
  required ReaderPalette palette,
  required ReaderSettings settings,
}) {
  final codeFill = Color.lerp(palette.paper, palette.ink, 0.07) ?? palette.paper;
  final quoteFill = Color.lerp(palette.paper, palette.ink, 0.05) ?? palette.paper;
  final body = TextStyle(
    fontSize: settings.fontSize,
    height: settings.lineHeight,
    letterSpacing: 0.12,
    color: palette.ink,
    fontFamilyFallback: Wx.fontFallback,
  );
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    a: body.copyWith(
      color: Wx.accent,
      decoration: TextDecoration.underline,
      decorationColor: Wx.accent.withValues(alpha: 0.45),
    ),
    h1: _heading(settings.fontSize + 8, palette),
    h2: _heading(settings.fontSize + 4, palette),
    h3: _heading(settings.fontSize + 2, palette),
    h4: _heading(settings.fontSize + 1, palette),
    h5: _heading(settings.fontSize, palette),
    h6: _heading(settings.fontSize, palette),
    h1Padding: const EdgeInsets.only(top: 18, bottom: 6),
    h2Padding: const EdgeInsets.only(top: 16, bottom: 4),
    h3Padding: const EdgeInsets.only(top: 12, bottom: 2),
    h4Padding: const EdgeInsets.only(top: 10, bottom: 2),
    h5Padding: const EdgeInsets.only(top: 8, bottom: 2),
    h6Padding: const EdgeInsets.only(top: 8, bottom: 2),
    em: TextStyle(fontStyle: FontStyle.italic, color: palette.ink),
    strong: TextStyle(fontWeight: FontWeight.w700, color: palette.ink),
    del: TextStyle(
      decoration: TextDecoration.lineThrough,
      color: palette.muted,
    ),
    listBullet: body,
    blockquote: body.copyWith(color: palette.muted, fontSize: settings.fontSize - 0.5),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
    blockquoteDecoration: BoxDecoration(
      color: quoteFill,
      borderRadius: BorderRadius.circular(8),
      border: Border(left: BorderSide(color: Wx.accent.withValues(alpha: 0.55), width: 3)),
    ),
    code: TextStyle(
      fontFamily: 'ui-monospace',
      fontFamilyFallback: const ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
      fontSize: settings.fontSize * 0.86,
      height: 1.45,
      color: palette.ink,
      backgroundColor: codeFill,
    ),
    codeblockPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    codeblockDecoration: BoxDecoration(
      color: codeFill,
      borderRadius: BorderRadius.circular(Wx.radius),
      border: Border.all(color: palette.ink.withValues(alpha: 0.12)),
    ),
    tableHead: TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: settings.fontSize * 0.9,
      color: palette.ink,
    ),
    tableBody: body.copyWith(fontSize: settings.fontSize * 0.9),
    tableBorder: TableBorder.all(color: palette.ink.withValues(alpha: 0.12), width: 0.6),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    tableColumnWidth: const IntrinsicColumnWidth(),
    blockSpacing: 22,
    listIndent: 24,
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: palette.ink.withValues(alpha: 0.14), width: 0.6)),
    ),
  );
}

WxMarkdownTableTheme bookReaderMarkdownTableTheme({
  required ReaderPalette palette,
  required double fontSize,
}) {
  final frameFill = Color.lerp(palette.paper, palette.ink, 0.06) ?? palette.paper;
  final headerFill = Color.lerp(palette.paper, palette.ink, 0.11) ?? palette.paper;
  final border = palette.ink.withValues(alpha: 0.14);
  return WxMarkdownTableTheme(
    frameFill: frameFill,
    headerFill: headerFill,
    borderColor: border,
    headerInk: palette.ink,
    bodyInk: palette.ink,
    zebraFill: palette.ink.withValues(alpha: 0.045),
    headerUnderline: Wx.accent.withValues(alpha: 0.55),
    cellFontSize: fontSize * 0.9,
  );
}

TextStyle _heading(double size, ReaderPalette palette) {
  return TextStyle(
    fontFamily: Wx.serif,
    fontFamilyFallback: Wx.fontFallback,
    fontSize: size,
    fontWeight: FontWeight.w600,
    letterSpacing: size >= 24 ? 0.6 : 0.35,
    height: 1.35,
    color: palette.ink,
  );
}

TextStyle bookReaderChapterStyle({
  required ReaderPalette palette,
  required ReaderSettings settings,
}) {
  return _heading(settings.fontSize + 12, palette);
}
