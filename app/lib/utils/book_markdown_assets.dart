import 'package:path/path.dart' as p;

/// Cache-relative candidates for a markdown image `src`.
List<String> bookMarkdownAssetCandidates({
  required String src,
  required String chapterFile,
  String? spineHref,
}) {
  final trimmed = src.trim();
  if (trimmed.isEmpty) return const [];
  if (trimmed.startsWith('http://') ||
      trimmed.startsWith('https://') ||
      trimmed.startsWith('data:')) {
    return [trimmed];
  }

  final posix = p.Context(style: p.Style.posix);
  final decoded = Uri.decodeFull(trimmed.replaceAll('\\', '/'));
  final base = posix.basename(decoded.split('?').first);
  final out = <String>[];

  void add(String joined) {
    final normalized = posix.normalize(joined.replaceAll('\\', '/'));
    if (normalized.isEmpty || normalized.startsWith('..') || normalized.startsWith('/')) {
      return;
    }
    if (!out.contains(normalized)) out.add(normalized);
  }

  if (base.isNotEmpty) {
    add(posix.join('extracted', 'OEBPS', 'Images', base));
    add(posix.join('extracted', 'Images', base));
    add(posix.join('media', base));
  }
  if (spineHref != null && spineHref.trim().isNotEmpty) {
    add(posix.join('extracted', posix.dirname(spineHref.replaceAll('\\', '/')), decoded));
  }
  add(posix.normalize(decoded.replaceFirst(RegExp(r'^(\.\./)+'), '')));
  add(posix.join('chapters', decoded));
  if (!decoded.contains('/') && base.isNotEmpty) {
    add(posix.join('extracted', 'OEBPS', base));
  }
  return out;
}

/// Turn leftover EPUB `<img>` tags into markdown images flutter_markdown can render.
String promoteBookHtmlImages(String markdown) {
  return markdown.replaceAllMapped(RegExp(r'<img\b[^>]*>', caseSensitive: false), (match) {
    final tag = match[0] ?? '';
    final src = RegExp(
      r'''\bsrc\s*=\s*(["'])([^"']*)\1|\bsrc\s*=\s*([^\s>]+)''',
      caseSensitive: false,
    ).firstMatch(tag);
    final path = (src?.group(2) ?? src?.group(3) ?? '').trim();
    if (path.isEmpty) return tag;
    final altMatch = RegExp(
      r'''\balt\s*=\s*(["'])([^"']*)\1|\balt\s*=\s*([^\s>]+)''',
      caseSensitive: false,
    ).firstMatch(tag);
    final alt = (altMatch?.group(2) ?? altMatch?.group(3) ?? '').trim();
    return '![${alt == '{%}' ? '' : alt}]($path)';
  });
}

/// Resolve a markdown image `src` to a path relative to the book cache dir.
String? resolveBookMarkdownAssetRef({
  required String src,
  required String chapterFile,
  String? spineHref,
}) {
  final trimmed = src.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('http://') ||
      trimmed.startsWith('https://') ||
      trimmed.startsWith('data:')) {
    return trimmed;
  }
  final candidates = bookMarkdownAssetCandidates(
    src: trimmed,
    chapterFile: chapterFile,
    spineHref: spineHref,
  );
  return candidates.isEmpty ? trimmed : candidates.first;
}
