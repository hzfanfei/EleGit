import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../utils/text_fit.dart';

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
final _task = RegExp(r'^[-*]\s+\[([ xX])\]\s+(.*)$');
final _bullet = RegExp(r'^[-*]\s+(.*)$');
final _orderedTask = RegExp(r'^(\d+)\.\s+\[([ xX])\]\s+(.*)$');
final _ordered = RegExp(r'^(\d+)\.\s+(.*)$');
final _quote = RegExp(r'^>\s?(.*)$');
final _rule = RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$');
final _sepCell = RegExp(r'^:?-+:?$');
final _inlineToken = RegExp(
  r'\*\*([^*]+)\*\*'
  r'|\[([^\]\n]+)\]\(([^)\s]+)\)'
  r'|`([^`]+)`'
  r'|\*([^*\n]+)\*'
  r'|(?<![A-Za-z0-9_])_([^_\n]+)_(?![A-Za-z0-9_])',
);

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

/// Headings, lists, quotes, rules, or pipe tables — use structured renderers.
bool looksLikeStructuredMarkdown(String text) {
  return text.split('\n').any((line) {
    final trimmed = line.trim();
    return _heading.hasMatch(trimmed) ||
        _bullet.hasMatch(trimmed) ||
        _ordered.hasMatch(trimmed) ||
        _quote.hasMatch(trimmed) ||
        _rule.hasMatch(trimmed) ||
        isMarkdownTableLine(trimmed);
  });
}

enum ChatMdSegmentKind { markdown, table }

class ChatMdSegment {
  const ChatMdSegment(this.kind, this.text);
  final ChatMdSegmentKind kind;
  final String text;
}

/// Splits one chat markdown block into prose [MarkdownBody] segments and tables.
List<ChatMdSegment> splitChatMarkdownSegments(String text) {
  if (text.trim().isEmpty) return const [];
  final lines = text.split('\n');
  final out = <ChatMdSegment>[];
  final buf = StringBuffer();
  ChatMdSegmentKind? mode;

  void flush() {
    if (buf.isEmpty || mode == null) return;
    final chunk = buf.toString().trimRight();
    if (chunk.isNotEmpty) out.add(ChatMdSegment(mode!, chunk));
    buf.clear();
    mode = null;
  }

  var index = 0;
  while (index < lines.length) {
    final line = lines[index];
    if (line.trim().isEmpty) {
      if (mode == ChatMdSegmentKind.markdown) buf.write('\n');
      index += 1;
      continue;
    }
    final tableLine = isMarkdownTableLine(line);
    final kind = tableLine ? ChatMdSegmentKind.table : ChatMdSegmentKind.markdown;
    if (mode == null) {
      mode = kind;
    } else if (mode != kind) {
      flush();
      mode = kind;
    }
    buf.write(line);
    buf.write('\n');
    index += 1;
  }
  flush();
  return out;
}

Widget _prose(String text, Color color, bool selectable) {
  if (!looksLikeStructuredMarkdown(text)) {
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
      children.add(WxMarkdownTable(rows.join('\n'), selectable: selectable));
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
  final indent = line.length - line.trimLeft().length;
  final level = (indent ~/ 2).clamp(0, 8);
  final trimmed = line.trimLeft();
  if (_rule.hasMatch(trimmed)) return const WxMarkdownRule();
  final heading = _heading.firstMatch(trimmed);
  if (heading != null) {
    final depth = heading.group(1)!.length;
    final size = depth == 1 ? 20.0 : depth == 2 ? 18.0 : 16.0;
    return _pad(
      level,
      _inline(
        heading.group(2) ?? '',
        color,
        selectable,
        size: size,
        weight: FontWeight.w600,
      ),
    );
  }
  final task = _task.firstMatch(trimmed);
  if (task != null) {
    return _taskRow(
      task.group(1)!.trim().isNotEmpty,
      task.group(2) ?? '',
      color,
      selectable,
      level,
    );
  }
  final orderedTask = _orderedTask.firstMatch(trimmed);
  if (orderedTask != null) {
    return _taskRow(
      orderedTask.group(2)!.trim().isNotEmpty,
      orderedTask.group(3) ?? '',
      color,
      selectable,
      level,
    );
  }
  final bullet = _bullet.firstMatch(trimmed);
  if (bullet != null) {
    return _listRow(level == 0 ? '•' : '◦', bullet.group(1) ?? '', color, selectable, level);
  }
  final ordered = _ordered.firstMatch(trimmed);
  if (ordered != null) {
    return _listRow('${ordered.group(1)}.', ordered.group(2) ?? '', color, selectable, level);
  }
  final quote = _quote.firstMatch(trimmed);
  if (quote != null) {
    return _pad(
      level,
      DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: Wx.accent.withValues(alpha: 0.55), width: 2),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: _inline(quote.group(1) ?? '', Wx.muted, selectable),
        ),
      ),
    );
  }
  if (trimmed.isEmpty) return const SizedBox(height: 4);
  return _pad(level, _inline(line, color, selectable));
}

