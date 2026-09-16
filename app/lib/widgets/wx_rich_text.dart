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
    parts.add(RichBlock(RichKind.prose, src.substring(cursor)));
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

Widget _prose(String text, Color color, bool selectable) {
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
    fontSize: 16,
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
