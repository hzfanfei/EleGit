import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../api/wenxiang_api.dart';
import '../utils/text_fit.dart';
import '../utils/task_completion.dart';
import '../utils/wx_mermaid_fence.dart';
import '../utils/wx_markdown_styles.dart';
export '../utils/wx_markdown_styles.dart'
    show WxMarkdownStyle, chatMarkdownStyle;
import 'wx_rich_text.dart';
import 'wx_answer_block.dart';

/// Splits a partial Markdown stream into "complete" blocks (ready to render
/// with [MarkdownBody]) and a "pending" tail that the user is still typing
/// into. A complete block ends at a blank line in prose, or at a closing
/// ```` ``` ```` fence line.
///
/// The parser is intentionally cheap: it scans the visible prefix once per
/// call, returning fresh lists. Callers compare against the previous result
/// to detect new blocks and animate them in.
class ChatMarkdownBlockParser {
  ChatMarkdownBlockParser();

  static final _detailsOpen =
      RegExp(r'^<details(?: open)?>', caseSensitive: false);
  static final _fenceOpen = RegExp(r'^\s*(`{3,}|~{3,})');
  final List<String> completed = <String>[];
  String pending = '';

  void update(String visible) {
    completed.clear();
    final buf = StringBuffer();
    String? fence;
    var inDetails = false;
    var tableOnly = true;

    void completeBlock() {
      completed.add(buf.toString());
      buf.clear();
      tableOnly = true;
    }

    var cursor = 0;
    while (cursor < visible.length) {
      final nl = visible.indexOf('\n', cursor);
      final lineEnd = nl == -1 ? visible.length : nl;
      var line = visible.substring(cursor, lineEnd);
      // Drop trailing \r so CRLF inputs still parse.
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

      final openFence = fence == null && !inDetails
          ? _fenceOpen.firstMatch(line)?.group(1)
          : null;
      if (inDetails ||
          (fence == null && _detailsOpen.hasMatch(line.trimLeft()))) {
        if (!inDetails && buf.isNotEmpty) completeBlock();
        buf.writeln(line);
        inDetails = !line.trimRight().toLowerCase().endsWith('</details>');
        if (!inDetails) completeBlock();
      } else if (fence != null) {
        buf.writeln(line);
        if (_isFenceClose(line, fence)) {
          completeBlock();
          fence = null;
        }
      } else if (openFence != null) {
        if (buf.isNotEmpty) completeBlock();
        buf.writeln(line);
        fence = openFence;
      } else if (line.trim().isEmpty) {
        if (buf.isNotEmpty && !tableOnly) completeBlock();
      } else {
        final tableLine = isMarkdownTableLine(line);
        if (buf.isNotEmpty && tableOnly && !tableLine) completeBlock();
        buf.writeln(line);
        tableOnly = tableOnly && tableLine;
      }

      if (nl == -1) break;
      cursor = lineEnd + 1;
    }

    pending = buf.toString();
    if (visible.contains('```')) {
      _splitCompletedByMermaid();
      _splitPendingByMermaid();
    }
  }

  void _splitCompletedByMermaid() {
    if (completed.isEmpty) return;
    final expanded = <String>[];
    for (final block in completed) {
      expanded.addAll(!block.contains('```') ||
              block.trimLeft().toLowerCase().startsWith('<details')
          ? [block]
          : expandMarkdownBlockByMermaid(block));
    }
    completed
      ..clear()
      ..addAll(expanded);
  }

  void _splitPendingByMermaid() {
    if (!pending.contains('```') ||
        pending.trimLeft().toLowerCase().startsWith('<details')) {
      return;
    }
    final segments = splitMarkdownByMermaidFences(pending);
    if (segments.length <= 1) return;
    for (var i = 0; i < segments.length - 1; i++) {
      completed.add(markdownSourceForMermaidSegment(segments[i]));
    }
    pending = markdownSourceForMermaidSegment(segments.last);
  }

  static bool _isFenceClose(String line, String fence) {
    final stripped = line.trim();
    if (!stripped.startsWith(fence)) return false;
    final marker = fence.codeUnitAt(0);
    for (var i = fence.length; i < stripped.length; i++) {
      if (stripped.codeUnitAt(i) != marker) return false;
    }
    return true;
  }
}

/// Renders a Markdown string that is being typed in incrementally.
///
/// Completed blocks (terminated by a blank line or a closing code fence) are
/// rendered with stable position keys, including repeated paragraphs. The trailing "pending"
/// block — the one the user is still typing into — is shown as plain text
/// with an optional blinking caret at its end. The whole stack is wrapped in
/// a Column without height animations to keep reading position stable.
class WxChatMarkdownStream extends StatefulWidget {
  const WxChatMarkdownStream({
    super.key,
    required this.source,
    required this.mdStyle,
    this.api,
    this.showCaret = false,
    this.onTapLink,
  });

