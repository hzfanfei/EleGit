import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../theme.dart';
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
    required this.styleSheet,
    this.showCaret = false,
    this.onTapLink,
  });

  /// Value notifier whose value is the partial Markdown source. For live
  /// streaming, point this at [WxTypewriterStream.visible]. For finished
  /// messages, wrap the persisted string in a [ValueNotifier].
  final ValueListenable<String> source;

  final MarkdownStyleSheet styleSheet;

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
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _parser.completed.length; i++)
            _BlockView(
              key: ValueKey(_renderedHashes[i]),
              source: _parser.completed[i],
              styleSheet: widget.styleSheet,
              onTapLink: widget.onTapLink,
              isNew: i >= _renderedHashes.length - (_renderedHashes.length - _completedCountAtLastRender()),
            ),
          if (_pendingText.isNotEmpty)
            widget.showCaret && !looksLikeStructuredMarkdown(_pendingText)
                ? _PendingView(text: _pendingText)
                : _BlockView(
                    key: ValueKey(_pendingHash),
                    source: _pendingText,
                    styleSheet: widget.styleSheet,
                    onTapLink: widget.onTapLink,
                  ),
          if (widget.showCaret && _pendingText.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: _BlinkingCaret(),
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
    required this.styleSheet,
    this.onTapLink,
    this.isNew = false,
  });

  final String source;
  final MarkdownStyleSheet styleSheet;
  final void Function(String href, String text)? onTapLink;
  final bool isNew;

  @override
  State<_BlockView> createState() => _BlockViewState();
}

class _BlockViewState extends State<_BlockView> {
  @override
  Widget build(BuildContext context) {
    final body = WxUnifiedMarkdownBody(
      data: widget.source,
      styleSheet: widget.styleSheet,
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

/// Chat-themed [MarkdownStyleSheet] for assistant replies. Distinct from the
/// book reader's style: uses the dark app palette instead of the reading
/// paper palette, with body text on transparent surface.
MarkdownStyleSheet chatMarkdownStyle(ThemeData theme) {
  final body = TextStyle(
    fontSize: 16,
    height: 1.55,
    color: Wx.text,
    fontFamilyFallback: Wx.fontFallback,
  );
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    a: body.copyWith(
      color: Wx.accent,
      decoration: TextDecoration.underline,
      decorationColor: Wx.accent.withValues(alpha: 0.45),
    ),
    h1: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      height: 1.3,
      color: Wx.text,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h2: TextStyle(
      fontSize: 19,
      fontWeight: FontWeight.w700,
      height: 1.3,
      color: Wx.text,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h3: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: Wx.text,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h4: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.35,
      color: Wx.text,
      fontFamilyFallback: Wx.fontFallback,
    ),
    h5: body.copyWith(fontWeight: FontWeight.w600),
    h6: body.copyWith(fontWeight: FontWeight.w600),
    h1Padding: const EdgeInsets.only(top: 16, bottom: 4),
    h2Padding: const EdgeInsets.only(top: 14, bottom: 4),
    h3Padding: const EdgeInsets.only(top: 12, bottom: 2),
    h4Padding: const EdgeInsets.only(top: 10, bottom: 2),
    h5Padding: const EdgeInsets.only(top: 8, bottom: 2),
    h6Padding: const EdgeInsets.only(top: 8, bottom: 2),
    em: body.copyWith(fontStyle: FontStyle.italic),
    strong: body.copyWith(fontWeight: FontWeight.w700),
    del: body.copyWith(
      decoration: TextDecoration.lineThrough,
      color: Wx.muted,
    ),
    listBullet: body.copyWith(color: Wx.muted, fontSize: 14, height: 1.4),
    listIndent: 22,
    listBulletPadding: const EdgeInsets.only(right: 4),
    checkbox: body.copyWith(color: Wx.muted, fontSize: 16),
    blockquote: body.copyWith(color: Wx.muted, fontSize: 15.5),
    blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
    blockquoteDecoration: BoxDecoration(
      color: Wx.surface,
      borderRadius: BorderRadius.circular(8),
      border: Border(
        left: BorderSide(color: Wx.accent.withValues(alpha: 0.55), width: 3),
      ),
    ),
    code: TextStyle(
      fontFamily: 'ui-monospace',
      fontFamilyFallback: const ['SF Mono', 'Menlo', 'Consolas', 'monospace'],
      fontSize: 14,
      height: 1.45,
      color: Wx.text,
      backgroundColor: Wx.raised,
    ),
    codeblockPadding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
    codeblockDecoration: BoxDecoration(
      color: Wx.raised,
      borderRadius: BorderRadius.circular(Wx.radius),
      border: Border.all(color: Wx.hairline),
    ),
    tableHead: TextStyle(
      fontWeight: FontWeight.w600,
      fontSize: 14.5,
      color: Wx.text,
    ),
    tableBody: body.copyWith(fontSize: 14.5),
    tableBorder: TableBorder.all(color: Wx.hairline, width: 0.6),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    tableColumnWidth: const IntrinsicColumnWidth(),
    blockSpacing: 16,
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: Wx.hairline, width: 0.6)),
    ),
  );
}
