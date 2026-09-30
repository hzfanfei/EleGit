import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../utils/wx_mermaid_fence.dart';
import '../utils/wx_markdown_styles.dart';
import 'wx_mermaid_block.dart';
export '../utils/wx_markdown_styles.dart' show WxMarkdownStyle, chatMarkdownStyle;
import 'wx_rich_text.dart';
import 'wx_unified_markdown.dart';

final _taskMarkerRe = RegExp(r'^===TASK_COMPLETED===\s*', multiLine: true);

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
    var inFence = false;
    var fenceStartPending = false;

    var cursor = 0;
    while (cursor < visible.length) {
      var nl = visible.indexOf('\n', cursor);
      final lineEnd = nl == -1 ? visible.length : nl;
      var line = visible.substring(cursor, lineEnd);
      // Drop trailing \r so CRLF inputs still parse.
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);

      if (inFence) {
        buf.write(line);
        buf.write('\n');
        if (_isFenceClose(line)) {
          completed.add(buf.toString());
          buf.clear();
          inFence = false;
        }
      } else if (fenceStartPending) {
        // We already accepted the opening fence line; treat the rest of the
        // visible text as code until we see a close line.
        inFence = true;
        fenceStartPending = false;
        buf.write(line);
        buf.write('\n');
        if (_isFenceClose(line)) {
          completed.add(buf.toString());
          buf.clear();
          inFence = false;
        }
      } else if (_isFenceOpen(line)) {
        if (buf.isNotEmpty) {
          completed.add(buf.toString());
          buf.clear();
        }
        buf.write(line);
        buf.write('\n');
        // If the visible text ends on the opening line, we don't yet know
        // whether the fence will be closed; stash that for the next call.
        if (nl == -1) {
          fenceStartPending = true;
        } else {
          inFence = true;
        }
      } else if (line.trim().isEmpty) {
        if (buf.isNotEmpty && !_bufferIsTableOnly(buf.toString())) {
          completed.add(buf.toString());
          buf.clear();
        }
      } else {
        final tableLine = isMarkdownTableLine(line);
        if (buf.isNotEmpty && !tableLine && _bufferIsTableOnly(buf.toString())) {
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
  }

  static bool _isFenceOpen(String line) {
    if (!line.startsWith('```')) return false;
    // At least 3 backticks, optionally preceded by up to 3 spaces of indent.
    final stripped = line.trimLeft();
    if (!stripped.startsWith('```')) return false;
    // Anything after the backticks on this line is the language hint.
    return true;
  }

  static bool _isFenceClose(String line) {
    final stripped = line.trimLeft();
    return stripped.startsWith('```') && stripped.replaceAll('`', '').trim().isEmpty;
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
/// rendered with [MarkdownBody] and keyed by content hash, so Flutter only
/// re-runs the parser/render for blocks that changed. The trailing "pending"
/// block — the one the user is still typing into — is shown as plain text
/// with an optional blinking caret at its end. The whole stack is wrapped in
/// [AnimatedSize] so block completion animates smoothly.
class WxChatMarkdownStream extends StatefulWidget {
  const WxChatMarkdownStream({
    super.key,
    required this.source,
    required this.mdStyle,
    this.showCaret = false,
    this.onTapLink,
  });

  /// Value notifier whose value is the partial Markdown source. For live
  /// streaming, point this at [WxTypewriterStream.visible]. For finished
  /// messages, wrap the persisted string in a [ValueNotifier].
  final ValueListenable<String> source;

  final WxMarkdownStyle mdStyle;

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
  // Hash of each completed block currently rendered, in order. We compare
  // against the new parse to know which blocks are new (eligible for fade-in)
  // vs. existing.
  List<int> _renderedHashes = const [];
  int _pendingHash = 0;
  String _pendingText = '';

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
    final stripped = _stripTaskMarker(raw);
    _parser.update(stripped);
    final newHashes = [
      for (final block in _parser.completed) block.hashCode,
    ];
    final newPendingHash = _parser.pending.hashCode;
    final pendingChanged = newPendingHash != _pendingHash ||
        _parser.pending != _pendingText;
    final completedChanged = !_listsEqual(newHashes, _renderedHashes);
    if (completedChanged || pendingChanged) {
      setState(() {
        _renderedHashes = newHashes;
        _pendingHash = newPendingHash;
        _pendingText = _parser.pending;
      });
    }
  }

  bool _listsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: Wx.motion,
      curve: Wx.motionCurve,
      alignment: Alignment.topCenter,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _parser.completed.length; i++)
            _BlockView(
              key: ValueKey(_renderedHashes[i]),
              source: _parser.completed[i],
              mdStyle: widget.mdStyle,
              onTapLink: widget.onTapLink,
              isNew: i >= _renderedHashes.length - (_renderedHashes.length - _completedCountAtLastRender()),
            ),
          if (_pendingText.isNotEmpty)
            widget.showCaret && !looksLikeStructuredMarkdown(_pendingText)
                ? _PendingView(text: _pendingText)
                : _BlockView(
                    key: ValueKey(_pendingHash),
                    source: _pendingText,
                    mdStyle: widget.mdStyle,
                    onTapLink: widget.onTapLink,
                  ),
          if (widget.showCaret && _pendingText.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _BlinkingCaret(),
              ),
            ),
        ],
      ),
    );
  }

  // Returns the count of completed blocks that were already rendered before
  // this build. Used to decide which blocks are "new" (>= this count) and
  // should fade in. We approximate by tracking how many hashes were known
  // before this parse — but since we always assign fresh hashes on each
  // parse, the simpler rule is: a block whose hash existed in the previous
  // rendered list is not new; everything else is new.
  int _completedCountAtLastRender() {
    return _renderedHashes.length; // unused, kept for clarity
  }
}

class _BlockView extends StatefulWidget {
  const _BlockView({
    super.key,
    required this.source,
    required this.mdStyle,
    this.onTapLink,
    this.isNew = false,
  });

  final String source;
  final WxMarkdownStyle mdStyle;
  final void Function(String href, String text)? onTapLink;
  final bool isNew;

  @override
  State<_BlockView> createState() => _BlockViewState();
}

class _BlockViewState extends State<_BlockView> {
  @override
  Widget build(BuildContext context) {
    final mermaidOnly = parseMermaidFenceBlock(widget.source);
    final body = mermaidOnly != null
        ? WxMermaidBlock(
            code: mermaidOnly.code,
            closed: mermaidOnly.closed,
            style: widget.mdStyle.mermaidStyle,
            shellColor: widget.mdStyle.mermaidShellColor,
            monoStyle: widget.mdStyle.body.copyWith(
              fontFamily: 'ui-monospace',
              fontSize: (widget.mdStyle.body.fontSize ?? 16) * 0.88,
              height: 1.45,
            ),
          )
        : WxUnifiedMarkdownBody(
            data: widget.source,
            mdStyle: widget.mdStyle,
            onTapLink: (text, href, title) {
              final target = (href ?? '').trim();
              if (target.isEmpty) return;
              widget.onTapLink?.call(target, text);
            },
          );
    if (!widget.isNew) return body;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Wx.motion,
      curve: Wx.motionCurve,
      child: body,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, (1 - value) * 6),
            child: child,
          ),
        );
      },
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
      text,
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

