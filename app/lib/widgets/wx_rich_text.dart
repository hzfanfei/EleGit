import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

enum RichKind { prose, code }

class RichBlock {
  const RichBlock(this.kind, this.text, {this.language = ''});
  final RichKind kind;
  final String text;
  final String language;
}

class WxTableData {
  const WxTableData({required this.headers, required this.rows});
  final List<String> headers;
  final List<List<String>> rows;
}

final _fence = RegExp(r'```([^\n]*)\n([\s\S]*?)```');
final _openFence = RegExp(r'```([^\n]*)(?:\n|$)');
final _heading = RegExp(r'^(#{1,3})\s+(.*)$');
final _bullet = RegExp(r'^[-*]\s+(.*)$');
final _ordered = RegExp(r'^(\d+)\.\s+(.*)$');
final _sepCell = RegExp(r'^:?-+:?$');

String _fenceLanguage(String raw) {
  final token = raw.trim().split(RegExp(r'\s+')).firstWhere(
        (part) => part.isNotEmpty,
        orElse: () => '',
      );
  return token;
}

List<RichBlock> splitRichBlocks(String src) {
  if (src.isEmpty) return const [];
  final parts = <RichBlock>[];
  var cursor = 0;
  for (final match in _fence.allMatches(src)) {
    if (match.start > cursor) {
      parts.add(RichBlock(RichKind.prose, src.substring(cursor, match.start)));
    }
    parts.add(RichBlock(
      RichKind.code,
      (match.group(2) ?? '').trimRight(),
      language: _fenceLanguage(match.group(1) ?? ''),
    ));
    cursor = match.end;
  }
  if (cursor < src.length) {
    final rest = src.substring(cursor);
    final opened = _openFence.firstMatch(rest);
    if (opened != null) {
      if (opened.start > 0) {
        parts.add(RichBlock(RichKind.prose, rest.substring(0, opened.start)));
      }
      parts.add(RichBlock(
        RichKind.code,
        rest.substring(opened.end),
        language: _fenceLanguage(opened.group(1) ?? ''),
      ));
    } else {
      parts.add(RichBlock(RichKind.prose, rest));
    }
  }
  return parts.where((p) => p.kind == RichKind.code || p.text.trim().isNotEmpty).toList();
}

List<String>? markdownTableCells(String line) {
  var text = line.trim();
  if (!text.contains('|')) return null;
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|')) text = text.substring(0, text.length - 1);
  final cells = text.split('|').map((cell) => cell.trim()).toList();
  if (cells.isEmpty) return null;
  return cells;
}

bool _isSeparatorCell(String cell) {
  return _sepCell.hasMatch(cell.replaceAll(' ', ''));
}

bool _isSeparatorRow(List<String> cells) {
  return cells.isNotEmpty && cells.every(_isSeparatorCell);
}

bool isMarkdownTableLine(String line) {
  final cells = markdownTableCells(line);
  if (cells == null) return false;
  return cells.length >= 2 || _isSeparatorRow(cells);
}

WxTableData? parseMarkdownTable(String src) {
  final collected = <List<String>>[];
  for (final line in src.split('\n')) {
    if (line.trim().isEmpty) continue;
    final cells = markdownTableCells(line);
    if (cells == null) continue;
    if (_isSeparatorRow(cells)) continue;
    collected.add(cells);
  }
  if (collected.isEmpty) return null;
  final width = collected.fold<int>(0, (max, row) => row.length > max ? row.length : max);
  List<String> pad(List<String> row) {
    if (row.length >= width) return row.sublist(0, width);
    return [...row, ...List<String>.filled(width - row.length, '')];
  }

  return WxTableData(
    headers: pad(collected.first),
    rows: collected.skip(1).map(pad).toList(),
  );
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
            _CodeBlock(blocks[i].text, language: blocks[i].language)
          else
            _prose(blocks[i].text, color, selectable),
        ],
      ],
    );
  }
}

