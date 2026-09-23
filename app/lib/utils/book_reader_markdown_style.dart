import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../persist/book_reader_prefs.dart';
import '../theme.dart';

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
      decorationColor: Wx.accent.withValues(alpha: 0.55),
      // Soft tint behind the link text — makes the tap target obvious
      // without turning each link into a button. flutter_markdown's
      // TapGestureRecognizer is attached to the span itself, so the
      // highlighted region is exactly the link text, not the paragraph.
      backgroundColor: Wx.accent.withValues(alpha: 0.16),
    ),
    h1: TextStyle(
      fontSize: settings.fontSize + 6,
      fontWeight: FontWeight.w700,
      height: 1.35,
      color: palette.ink,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h2: TextStyle(
      fontSize: settings.fontSize + 3,
      fontWeight: FontWeight.w700,
      height: 1.35,
      color: palette.ink,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h3: TextStyle(
      fontSize: settings.fontSize + 1,
      fontWeight: FontWeight.w600,
      height: 1.4,
      color: palette.ink,
      fontFamilyFallback: Wx.fontFallback,
    ),
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
      borderRadius: BorderRadius.circular(10),
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
    blockSpacing: 12,
    listIndent: 24,
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: palette.ink.withValues(alpha: 0.14), width: 0.6)),
    ),
  );
}
