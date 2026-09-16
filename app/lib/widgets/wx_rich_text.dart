import 'package:flutter/material.dart';

import '../theme.dart';

enum RichKind { prose, code }

class RichBlock {
  const RichBlock(this.kind, this.text);
  final RichKind kind;
  final String text;
}

final _fence = RegExp(r'```[^\n]*\n([\s\S]*?)```');

List<RichBlock> splitRichBlocks(String src) {
  if (src.isEmpty) return const [];
  final parts = <RichBlock>[];
  var cursor = 0;
  for (final match in _fence.allMatches(src)) {
    if (match.start > cursor) {
      parts.add(RichBlock(RichKind.prose, src.substring(cursor, match.start)));
    }
    parts.add(RichBlock(RichKind.code, (match.group(1) ?? '').trimRight()));
    cursor = match.end;
  }
  if (cursor < src.length) {
    final rest = src.substring(cursor);
    final open = RegExp(r'```[^\n]*\n');
    final opened = open.firstMatch(rest);
    if (opened != null) {
      if (opened.start > 0) {
        parts.add(RichBlock(RichKind.prose, rest.substring(0, opened.start)));
      }
      parts.add(RichBlock(RichKind.code, rest.substring(opened.end)));
    } else {
      parts.add(RichBlock(RichKind.prose, rest));
    }
  }
  return parts.where((p) => p.text.trim().isNotEmpty).toList();
}

class WxReadableText extends StatelessWidget {
  const WxReadableText(
    this.text, {
    super.key,
    this.color = Wx.text,
    this.selectable = true,
  });

  final String text;
  final Color color;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final blocks = splitRichBlocks(text);
    if (blocks.isEmpty) {
      return _prose(text, color, selectable);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          if (blocks[i].kind == RichKind.code)
            _CodeBlock(blocks[i].text)
          else
            _prose(blocks[i].text, color, selectable),
        ],
      ],
    );
  }
}

final _heading = RegExp(r'^(#{1,3})\s+(.*)$');
final _bullet = RegExp(r'^[-*]\s+(.*)$');
final _ordered = RegExp(r'^(\d+)\.\s+(.*)$');

bool _hasStructure(String text) {
  return text.split('\n').any((line) {
    final t = line.trim();
    return _heading.hasMatch(t) || _bullet.hasMatch(t) || _ordered.hasMatch(t);
  });
}

Widget _prose(String text, Color color, bool selectable) {
  if (_hasStructure(text)) {
    final lines = text.split('\n');
    final children = <Widget>[];
    var gap = false;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        gap = children.isNotEmpty;
        continue;
      }
      if (children.isNotEmpty) {
        children.add(SizedBox(height: gap ? 10 : 6));
      }
      children.add(_structuredLine(line, color, selectable));
      gap = false;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
  return _inline(text, color, selectable);
}

Widget _structuredLine(String line, Color color, bool selectable) {
  final trimmed = line.trimRight();
  final heading = _heading.firstMatch(trimmed.trimLeft());
  if (heading != null) {
    final level = heading.group(1)!.length;
    final size = level == 1 ? 20.0 : level == 2 ? 18.0 : 16.0;
    return _inline(
      heading.group(2) ?? '',
      color,
      selectable,
      size: size,
      weight: FontWeight.w600,
    );
  }
  final bullet = _bullet.firstMatch(trimmed.trimLeft());
  if (bullet != null) {
    return _listRow('·', bullet.group(1) ?? '', color, selectable);
  }
  final ordered = _ordered.firstMatch(trimmed.trimLeft());
  if (ordered != null) {
    return _listRow('${ordered.group(1)}.', ordered.group(2) ?? '', color, selectable);
  }
  if (trimmed.trim().isEmpty) return const SizedBox(height: 4);
  return _inline(line, color, selectable);
}

Widget _listRow(String mark, String text, Color color, bool selectable) {
  return Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 22,
        child: Text(
          mark,
          style: const TextStyle(
            color: Wx.muted,
            fontSize: 16,
            height: 1.55,
            fontFamilyFallback: Wx.fontFallback,
          ),
        ),
      ),
      Expanded(child: _inline(text, color, selectable)),
    ],
  );
}

Widget _inline(
  String text,
  Color color,
  bool selectable, {
  double size = 16,
  FontWeight weight = FontWeight.w400,
}) {
  final spans = <InlineSpan>[];
  final token = RegExp(r'\*\*([^*]+)\*\*|`([^`]+)`');
  var cursor = 0;
  for (final match in token.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, match.start)));
    }
    if (match.group(1) != null) {
      spans.add(TextSpan(
        text: match.group(1),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ));
    } else {
      spans.add(TextSpan(
        text: match.group(2),
        style: const TextStyle(
          fontFamily: 'ui-monospace',
          fontFamilyFallback: ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
          backgroundColor: Color(0x221C1F24),
          fontSize: 14.5,
        ),
      ));
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor)));
  }

  final style = TextStyle(
    color: color,
    fontSize: size,
    fontWeight: weight,
    height: 1.55,
    fontFamilyFallback: Wx.fontFallback,
  );
  final rich = TextSpan(style: style, children: spans);
  if (selectable) {
    return SelectableText.rich(rich);
  }
  return Text.rich(rich);
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code);
  final String code;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Wx.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wx.hairline),
      ),
      child: SelectableText(
        code,
        style: const TextStyle(
          fontFamily: 'ui-monospace',
          fontFamilyFallback: ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
          fontSize: 13.5,
          height: 1.5,
          color: Wx.text,
        ),
      ),
    );
  }
}