Widget _pad(int level, Widget child) {
  if (level <= 0) return child;
  return Padding(padding: EdgeInsets.only(left: level * 14), child: child);
}

Widget _taskRow(bool checked, String text, Color color, bool selectable, int level) {
  return _pad(
    level,
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WxTaskBox(checked: checked),
        const SizedBox(width: 6),
        Expanded(child: _inline(text, color, selectable)),
      ],
    ),
  );
}

Widget _listRow(String mark, String text, Color color, bool selectable, int level) {
  return _pad(
    level,
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(
            mark,
            style: TextStyle(
              color: level == 0 ? Wx.muted : Wx.faint,
              fontSize: level == 0 ? 15 : 13,
              height: 1.55,
              fontFamilyFallback: Wx.fontFallback,
            ),
          ),
        ),
        Expanded(child: _inline(text, color, selectable)),
      ],
    ),
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
  var cursor = 0;
  for (final match in _inlineToken.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: breakLongRuns(text.substring(cursor, match.start))));
    }
    if (match.group(1) != null) {
      spans.add(TextSpan(
        text: breakLongRuns(match.group(1)!),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ));
    } else if (match.group(2) != null) {
      spans.add(TextSpan(
        text: breakLongRuns(match.group(2)!),
        style: TextStyle(
          color: Wx.accent,
          decoration: TextDecoration.underline,
          decorationColor: Wx.accent.withValues(alpha: 0.45),
        ),
      ));
    } else if (match.group(4) != null) {
      spans.add(TextSpan(
        text: breakLongRuns(match.group(4)!),
        style: const TextStyle(
          fontFamily: 'ui-monospace',
          fontFamilyFallback: ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
          backgroundColor: Color(0x1F3E362F),
          fontSize: 14.5,
        ),
      ));
    } else {
      final italic = match.group(5) ?? match.group(6) ?? '';
      spans.add(TextSpan(
        text: breakLongRuns(italic),
        style: const TextStyle(fontStyle: FontStyle.italic),
      ));
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: breakLongRuns(text.substring(cursor))));
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

final _codeToken = RegExp([
  r'"""[\s\S]*?"""',
  r"'''[\s\S]*?'''",
  r'"(?:\\.|[^"\\])*"',
  r"'(?:\\.|[^'\\])*'",
  r'//[^\n]*',
  r'/\*[\s\S]*?\*/',
  r'\b\d+(?:\.\d+)?\b',
  r'\b(?:if|else|elif|return|class|import|const|final|var|let|function|def|true|false|null|void|for|while|switch|case|new|this|async|await|extends|implements|static|package|fn|pub|yield|break|continue|try|catch|throw)\b',
].join('|'));

/// Quiet highlighting: comments faint, strings ochre, numbers muted, keywords heavier.
TextSpan wxHighlightedCode(String code, {TextStyle base = _mono}) {
  if (code.isEmpty) return TextSpan(text: ' ', style: base);
  final spans = <InlineSpan>[];
  var cursor = 0;
  for (final match in _codeToken.allMatches(code)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: breakLongRuns(code.substring(cursor, match.start))));
    }
    final token = match.group(0)!;
    spans.add(TextSpan(text: breakLongRuns(token), style: _codeTokenStyle(token, base)));
    cursor = match.end;
  }
  if (cursor < code.length) {
    spans.add(TextSpan(text: breakLongRuns(code.substring(cursor))));
  }
  return TextSpan(style: base, children: spans);
}

