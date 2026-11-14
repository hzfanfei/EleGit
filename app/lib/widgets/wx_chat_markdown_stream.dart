import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../api/wenxiang_api.dart';
import '../utils/text_fit.dart';
import '../utils/wx_mermaid_fence.dart';
import '../utils/wx_markdown_styles.dart';
export '../utils/wx_markdown_styles.dart'
    show WxMarkdownStyle, chatMarkdownStyle;
import 'wx_rich_text.dart';
import 'wx_answer_block.dart';

final _taskMarkerRe = RegExp(r'^\s*===TASK_COMPLETED===[ \t]*(?:\r?\n|$)');

String _stripTaskMarker(String text) {
  return text.replaceFirst(_taskMarkerRe, '').trim();
}

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

  final List<String> completed = <String>[];
  String pending = '';

  void update(String visible) {
    completed.clear();
    final buf = StringBuffer();
    String? fence;
    var inDetails = false;

    var cursor = 0;
    while (cursor < visible.length) {
      var nl = visible.indexOf('\n', cursor);
      final lineEnd = nl == -1 ? visible.length : nl;
      var line = visible.substring(cursor, lineEnd);
      // Drop trailing \r so CRLF inputs still parse.
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

      if (inDetails ||
          (fence == null &&
              RegExp(r'^<details(?: open)?>', caseSensitive: false)
                  .hasMatch(line.trim()))) {
        if (!inDetails && buf.isNotEmpty) {
          completed.add(buf.toString());
          buf.clear();
        }
        buf.writeln(line);
        inDetails = !line.trimRight().toLowerCase().endsWith('</details>');
        if (!inDetails) {
          completed.add(buf.toString());
          buf.clear();
        }
      } else if (fence != null) {
        buf.write(line);
        buf.write('\n');
        if (_isFenceClose(line, fence)) {
          completed.add(buf.toString());
          buf.clear();
          fence = null;
        }
      } else if (_fenceOpen(line) != null) {
        if (buf.isNotEmpty) {
          completed.add(buf.toString());
          buf.clear();
        }
        buf.write(line);
        buf.write('\n');
        fence = _fenceOpen(line);
      } else if (line.trim().isEmpty) {
        if (buf.isNotEmpty && !_bufferIsTableOnly(buf.toString())) {
          completed.add(buf.toString());
          buf.clear();
        }
      } else {
        final tableLine = isMarkdownTableLine(line);
        if (buf.isNotEmpty &&
            !tableLine &&
            _bufferIsTableOnly(buf.toString())) {
          completed.add(buf.toString());
          buf.clear();
        }
        buf.write(line);
        buf.write('\n');
      }

      if (nl == -1) break;
      cursor = lineEnd + 1;
    }

    pending = buf.toString();
    _splitCompletedByMermaid();
    _splitPendingByMermaid();
  }

  void _splitCompletedByMermaid() {
    if (completed.isEmpty) return;
    final expanded = <String>[];
    for (final block in completed) {
      expanded.addAll(block.trimLeft().toLowerCase().startsWith('<details')
          ? [block]
          : expandMarkdownBlockByMermaid(block));
    }
    completed
      ..clear()
      ..addAll(expanded);
  }

  void _splitPendingByMermaid() {
    if (pending.isEmpty ||
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

  static String? _fenceOpen(String line) =>
      RegExp(r'^\s*(`{3,}|~{3,})').firstMatch(line)?.group(1);

  static bool _isFenceClose(String line, String fence) {
    final stripped = line.trim();
    return stripped.length >= fence.length &&
        stripped.split('').every((char) => char == fence[0]);
  }

  static bool _bufferIsTableOnly(String text) {
    var any = false;
    for (final line in text.split('\n')) {
      if (line.trim().isEmpty) continue;
      any = true;
      if (!isMarkdownTableLine(line)) return false;
    }
    return any;
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
  final ChatMarkdownBlockParser _parser = ChatMarkdownBlockParser();
  String _lastSource = '';
  List<String> _blocks = const [];
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
    final stripped = separateChatParagraphs(
      normalizeChatMarkdownTables(_stripTaskMarker(raw)),
    );
    _parser.update(stripped);
    setState(() {
      _taskCompleted = _taskMarkerRe.hasMatch(raw);
      _blocks = [
        ..._parser.completed,
        if (_parser.pending.isNotEmpty) _parser.pending
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
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
        for (var i = 0; i < _blocks.length; i++)
          Padding(
            // Position survives appended text and the pending-to-completed transition.
            key: ValueKey('answer-block-$i'),
            padding: EdgeInsets.only(top: i == 0 ? 0 : _blockGap(_blocks[i])),
            child: widget.showCaret &&
                    i == _parser.completed.length &&
                    !looksLikeStructuredMarkdown(_blocks[i]) &&
                    !_blocks[i].trimLeft().toLowerCase().startsWith('<details')
                ? _PendingView(text: _blocks[i])
                : WxAnswerBlock(
                    source: _blocks[i],
                    mdStyle: widget.mdStyle,
                    api: widget.api,
                    onTapLink: widget.onTapLink,
                  ),
          ),
        if (widget.showCaret && _parser.pending.isNotEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child:
                Align(alignment: Alignment.centerLeft, child: _BlinkingCaret()),
          ),
      ],
    );
  }

  double _blockGap(String block) =>
      RegExp(r'^\s*(?:[-*+] |\d+\. )').hasMatch(block) ? 6 : 10;
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
