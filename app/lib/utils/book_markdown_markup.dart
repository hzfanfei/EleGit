import '../models.dart';
import 'book_markdown_assets.dart';

final _htmlPreCode = RegExp(
  r'<pre\b[^>]*>\s*<code\b[^>]*>([\s\S]*?)</code>\s*</pre>',
  caseSensitive: false,
);
final _htmlPre = RegExp(r'<pre\b[^>]*>([\s\S]*?)</pre>', caseSensitive: false);
final _htmlCode = RegExp(r'<code\b[^>]*>([\s\S]*?)</code>', caseSensitive: false);
final _htmlAnchor = RegExp(r'<a\b([^>]*)>([\s\S]*?)</a>', caseSensitive: false);
final _htmlAttr = RegExp(
  r'''\bhref\s*=\s*(["'])([^"']*)\1|\bhref\s*=\s*([^\s>]+)''',
  caseSensitive: false,
);
final _htmlFootnote = RegExp(
  r'<sup>\s*<a\b[^>]*>\s*<span\b[^>]*>([\s\S]*?)</span>\s*</a>\s*</sup>',
  caseSensitive: false,
);
final _imagePlaceholder = RegExp(
  r'''<span\b[^>]*(?:data-)?original-image-src\s*=\s*(["'])([^"']+)\1[^>]*>([\s\S]*?)</span>''',
  caseSensitive: false,
);
final _htmlStrong = RegExp(r'<(strong|b)\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false);
final _htmlEm = RegExp(r'<(em|i)\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false);
final _htmlBr = RegExp(r'<br\s*/?>', caseSensitive: false);
final _chromeTag = RegExp(
  r'</?(?:div|span|p|section|article|header|footer|figure|figcaption|nav|main|aside|font|center|sup|sub|u|small)(?:\s[^>]*)?>',
  caseSensitive: false,
);

String decodeBookHtmlEntities(String raw) {
  return raw
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}

String _stripHtml(String raw) {
  return decodeBookHtmlEntities(raw.replaceAll(RegExp(r'<[^>]+>'), '')).trim();
}

String _fenceFromHtml(String inner) {
  final code = decodeBookHtmlEntities(inner.replaceAll(RegExp(r'<[^>]+>'), ''));
  return '\n```\n${code.trimRight()}\n```\n';
}

String mapMarkdownOutsideFences(String markdown, String Function(String prose) rewrite) {
  final lines = markdown.split('\n');
  final out = <String>[];
  var fence = '';
  final buf = <String>[];
  void flushText() {
    if (buf.isEmpty) return;
    out.add(rewrite(buf.join('\n')));
    buf.clear();
  }

  for (final line in lines) {
    final open = RegExp(r'^(```+|~~~+)').firstMatch(line);
    if (fence.isEmpty && open != null) {
      flushText();
      fence = open.group(1)!;
      out.add(line);
      continue;
    }
    if (fence.isNotEmpty && line.startsWith(fence)) {
      out.add(line);
      fence = '';
      continue;
    }
    if (fence.isNotEmpty) {
      out.add(line);
      continue;
    }
    buf.add(line);
  }
  if (fence.isNotEmpty) {
    out.addAll(buf);
  } else {
    flushText();
  }
  return out.join('\n');
}

String mapOutsideInlineCode(String text, String Function(String chunk) rewrite) {
  final re = RegExp(r'(`+)([^`\n]*?)\1');
  final out = StringBuffer();
  var last = 0;
  for (final match in re.allMatches(text)) {
    out.write(rewrite(text.substring(last, match.start)));
    out.write(match.group(0));
    last = match.end;
  }
  out.write(rewrite(text.substring(last)));
  return out.toString();
}

String _normalizeBookProse(String markdown) {
  var out = markdown;
  out = out.replaceAllMapped(_htmlFootnote, (match) {
    final note = _stripHtml(match.group(1) ?? '');
    return note.isEmpty ? '' : '（$note）';
  });
  out = out.replaceAllMapped(_imagePlaceholder, (match) {
    final src = (match.group(2) ?? '').trim();
    final alt = _stripHtml(match.group(3) ?? '');
    if (src.isEmpty) return alt;
    final label = alt == 'Cover Image' ? '' : alt;
    return '![$label]($src)';
  });
  out = promoteBookHtmlImages(out);
  out = out.replaceAllMapped(_htmlPreCode, (match) => _fenceFromHtml(match.group(1) ?? ''));
  out = out.replaceAllMapped(_htmlPre, (match) => _fenceFromHtml(match.group(1) ?? ''));
  out = out.replaceAllMapped(_htmlCode, (match) {
    final inner = _stripHtml(match.group(1) ?? '').replaceAll('\n', ' ');
    if (inner.isEmpty) return match.group(0) ?? '';
    return '`$inner`';
  });
  out = out.replaceAllMapped(_htmlAnchor, (match) {
    final href = decodeBookHtmlEntities(
      ( _htmlAttr.firstMatch(match.group(1) ?? '')?.group(2) ??
            _htmlAttr.firstMatch(match.group(1) ?? '')?.group(3) ??
            '')
          .trim(),
    );
    final text = _stripHtml(match.group(2) ?? '');
    if (href.isEmpty) return text.isEmpty ? (match.group(0) ?? '') : text;
    return '[${text.isEmpty ? href : text}]($href)';
  });
  out = out.replaceAllMapped(_htmlStrong, (match) => '**${_stripHtml(match.group(2) ?? '')}**');
  out = out.replaceAllMapped(_htmlEm, (match) => '*${_stripHtml(match.group(2) ?? '')}*');
  out = out.replaceAll(_htmlBr, '\n');
  out = out.replaceAllMapped(_chromeTag, (match) {
    final tag = match.group(0) ?? '';
    if (RegExp(r'^</?(?:p|div|section|article|header|footer|figure|figcaption|nav|main|aside)\b', caseSensitive: false)
        .hasMatch(tag)) {
      return '\n\n';
    }
    return '';
  });
  return decodeBookHtmlEntities(out);
}

/// EPUB leftover HTML → markdown flutter_markdown can actually render.
String normalizeBookMarkdown(String markdown) {
  return mapMarkdownOutsideFences(
    markdown,
    (prose) => mapOutsideInlineCode(prose, _normalizeBookProse),
  ).replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

/// External http(s) target, or null for in-book / invalid hrefs.
Uri? bookMarkdownExternalUri(String href) {
  var raw = decodeBookHtmlEntities(href.trim());
  if (raw.isEmpty) return null;
  if (raw.startsWith('mailto:') || raw.startsWith('tel:')) {
    return Uri.tryParse(raw);
  }
  if (!raw.contains('://')) {
    if (RegExp(r'^(www\.|[a-z0-9-]+\.[a-z]{2,})(:\d+)?([/?#]|$)', caseSensitive: false)
        .hasMatch(raw)) {
      raw = 'https://$raw';
    } else {
      return null;
    }
  }
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.isScheme('http') || uri.isScheme('https')) return uri;
  return null;
}

int? resolveBookMarkdownChapterLink({
  required String href,
  String text = '',
  List<BookChapterEntry> chapters = const [],
  List<BookTocEntry> toc = const [],
}) {
  final title = text.trim();
  if (title.isNotEmpty) {
    for (final entry in toc) {
      if (entry.title.trim() == title) return entry.index;
    }
    for (final chapter in chapters) {
      if (chapter.title.trim() == title) return chapter.index;
    }
  }

  final path = href.trim().split('#').first.replaceAll('\\', '/');
  if (path.isEmpty || path.startsWith('http://') || path.startsWith('https://')) {
    return null;
  }
  final parts = path.split('/').where((part) => part.isNotEmpty && part != '.' && part != '..');
  if (parts.isEmpty) return null;
  final base = parts.last;
  final stem = base.replaceAll(RegExp(r'\.(xhtml|html|htm)$', caseSensitive: false), '');
  for (final chapter in chapters) {
    final hrefPath = (chapter.href ?? '').replaceAll('\\', '/');
    if (hrefPath.endsWith('/$base') || hrefPath.endsWith(base)) return chapter.index;
    final file = chapter.file;
    if (file == base || file.contains('-$stem.') || file.contains(stem)) {
      return chapter.index;
    }
  }
  return null;
}
