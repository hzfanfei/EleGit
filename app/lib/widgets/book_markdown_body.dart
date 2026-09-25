import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/book_markdown_assets.dart';
import '../utils/book_markdown_markup.dart';
import '../utils/text_fit.dart';

final Map<String, Uint8List> _bookImageBytes = {};

class BookMarkdownBody extends StatelessWidget {
  const BookMarkdownBody({
    super.key,
    required this.api,
    required this.bookId,
    required this.chapterFile,
    required this.data,
    required this.styleSheet,
    this.spineHref,
    this.chapterTitle,
    this.onTapLink,
    this.onConsumeTap,
    this.launchExternalLinks = true,
  });

  final WenxiangApi api;
  final String bookId;
  final String chapterFile;
  final String? spineHref;
  final String? chapterTitle;
  final String data;
  final MarkdownStyleSheet styleSheet;
  final void Function(String href, String text)? onTapLink;

  /// A tap that should not also toggle the reader chrome.
  final VoidCallback? onConsumeTap;

  /// When true (default), http(s) / mailto / tel / bare-domain links are
  /// opened in the system browser automatically. The [onTapLink] callback is
  /// still invoked for every link so callers can do their own bookkeeping
  /// (e.g. suppress the chrome-toggle gesture in the book reader).
  final bool launchExternalLinks;

  String _prepared() {
    final normalized = normalizeBookMarkdown(data);
    final title = chapterTitle?.trim() ?? '';
    if (title.isEmpty) return normalized;
    return omitLeadingChapterHeading(normalized, title);
  }

  void _showFootnote(BuildContext context, String href) {
    final encoded = href.substring('wx-footnote:'.length);
    var note = encoded;
    try {
      note = Uri.decodeComponent(encoded);
    } catch (_) {}
    note = note.trim();
    if (note.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 24),
            child: Text(
              note,
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.6),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final codeStyle = (styleSheet.code ?? const TextStyle()).copyWith(backgroundColor: null);
    return MarkdownBody(
      data: _prepared(),
      selectable: true,
      styleSheet: styleSheet,
      builders: {'pre': _WrappingCodeBlock(codeStyle)},
      onSelectionChanged: (_, selection, __) {
        if (!selection.isCollapsed) onConsumeTap?.call();
      },
      onTapLink: (text, href, title) {
        final target = (href ?? '').trim();
        if (target.isEmpty) return;
        onConsumeTap?.call();
        if (target.startsWith('wx-footnote:')) {
          _showFootnote(context, target);
          onTapLink?.call(target, text);
          return;
        }
        if (launchExternalLinks) {
          final external = bookMarkdownExternalUri(target);
          if (external != null) {
            // Fire-and-forget: this callback is sync; surface launch failures
            // via SnackBar if we have a messenger.
            () async {
              final opened = await launchUrl(
                external,
                mode: LaunchMode.externalApplication,
              );
              if (!opened && messenger != null && messenger.mounted) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text('无法打开链接：$target'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            }();
          }
        }
        // Always let the caller observe the tap — they may want to mark
        // the gesture (e.g. prevent the reader's chrome from toggling).
        onTapLink?.call(target, text);
      },
      sizedImageBuilder: (config) => _BookMarkdownImage(
        api: api,
        bookId: bookId,
        chapterFile: chapterFile,
        spineHref: spineHref,
        uri: config.uri,
        alt: config.alt ?? config.title ?? '',
        width: config.width,
        height: config.height,
        onOpen: onConsumeTap,
      ),
    );
  }
}

class _WrappingCodeBlock extends MarkdownElementBuilder {
  _WrappingCodeBlock(this.style);

  final TextStyle style;

