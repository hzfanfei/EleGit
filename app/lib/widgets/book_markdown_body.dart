import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/book_markdown_assets.dart';

class BookMarkdownBody extends StatelessWidget {
  const BookMarkdownBody({
    super.key,
    required this.api,
    required this.bookId,
    required this.chapterFile,
    required this.data,
    required this.styleSheet,
    this.spineHref,
  });

  final WenxiangApi api;
  final String bookId;
  final String chapterFile;
  final String? spineHref;
  final String data;
  final MarkdownStyleSheet styleSheet;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      styleSheet: styleSheet,
      imageBuilder: (uri, title, alt) => _BookMarkdownImage(
        api: api,
        bookId: bookId,
        chapterFile: chapterFile,
        spineHref: spineHref,
        uri: uri,
        alt: alt ?? title ?? '',
      ),
    );
  }
}

class _BookMarkdownImage extends StatelessWidget {
  const _BookMarkdownImage({
    required this.api,
    required this.bookId,
    required this.chapterFile,
    required this.uri,
    required this.alt,
    this.spineHref,
  });

  final WenxiangApi api;
  final String bookId;
  final String chapterFile;
  final String? spineHref;
  final Uri uri;
  final String alt;

  @override
  Widget build(BuildContext context) {
    final raw = uri.toString();
    final resolved = raw.startsWith('http://') || raw.startsWith('https://') || raw.startsWith('data:')
        ? raw
        : resolveBookMarkdownAssetRef(
            src: Uri.decodeComponent(raw),
            chapterFile: chapterFile,
            spineHref: spineHref,
          );

    if (resolved == null || resolved.isEmpty) {
      return _brokenImage(alt, '无法解析图片路径');
    }

    final imageUri = resolved.startsWith('http://') ||
            resolved.startsWith('https://') ||
            resolved.startsWith('data:')
        ? Uri.parse(resolved)
        : api.bookAssetUri(bookId, resolved);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          imageUri.toString(),
          headers: api.assetHeaders,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => _brokenImage(alt, '图片加载失败'),
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return SizedBox(
              height: 120,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress.expectedTotalBytes != null
                      ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                      : null,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _brokenImage(String alt, String hint) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Wx.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Wx.hairline),
      ),
      child: Text(
        alt.isNotEmpty ? alt : hint,
        style: const TextStyle(color: Wx.faint, fontSize: 13),
      ),
    );
  }
}
