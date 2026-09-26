import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme.dart';
import '../utils/text_fit.dart';
import 'wx_rich_text.dart';

final _hrLine = RegExp(r'^ {0,3}(?:\*{3,}|-{3,}|_{3,})[ \t]*$');

class _MdPiece {
  const _MdPiece.rule() : rule = true, text = '';
  const _MdPiece.text(this.text) : rule = false;

  final bool rule;
  final String text;
}

/// Pulls horizontal rules out so they can be a real hairline. flutter_markdown
/// draws `hr` as a zero-height box, so the line never shows.
List<_MdPiece> _splitRules(String data) {
  final pieces = <_MdPiece>[];
  final buf = StringBuffer();
  var fence = false;

  void flush() {
    final text = buf.toString().trim();
    buf.clear();
    if (text.isNotEmpty) pieces.add(_MdPiece.text(text));
  }

  for (final line in data.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      fence = !fence;
      buf.writeln(line);
      continue;
    }
    if (!fence && _hrLine.hasMatch(line.trimRight())) {
      // A dash line glued to the previous paragraph is a setext heading.
      final dashes = RegExp(r'^ {0,3}-').hasMatch(line.trimRight());
      if (dashes && _continuesSetext(_previousLine(buf))) {
        buf.writeln(line);
        continue;
      }
      flush();
      pieces.add(const _MdPiece.rule());
      continue;
    }
    buf.writeln(line);
  }
  flush();
  return pieces;
}

String _previousLine(StringBuffer buf) {
  final raw = buf.toString();
  if (raw.isEmpty) return '';
  final lines = raw.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  if (lines.isEmpty) return '';
  return lines.last.trim();
}

bool _continuesSetext(String previous) {
  if (previous.isEmpty) return false;
  if (previous.startsWith('#') || previous.startsWith('>') || previous.startsWith('|')) {
    return false;
  }
  if (RegExp(r'^[-*+]\s').hasMatch(previous)) return false;
  if (RegExp(r'^\d+\.\s').hasMatch(previous)) return false;
  if (_hrLine.hasMatch(previous)) return false;
  return true;
}

String _fenceLanguage(dynamic element) {
  final children = element.children;
  if (children is List) {
    for (final child in children) {
      final attrs = child.attributes;
      if (attrs is! Map) continue;
      final cls = attrs['class'];
      if (cls is! String) continue;
      final match = RegExp(r'language-(\S+)').firstMatch(cls);
      if (match != null) return match.group(1)!;
    }
  }
  return '';
}

/// Fenced code blocks that wrap long lines (shared by chat and book reader).
class WrappingMarkdownCodeBlock extends MarkdownElementBuilder {
  WrappingMarkdownCodeBlock(this.style);

  final TextStyle style;

  @override
  Widget? visitText(dynamic text, TextStyle? preferredStyle) {
    return const SizedBox.shrink();
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    dynamic element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = (element.textContent as String).replaceAll(RegExp(r'\s+$'), '');
    return WxFencedCode(
      code: code,
      language: _fenceLanguage(element),
      framed: false,
      style: style,
      blockKey: const Key('wx-md-code'),
    );
  }
}

Widget _wxBullet(MarkdownBulletParameters params) {
  final nested = params.nestLevel > 0;
  final ordered = params.style == BulletStyle.orderedList;
  final mark = ordered ? '${params.index + 1}.' : (nested ? '◦' : '•');
  return Padding(
    padding: const EdgeInsets.only(right: 6, top: 1),
    child: Text(
      mark,
      textAlign: TextAlign.right,
      style: TextStyle(
        color: nested ? Wx.faint : Wx.muted,
        fontSize: ordered ? 14 : (nested ? 12 : 15),
        height: 1.45,
        fontFamilyFallback: Wx.fontFallback,
      ),
    ),
  );
}

/// One markdown pipeline: prose soft-wrap, [WxMarkdownTable], wrapping code fences.
class WxUnifiedMarkdownBody extends StatelessWidget {
  const WxUnifiedMarkdownBody({
    super.key,
    required this.data,
    required this.styleSheet,
    this.onTapLink,
    this.onSelectionChanged,
    this.sizedImageBuilder,
    this.selectable = true,
    this.splitTables = true,
    this.softWrapProse = true,
    this.tableTheme = WxMarkdownTableTheme.chat,
  });

  final String data;
  final MarkdownStyleSheet styleSheet;
  final void Function(String text, String? href, String? title)? onTapLink;
  final MarkdownOnSelectionChangedCallback? onSelectionChanged;
  final MarkdownSizedImageBuilder? sizedImageBuilder;
  final bool selectable;
  final bool splitTables;
  final bool softWrapProse;
  final WxMarkdownTableTheme tableTheme;

  Widget _markdownChunk(String chunk) {
    final sheet = styleSheet;
    final codeStyle = (sheet.code ?? const TextStyle()).copyWith(backgroundColor: null);
    final prepared = softWrapProse
        ? prepareChatMarkdownForDisplay(chunk, isTableLine: isMarkdownTableLine)
        : chunk;
    return MarkdownBody(
      data: prepared,
      selectable: selectable,
      styleSheet: sheet,
      builders: {'pre': WrappingMarkdownCodeBlock(codeStyle)},
      bulletBuilder: _wxBullet,
      checkboxBuilder: (checked) => WxTaskBox(checked: checked),
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      onSelectionChanged: onSelectionChanged,
      onTapLink: onTapLink,
      sizedImageBuilder: sizedImageBuilder,
    );
  }

  Widget _withRules(String chunk) {
    final pieces = _splitRules(chunk);
    if (pieces.isEmpty) return _markdownChunk(chunk);
    if (pieces.length == 1 && !pieces.first.rule) return _markdownChunk(pieces.first.text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final piece in pieces)
          if (piece.rule) const WxMarkdownRule() else _markdownChunk(piece.text),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!splitTables) {
      return _withRules(data);
    }
    final segments = splitChatMarkdownSegments(data);
    if (segments.length == 1 && segments.first.kind == ChatMdSegmentKind.markdown) {
      return _withRules(segments.first.text);
    }
    if (segments.isEmpty) {
      return _withRules(data);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          if (segments[i].kind == ChatMdSegmentKind.table)
            WxMarkdownTable(
              segments[i].text,
              selectable: selectable,
              theme: tableTheme,
            )
          else
            _withRules(segments[i].text),
        ],
      ],
    );
  }
}
