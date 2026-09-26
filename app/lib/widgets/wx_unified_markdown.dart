import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../utils/text_fit.dart';
import 'wx_rich_text.dart';

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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SelectableText(
        breakLongRuns(code),
        style: style,
      ),
    );
  }
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
  });

  final String data;
  final MarkdownStyleSheet styleSheet;
  final void Function(String text, String? href, String? title)? onTapLink;
  final MarkdownOnSelectionChangedCallback? onSelectionChanged;
  final MarkdownSizedImageBuilder? sizedImageBuilder;
  final bool selectable;
  final bool splitTables;
  final bool softWrapProse;

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
      onSelectionChanged: onSelectionChanged,
      onTapLink: onTapLink,
      sizedImageBuilder: sizedImageBuilder,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!splitTables) {
      return _markdownChunk(data);
    }
    final segments = splitChatMarkdownSegments(data);
    if (segments.length == 1 && segments.first.kind == ChatMdSegmentKind.markdown) {
      return _markdownChunk(segments.first.text);
    }
    if (segments.isEmpty) {
      return _markdownChunk(data);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          if (segments[i].kind == ChatMdSegmentKind.table)
            WxMarkdownTable(segments[i].text, selectable: selectable)
          else
            _markdownChunk(segments[i].text),
        ],
      ],
    );
  }
}