  @override
  Widget? visitText(dynamic text, TextStyle? preferredStyle) {
    // flutter_markdown only clears the inline stack when visitText returns
    // a widget. The real block is built in visitElementAfterWithContext.
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

class _BookMarkdownImage extends StatefulWidget {
  const _BookMarkdownImage({
    required this.api,
    required this.bookId,
    required this.chapterFile,
    required this.uri,
    required this.alt,
    this.spineHref,
    this.width,
    this.height,
    this.onOpen,
  });

  final WenxiangApi api;
  final String bookId;
  final String chapterFile;
  final String? spineHref;
  final Uri uri;
  final String alt;
  final double? width;
  final double? height;
  final VoidCallback? onOpen;

  @override
  State<_BookMarkdownImage> createState() => _BookMarkdownImageState();
}

class _BookMarkdownImageState extends State<_BookMarkdownImage> {
  late Future<Uint8List?> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _BookMarkdownImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.bookId != widget.bookId ||
        oldWidget.chapterFile != widget.chapterFile ||
        oldWidget.spineHref != widget.spineHref) {
      _bytes = _load();
    }
  }

  String get _raw {
    try {
      return Uri.decodeFull(widget.uri.toString());
    } catch (_) {
      return widget.uri.toString();
    }
  }

  Future<Uint8List?> _load() async {
    final raw = _raw;
    if (raw.startsWith('data:image/') && !raw.contains('image/svg')) {
      try {
        return UriData.parse(raw).contentAsBytes();
      } catch (_) {
        return null;
      }
    }
    if (raw.startsWith('data:')) return null;

    final candidates = raw.startsWith('http://') || raw.startsWith('https://')
        ? <String>[raw]
        : bookMarkdownAssetCandidates(
            src: raw,
            chapterFile: widget.chapterFile,
            spineHref: widget.spineHref,
          );
    if (candidates.isEmpty) return null;

    final cacheKey = '${widget.bookId}::${candidates.join('|')}';
    final cached = _bookImageBytes[cacheKey];
    if (cached != null) return cached;

    try {
      final bytes = raw.startsWith('http://') || raw.startsWith('https://')
          ? await _fetchAbsolute(raw)
          : await widget.api.fetchBookAssetBytesFromCandidates(widget.bookId, candidates);
      _remember(cacheKey, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _fetchAbsolute(String url) {
    return widget.api.fetchUrlBytes(Uri.parse(url));
  }

  void _remember(String key, Uint8List bytes) {
    _bookImageBytes[key] = bytes;
    if (_bookImageBytes.length <= 80) return;
    _bookImageBytes.remove(_bookImageBytes.keys.first);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snapshot) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final maxW = constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            if (snapshot.connectionState != ConnectionState.done) {
              return _loading(maxW);
            }
            final bytes = snapshot.data;
            if (bytes == null || bytes.isEmpty) return _broken();
            return _framed(
              GestureDetector(
                onTap: () {
                  widget.onOpen?.call();
                  _zoom(context, bytes);
                },
                child: _picture(bytes, maxW),
              ),
            );
          },
        );
      },
    );
  }

  Widget _loading(double maxW) {
    final w = widget.width;
    final h = widget.height;
    if (w != null && h != null && w > 0 && h > 0) {
      final dw = w > maxW ? maxW : w;
      final dh = h * (dw / w);
      return SizedBox(
        width: dw,
        height: dh,
        child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return const SizedBox(
      width: 36,
      height: 36,
      child: Padding(
        padding: EdgeInsets.all(8),
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _picture(Uint8List bytes, double maxW) {
    final attrW = widget.width;
    final attrH = widget.height;
    double? width;
    double? height;
    if (attrW != null && attrW > 0) {
      width = attrW > maxW ? maxW : attrW;
      if (attrH != null && attrH > 0) height = attrH * (width / attrW);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW),
        child: Image.memory(
          bytes,
          width: width,
          height: height,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _broken(),
        ),
      ),
    );
  }

  void _zoom(BuildContext context, Uint8List bytes) {
    showDialog<void>(
      context: context,
      barrierColor: const Color(0xE6000000),
      builder: (context) {
        return SafeArea(
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Image.memory(bytes, fit: BoxFit.contain),
                ),
              ),
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _framed(Widget child) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: child,
      ),
    );
  }

  Widget _broken() {
    final hint = widget.alt.trim();
    final showHint = hint.isNotEmpty && hint != '{%}' && !hint.startsWith('{');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Wx.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Wx.hairline),
      ),
      child: Text(
        showHint ? hint : '图片加载失败',
        style: const TextStyle(color: Wx.faint, fontSize: 13),
      ),
    );
  }
}
