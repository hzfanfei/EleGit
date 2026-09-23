import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/book_markdown_assets.dart';
import '../utils/book_markdown_markup.dart';

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
    this.onTapLink,
    this.launchExternalLinks = true,
  });

  final WenxiangApi api;
  final String bookId;
  final String chapterFile;
  final String? spineHref;
  final String data;
  final MarkdownStyleSheet styleSheet;
  final void Function(String href, String text)? onTapLink;

  /// When true (default), http(s) / mailto / tel / bare-domain links are
  /// opened in the system browser automatically. The [onTapLink] callback is
  /// still invoked for every link so callers can do their own bookkeeping
  /// (e.g. suppress the chrome-toggle gesture in the book reader).
  final bool launchExternalLinks;

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    return MarkdownBody(
      data: normalizeBookMarkdown(data),
      styleSheet: styleSheet,
      onTapLink: (text, href, title) {
        final target = (href ?? '').trim();
        if (target.isEmpty) return;
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
  });

  final WenxiangApi api;
  final String bookId;
  final String chapterFile;
  final String? spineHref;
  final Uri uri;
  final String alt;
  final double? width;
  final double? height;

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
        if (snapshot.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) return _broken();
        return _framed(
          LayoutBuilder(
            builder: (context, constraints) {
              final maxW = constraints.maxWidth.isFinite && constraints.maxWidth > 0
                  ? constraints.maxWidth
                  : MediaQuery.sizeOf(context).width;
              return Image.memory(
                bytes,
                fit: BoxFit.contain,
                width: widget.width ?? maxW,
                height: widget.height,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _broken(),
              );
            },
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