TextStyle _codeTokenStyle(String token, TextStyle base) {
  if (token.startsWith('"') || token.startsWith("'")) {
    return base.copyWith(color: Wx.accent);
  }
  if (token.startsWith('//') || token.startsWith('/*')) {
    return base.copyWith(color: Wx.faint);
  }
  if (RegExp(r'^\d').hasMatch(token)) {
    return base.copyWith(color: Wx.muted);
  }
  return base.copyWith(fontWeight: FontWeight.w600);
}

/// Prose tail while a chat block is still streaming. Complete tokens only.
class WxInlineMarkdown extends StatelessWidget {
  const WxInlineMarkdown(
    this.text, {
    super.key,
    this.color = Wx.text,
    this.size = 16,
    this.selectable = true,
  });

  final String text;
  final Color color;
  final double size;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    return _inline(text, color, selectable, size: size);
  }
}

class WxMarkdownRule extends StatelessWidget {
  const WxMarkdownRule({super.key, this.color = Wx.hairline});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: 1,
        child: ColoredBox(color: color),
      ),
    );
  }
}

class WxTaskBox extends StatelessWidget {
  const WxTaskBox({super.key, required this.checked});

  final bool checked;

  @override
  Widget build(BuildContext context) {
    final ink = checked ? Wx.accent : Wx.muted;
    return Padding(
      padding: const EdgeInsets.only(top: 4, right: 2),
      child: SizedBox(
        width: 14,
        height: 14,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: ink),
            color: checked ? Wx.accent.withValues(alpha: 0.18) : const Color(0x00000000),
          ),
          child: checked
              ? const Center(child: Icon(Icons.check, size: 10, color: Wx.accent))
              : null,
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock(this.code, {this.language = ''});
  final String code;
  final String language;

  @override
  Widget build(BuildContext context) {
    return WxFencedCode(code: code, language: language);
  }
}

class WxFencedCode extends StatelessWidget {
  const WxFencedCode({
    super.key,
    required this.code,
    this.language = '',
    this.framed = true,
    this.style = _mono,
    this.blockKey = const Key('wx-code-block'),
  });

  final String code;
  final String language;
  final bool framed;
  final TextStyle style;
  final Key blockKey;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(milliseconds: 1200)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
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
                    color: Wx.muted,
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
        Padding(
          key: blockKey,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: SelectableText.rich(wxHighlightedCode(code, base: style)),
        ),
      ],
    );
    if (!framed) return body;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Wx.raised,
        borderRadius: BorderRadius.circular(Wx.radius),
        border: Border.all(color: Wx.hairline),
      ),
      child: body,
    );
  }
}

@immutable
class WxMarkdownTableTheme {
  const WxMarkdownTableTheme({
    required this.frameFill,
    required this.headerFill,
    required this.borderColor,
    required this.headerInk,
    required this.bodyInk,
    required this.zebraFill,
    required this.headerUnderline,
    this.cellFontSize = 13.5,
    this.borderRadius = 10,
  });

  final Color frameFill;
  final Color headerFill;
  final Color borderColor;
  final Color headerInk;
  final Color bodyInk;
  final Color zebraFill;
  final Color headerUnderline;
  final double cellFontSize;
  final double borderRadius;

  /// Default for chat, repo cards, and [WxReadableText].
  static const chat = WxMarkdownTableTheme(
    frameFill: Wx.surface,
    headerFill: Wx.raised,
    borderColor: Wx.hairline,
    headerInk: Wx.text,
    bodyInk: Color(0xFFD8D4CC),
    zebraFill: Color(0x121C1F24),
    headerUnderline: Wx.accent,
  );
}

class WxMarkdownTable extends StatelessWidget {
  const WxMarkdownTable(
    this.src, {
    required this.selectable,
    this.theme = WxMarkdownTableTheme.chat,
    super.key,
  });

  final String src;
  final bool selectable;
  final WxMarkdownTableTheme theme;