bool _hasStructure(String text) {
  return text.split('\n').any((line) {
    final trimmed = line.trim();
    return _heading.hasMatch(trimmed) ||
        _bullet.hasMatch(trimmed) ||
        _ordered.hasMatch(trimmed) ||
        isMarkdownTableLine(trimmed);
  });
}

Widget _prose(String text, Color color, bool selectable) {
  if (!_hasStructure(text)) {
    return _inline(text, color, selectable);
  }
  final lines = text.split('\n');
  final children = <Widget>[];
  var gap = false;
  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    if (line.trim().isEmpty) {
      gap = children.isNotEmpty;
      index += 1;
      continue;
    }
    if (isMarkdownTableLine(line)) {
      final rows = <String>[line];
      index += 1;
      while (index < lines.length && isMarkdownTableLine(lines[index])) {
        rows.add(lines[index]);
        index += 1;
      }
      if (children.isNotEmpty) {
        children.add(SizedBox(height: gap ? 12 : 8));
      }
      children.add(_MarkdownTable(rows.join('\n'), selectable: selectable));
      gap = false;
      continue;
    }
    if (children.isNotEmpty) {
      children.add(SizedBox(height: gap ? 10 : 6));
    }
    children.add(_structuredLine(line, color, selectable));
    gap = false;
    index += 1;
  }
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: children,
  );
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

const _mono = TextStyle(
  fontFamily: 'ui-monospace',
  fontFamilyFallback: ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
  fontSize: 13.5,
  height: 1.55,
  color: Wx.text,
);

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code, {this.language = ''});
  final String code;
  final String language;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(milliseconds: 1200)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Wx.raised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Wx.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 2, 0),
            child: Row(
              children: [
                if (language.isNotEmpty)
                  Text(
                    language,
                    style: const TextStyle(
                      color: Wx.accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.35,
                      fontFamilyFallback: Wx.fontFallback,
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: '复制',
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy_outlined, size: 16, color: Wx.muted),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              ],
            ),
          ),
          const ColoredBox(
            color: Wx.hairline,
            child: SizedBox(height: 1),
          ),
          SingleChildScrollView(
            key: const Key('wx-code-scroll'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: SelectableText(
              code.isEmpty ? ' ' : code,
              style: _mono,
            ),
          ),
        ],
      ),
    );
  }
}

class _MarkdownTable extends StatelessWidget {
  const _MarkdownTable(this.src, {required this.selectable});
  final String src;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final table = parseMarkdownTable(src);
    if (table == null) {
      return _inline(src, Wx.text, selectable);
    }

    Widget cell(String text, {required bool header}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: _inline(
          text,
          header ? Wx.text : const Color(0xFFD8D4CC),
          selectable,
          size: 13.5,
          weight: header ? FontWeight.w600 : FontWeight.w400,
        ),
      );
    }

    return SingleChildScrollView(
      key: const Key('wx-table-scroll'),
      scrollDirection: Axis.horizontal,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Wx.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Wx.hairline),
        ),
        child: Table(
          key: const Key('wx-md-table'),
          defaultColumnWidth: const IntrinsicColumnWidth(),
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: const TableBorder(
            horizontalInside: BorderSide(color: Wx.hairline),
            verticalInside: BorderSide(color: Wx.hairline),
          ),
          children: [
            TableRow(
              decoration: const BoxDecoration(
                color: Wx.raised,
                border: Border(
                  bottom: BorderSide(color: Wx.accent, width: 1.2),
                ),
              ),
              children: [
                for (final header in table.headers) cell(header, header: true),
              ],
            ),
            for (var row = 0; row < table.rows.length; row++)
              TableRow(
                decoration: BoxDecoration(
                  color: row.isOdd ? const Color(0x121C1F24) : Colors.transparent,
                ),
                children: [
                  for (final value in table.rows[row]) cell(value, header: false),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
