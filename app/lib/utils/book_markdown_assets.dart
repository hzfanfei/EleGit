import 'package:path/path.dart' as p;

/// Resolve a markdown image `src` to a path relative to the book cache dir.
String? resolveBookMarkdownAssetRef({
  required String src,
  required String chapterFile,
  String? spineHref,
}) {
  final trimmed = src.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return trimmed;
  }
  if (trimmed.startsWith('data:')) return trimmed;

  final posix = p.Context(style: p.Style.posix);

  String? normalizeCachePath(String joined) {
    final normalized = posix.normalize(joined.replaceAll('\\', '/'));
    if (normalized.startsWith('..') || normalized.contains('/../')) {
      return null;
    }
    if (normalized.startsWith('/')) return null;
    return normalized;
  }

  final fromChapter = normalizeCachePath(
    posix.join('chapters', chapterFile, trimmed),
  );
  if (fromChapter != null) return fromChapter;

  final href = (spineHref ?? '').trim().replaceAll('\\', '/');
  if (href.isNotEmpty) {
    final fromSpine = normalizeCachePath(
      posix.join('extracted', posix.dirname(href), trimmed),
    );
    if (fromSpine != null) return fromSpine;
  }

  return normalizeCachePath(trimmed);
}