  @override
  Widget build(BuildContext context) {
    final table = parseMarkdownTable(src);
    final t = theme;
    if (table == null) {
      return _inline(src, t.headerInk, selectable);
    }

    Widget cell(String text, {required bool header}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: _inline(
          text,
          header ? t.headerInk : t.bodyInk,
          selectable,
          size: t.cellFontSize,
          weight: header ? FontWeight.w600 : FontWeight.w400,
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite && constraints.maxWidth > 0
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final count = table.headers.length;
        final columns = _tableColumnWidths(table, count);
        final natural = columns.fold<double>(0, (sum, column) => sum + column);
        final scroll = natural > width + 0.5;
        final extra = scroll || count == 0 ? 0.0 : (width - natural) / count;
        final framed = DecoratedBox(
            decoration: BoxDecoration(
              color: t.frameFill,
              borderRadius: BorderRadius.circular(t.borderRadius),
              border: Border.all(color: t.borderColor),
            ),
            child: Table(
              key: const Key('wx-md-table'),
              columnWidths: {
                for (var i = 0; i < count; i++) i: FixedColumnWidth(columns[i] + extra),
              },
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              border: TableBorder(
                horizontalInside: BorderSide(color: t.borderColor),
                verticalInside: BorderSide(color: t.borderColor),
              ),
              children: [
                TableRow(
                  decoration: BoxDecoration(
                    color: t.headerFill,
                    border: Border(
                      bottom: BorderSide(color: t.headerUnderline, width: 1.2),
                    ),
                  ),
                  children: [
                    for (final header in table.headers) cell(header, header: true),
                  ],
                ),
                for (var row = 0; row < table.rows.length; row++)
                  TableRow(
                    decoration: BoxDecoration(
                      color: row.isOdd ? t.zebraFill : Colors.transparent,
                    ),
                    children: [
                      for (final value in table.rows[row]) cell(value, header: false),
                    ],
                  ),
              ],
            ),
        );
        if (!scroll) {
          return SizedBox(width: width, child: framed);
        }
        return SizedBox(
          width: width,
          child: SingleChildScrollView(
            key: const Key('wx-table-scroll'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(width: natural, child: framed),
          ),
        );
      },
    );
  }
}

const _tableCellPadding = 24.0;
const _tableMinColumn = 72.0;
const _tableMaxColumn = 240.0;

List<double> _tableColumnWidths(WxTableData table, int count) {
  const headerStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, fontFamilyFallback: Wx.fontFallback);
  const bodyStyle = TextStyle(fontSize: 13.5, fontWeight: FontWeight.w400, fontFamilyFallback: Wx.fontFallback);
  return [
    for (var i = 0; i < count; i++)
      _columnWidth([
        table.headers[i],
        for (final row in table.rows) i < row.length ? row[i] : '',
      ], headerStyle, bodyStyle),
  ];
}

double _columnWidth(List<String> cells, TextStyle headerStyle, TextStyle bodyStyle) {
  var widest = _tableMinColumn;
  for (var i = 0; i < cells.length; i++) {
    final measured = _singleLineWidth(cells[i], i == 0 ? headerStyle : bodyStyle) + _tableCellPadding;
    if (measured > widest) widest = measured;
  }
  if (widest > _tableMaxColumn) return _tableMaxColumn;
  return widest;
}

double _singleLineWidth(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

class WxReplyFrame extends StatelessWidget {
  const WxReplyFrame({
    super.key,
    required this.label,
    required this.child,
    this.footer,
    this.trailing,
    this.labelColor = Wx.text,
    this.railColor = Wx.hairline,
    this.railWidth = 2,
    this.bottom = 16,
    this.lead = 12,
  });

  final String label;
  final Widget child;
  final Widget? footer;
  final Widget? trailing;
  final Color labelColor;
  final Color railColor;
  final double railWidth;
  final double bottom;
  final double lead;

  @override
  Widget build(BuildContext context) {
    final ask = label == '你问';
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: CustomPaint(
        painter: _ReplyRailPainter(color: railColor, width: railWidth),
        child: Padding(
          padding: EdgeInsets.only(left: railWidth + lead),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: labelColor,
                            fontSize: ask ? 12 : 13,
                            fontWeight: FontWeight.w600,
                            letterSpacing: ask ? 0.4 : 0.8,
                          ),
                    ),
                  ),
                  if (trailing != null) trailing!,
                ],
              ),
              const SizedBox(height: 8),
              child,
              if (footer != null) ...[
                const SizedBox(height: 8),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ReplyRailPainter extends CustomPainter {
  const _ReplyRailPainter({required this.color, required this.width});

  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Rect.fromLTWH(0, 2, width, math.max(0, size.height - 2)), Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _ReplyRailPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.width != width;
  }
}