  /// Value notifier whose value is the partial Markdown source. For live
  /// streaming, point this at [WxTypewriterStream.visible]. For finished
  /// messages, wrap the persisted string in a [ValueNotifier].
  final ValueListenable<String> source;

  final WxMarkdownStyle mdStyle;
  final WenxiangApi? api;

  /// When true, a blinking caret is appended after the pending block.
  final bool showCaret;

  /// Optional callback for link taps (e.g. open in browser).
  final void Function(String href, String text)? onTapLink;

  @override
  State<WxChatMarkdownStream> createState() => _WxChatMarkdownStreamState();
}

class _WxChatMarkdownStreamState extends State<WxChatMarkdownStream> {
  static final _listStart = RegExp(r'^\s*(?:[-*+] |\d+\. )');
  final ChatMarkdownBlockParser _parser = ChatMarkdownBlockParser();
  final _completedViews = <({String source, Widget view})>[];
  String _lastSource = '';
  bool _taskCompleted = false;
  @override
  void initState() {
    super.initState();
    widget.source.addListener(_onSourceChanged);
    _onSourceChanged();
  }

  @override
  void didUpdateWidget(covariant WxChatMarkdownStream oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mdStyle != widget.mdStyle ||
        oldWidget.api != widget.api ||
        (oldWidget.onTapLink == null) != (widget.onTapLink == null)) {
      _completedViews.clear();
    }
    if (!identical(oldWidget.source, widget.source)) {
      oldWidget.source.removeListener(_onSourceChanged);
      widget.source.addListener(_onSourceChanged);
      _onSourceChanged();
    }
  }

  @override
  void dispose() {
    widget.source.removeListener(_onSourceChanged);
    super.dispose();
  }

  void _onSourceChanged() {
    final raw = widget.source.value;
    if (raw == _lastSource) return;
    _lastSource = raw;
    final completion = parseTaskCompletion(raw);
    final stripped = separateChatParagraphs(
      normalizeChatMarkdownTables(completion.text),
    );
    _parser.update(stripped);
    setState(() => _taskCompleted = completion.completed);
  }

  void _openLink(String href, String text) =>
      widget.onTapLink?.call(href, text);

  Widget _block(int index, String source, {bool pending = false}) {
    final plain = pending &&
        widget.showCaret &&
        !looksLikeStructuredMarkdown(source) &&
        !source.trimLeft().toLowerCase().startsWith('<details');
    return Padding(
      // Keep state such as expanded details across updates to the stream.
      key: ValueKey('answer-block-$index'),
      padding: EdgeInsets.only(
        top: index == 0 ? 0 : (_listStart.hasMatch(source) ? 6 : 10),
      ),
      child: plain
          ? _PendingView(text: source)
          : WxAnswerBlock(
              source: source,
              mdStyle: widget.mdStyle,
              api: widget.api,
              onTapLink: widget.onTapLink == null ? null : _openLink,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final completed = _parser.completed;
    if (_completedViews.length > completed.length) {
      _completedViews.removeRange(completed.length, _completedViews.length);
    }
    for (var i = 0; i < completed.length; i++) {
      final source = completed[i];
      if (i == _completedViews.length) {
        _completedViews.add((source: source, view: _block(i, source)));
      } else if (_completedViews[i].source != source) {
        _completedViews[i] = (source: source, view: _block(i, source));
      }
    }
    final pending = _parser.pending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_taskCompleted)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child:
                Text('✓ 任务已完成', style: TextStyle(color: Wx.ok, fontSize: 12)),
          ),
        for (final block in _completedViews) block.view,
        if (pending.isNotEmpty)
          _block(completed.length, pending, pending: true),
        if (widget.showCaret && pending.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child:
                Align(alignment: Alignment.centerLeft, child: _BlinkingCaret()),
          ),
      ],
    );
  }
}

class _PendingView extends StatelessWidget {
  const _PendingView({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Wx.text,
          height: 1.55,
          fontFamilyFallback: Wx.fontFallback,
        );
    return WxInlineMarkdown(
      prepareChatMarkdownForDisplay(text, isTableLine: isMarkdownTableLine),
      color: style?.color ?? Wx.text,
      size: style?.fontSize ?? 16,
    );
  }
}

/// Reusable blinking caret used by chat reply streams. Same look as the
/// inline `_Caret` previously embedded in `chat_page.dart`.
class _BlinkingCaret extends StatefulWidget {
  const _BlinkingCaret();

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: Wx.breath,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        key: const Key('wx-stream-caret'),
        width: 2,
        height: 15,
        decoration: BoxDecoration(
          color: Wx.accent,
          borderRadius: BorderRadius.circular(1),
        ),
      ),
    );
  }
}
