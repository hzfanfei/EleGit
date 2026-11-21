import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/markdown_syntax.dart';
import '../utils/task_completion.dart';
import '../utils/text_fit.dart';
import '../utils/wx_markdown_styles.dart';
import '../utils/wx_mermaid_fence.dart';
import 'wx_answer_block.dart';
import 'wx_rich_text.dart';

export '../utils/wx_markdown_styles.dart'
    show WxMarkdownStyle, chatMarkdownStyle;

/// Splits visible Markdown into complete blocks and a tail that can still
/// change. For raw streams, keep blocks before a confirmed paragraph boundary
/// so later chunks only run the source preparation on the remaining text.
class ChatMarkdownBlockParser {
  ChatMarkdownBlockParser();

  static final _detailsOpen =
      RegExp(r'^<details(?: open)?>', caseSensitive: false);
  final List<String> completed = <String>[];
  String pending = '';
  bool taskCompleted = false;
  String _previousSource = '';
  int _settledOffset = 0;
  int _settledBlocks = 0;
  bool _settledTaskCompleted = false;

  @visibleForTesting
  int get settledSourceLength => _settledOffset;

  /// Replace the current parse with already prepared Markdown.
  void update(String visible) {
    _reset();
    _parse(visible);
  }

  void updateSource(String source) {
    if (!source.startsWith(_previousSource)) _reset();
    _previousSource = source;
    completed.removeRange(_settledBlocks, completed.length);

    TaskCompletionText? tail;
    final boundary = _lastParagraphBoundary(source, _settledOffset);
    if (boundary > _settledOffset) {
      final candidateTail = _prepare(source.substring(boundary));
      if (candidateTail.text.isNotEmpty) {
        final prefix = _prepare(
          source.substring(_settledOffset, boundary),
          fromStart: _settledOffset == 0,
          preserveEnd: true,
        );
        _parse(prefix.text);
        if (pending.isEmpty && completed.length > _settledBlocks) {
          _settledOffset = boundary;
          _settledBlocks = completed.length;
          _settledTaskCompleted |= prefix.completed;
          tail = candidateTail;
        } else {
          // A table can continue across an empty line.
          completed.removeRange(_settledBlocks, completed.length);
        }
      }
    }
    tail ??= _prepare(
      source.substring(_settledOffset),
      fromStart: _settledOffset == 0,
    );
    if (tail.text.isEmpty && _settledOffset != 0) {
      // A partial task marker may be the only text after the boundary.
      _reset();
      _previousSource = source;
      tail = _prepare(source, fromStart: true);
    }
    _parse(tail.text);
    taskCompleted = _settledTaskCompleted || tail.completed;
  }

  void _reset() {
    completed.clear();
    pending = '';
    taskCompleted = false;
    _previousSource = '';
    _settledOffset = 0;
    _settledBlocks = 0;
    _settledTaskCompleted = false;
  }

  static TaskCompletionText _prepare(
    String raw, {
    bool fromStart = false,
    bool preserveEnd = false,
  }) {
    final normalized = raw.contains('\r')
        ? raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n')
        : raw;
    final completion = parseTaskCompletion(normalized, trim: false);
    var text = completion.text;
    if (fromStart) text = text.trimLeft();
    if (!preserveEnd) text = text.trimRight();
    return TaskCompletionText(
      separateChatParagraphs(
        normalizeChatMarkdownTables(restoreFlattenedMermaidFences(text)),
      ),
      completion.completed,
    );
  }

  static int _lastParagraphBoundary(String source, int start) {
    if (source.indexOf('\n\n', start) == -1 &&
        source.indexOf('\n\r\n', start) == -1) {
      return start;
    }
    final literals = MarkdownLiteralScanner();
    var inDetails = false;
    var blankEnd = start;
    var boundary = start;
    var cursor = start;
    while (cursor < source.length) {
      final newline = source.indexOf('\n', cursor);
      final end = newline == -1 ? source.length : newline;
      final line = source.substring(cursor, end);
      final trimmed = line.trim();
      if (trimmed.isNotEmpty) boundary = blankEnd;
      if (!literals.consume(line)) {
        if (inDetails || _detailsOpen.hasMatch(trimmed)) {
          inDetails = !_endsDetails(trimmed);
        } else if (newline != -1 && (line.isEmpty || line == '\r')) {
          blankEnd = newline + 1;
        }
      }
      if (newline == -1) break;
      cursor = newline + 1;
    }
    return boundary;
  }

  static bool _endsDetails(String line) =>
      line.trimRight().toLowerCase().endsWith('</details>');

  void _parse(String visible) {
    final buf = StringBuffer();
    final literals = MarkdownLiteralScanner();
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

      final continuingLiteral = literals.isOpen;
      final literal = literals.consume(line);
      if (inDetails || (!literal && _detailsOpen.hasMatch(line.trimLeft()))) {
        if (!inDetails && buf.isNotEmpty) completeBlock();
        buf.writeln(line);
        inDetails = literal || !_endsDetails(line);
        if (!inDetails) completeBlock();
      } else if (literal) {
        if (!continuingLiteral && buf.isNotEmpty) completeBlock();
        buf.writeln(line);
        if (!literals.isOpen) completeBlock();
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
  }
}

/// Renders a Markdown string that is being typed in incrementally.
///
/// Completed blocks (terminated by a blank line or a closing code fence) are
/// rendered with stable position keys, including repeated paragraphs. The
/// trailing block can show a caret while keeping structured content readable.
class WxChatMarkdownStream extends StatefulWidget {
  const WxChatMarkdownStream({
    super.key,
    required this.source,
    required this.mdStyle,
    this.api,
    this.showCaret = false,
    this.streaming = false,
    this.taskCompleted = false,
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

  /// Open presentation blocks show a receiving state while streaming.
  final bool streaming;
  final bool taskCompleted;

  /// Optional callback for link taps (e.g. open in browser).
  final void Function(String href, String text)? onTapLink;

  @override
  State<WxChatMarkdownStream> createState() => _WxChatMarkdownStreamState();
}

class _WxChatMarkdownStreamState extends State<WxChatMarkdownStream> {
  static final _listStart = RegExp(r'^\s*(?:[-*+] |\d+\. )');
  final ChatMarkdownBlockParser _parser = ChatMarkdownBlockParser();
  final _completedViews = <({String source, Widget view})>[];
  ({String source, int index, Widget view})? _pendingView;
  String _lastSource = '';
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
      _pendingView = null;
    }
    if (oldWidget.showCaret != widget.showCaret ||
        oldWidget.streaming != widget.streaming) {
      _pendingView = null;
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
    setState(() => _parser.updateSource(raw));
  }

  void _openLink(String href, String text) =>
      widget.onTapLink?.call(href, text);

  Widget _block(int index, String source, {bool pending = false}) {
    final plain = pending &&
        widget.showCaret &&
        !source.contains('``') &&
        !source.trimLeft().startsWith('~~~') &&
        !source.contains(r'\[') &&
        !source.contains(r'\(') &&
        !source.contains(r'$$') &&
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
              streaming: pending && widget.streaming,
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
    if (pending.isEmpty) {
      _pendingView = null;
    } else if (_pendingView?.source != pending ||
        _pendingView?.index != completed.length) {
      _pendingView = (
        source: pending,
        index: completed.length,
        view: _block(completed.length, pending, pending: true),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_parser.taskCompleted || widget.taskCompleted)
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child:
                Text('✓ 任务已完成', style: TextStyle(color: Wx.ok, fontSize: 12)),
          ),
        for (final block in _completedViews) block.view,
        if (_pendingView case final pending?) pending.view,
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
