import '../models.dart';
import 'book_markdown_assets.dart';
import 'text_fit.dart';

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
  r'''<sup\b[^>]*>\s*<a\b([^>]*)>([\s\S]*?)</a>\s*</sup>''',
  caseSensitive: false,
);
final _htmlHeading = RegExp(r'<h([1-6])\b[^>]*>([\s\S]*?)</h\1>', caseSensitive: false);
final _htmlOrdered = RegExp(r'<ol\b[^>]*>([\s\S]*?)</ol>', caseSensitive: false);
final _htmlUnordered = RegExp(r'<ul\b[^>]*>([\s\S]*?)</ul>', caseSensitive: false);
final _htmlLi = RegExp(r'<li\b[^>]*>([\s\S]*?)</li>', caseSensitive: false);
final _htmlQuote = RegExp(r'<blockquote\b[^>]*>([\s\S]*?)</blockquote>', caseSensitive: false);
final _footnoteId = RegExp(
  r'''<(?:li|aside|div|p|dd)\b[^>]*\bid\s*=\s*(["'])([^"']+)\1[^>]*>([\s\S]*?)</(?:li|aside|div|p|dd)>''',
  caseSensitive: false,
);
final _mdLink = RegExp(r'(?<!!)\[([^\[\]]+)\]\(([^)\s]+)\)');
const _brJoin = '\u0001';
final _imagePlaceholder = RegExp(
  r'''<span\b[^>]*(?:data-)?original-image-src\s*=\s*(["'])([^"']+)\1[^>]*>([\s\S]*?)</span>''',
  caseSensitive: false,
);
final _htmlStrong = RegExp(r'<(strong|b)\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false);
final _htmlEm = RegExp(r'<(em|i)\b[^>]*>([\s\S]*?)</\1>', caseSensitive: false);
final _htmlBr = RegExp(r'<br\s*/?>', caseSensitive: false);
final _chromeTag = RegExp(
  r'</?(?:div|span|p|section|article|header|footer|figure|figcaption|nav|main|aside|font|center|sup|sub|u|small|ul|ol|li|h[1-6]|blockquote)(?:\s[^>]*)?>',
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

String _plainBlock(String raw) {
  var text = raw.replaceAll(_htmlBr, '\n');
  text = text.replaceAll(RegExp(r'</(?:p|div|li)>\s*<(?:p|div|li)\b[^>]*>', caseSensitive: false), '\n');
  return _stripHtml(text);
}

Map<String, String> _footnoteBodies(String raw) {
  final notes = <String, String>{};
  for (final match in _footnoteId.allMatches(raw)) {
    final id = (match.group(2) ?? '').trim();
    final text = _plainBlock(match.group(3) ?? '');
    if (id.isEmpty || text.isEmpty) continue;
    notes[id] = text;
  }
  return notes;
}

String _footnoteMarker(String label) {
  final text = label.trim();
  if (RegExp(r'^\d{1,3}$').hasMatch(text)) {
    const digits = ['⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹'];
    return text.split('').map((ch) => digits[int.parse(ch)]).join();
  }
  if (text.runes.length <= 2 && text.isNotEmpty) return text;
  return '注';
}

String _markBreaks(String input) {
  return input.replaceAllMapped(RegExp(r'(?:<br\s*/?>\s*)+', caseSensitive: false), (match) {
    final count = RegExp(r'<br\s*/?>', caseSensitive: false).allMatches(match.group(0)!).length;
    return count >= 2 ? '\n\n' : _brJoin;
  });
}

bool _isCjk(int rune) {
  return (rune >= 0x3400 && rune <= 0x9FFF) || (rune >= 0xF900 && rune <= 0xFAFF);
}

bool _looksLikeVerse(List<String> lines) {
  if (lines.length < 3) return false;
  final lengths = lines.map((line) => line.runes.length).toList();
  if (lengths.any((length) => length > 18)) return false;
  final average = lengths.reduce((a, b) => a + b) / lengths.length;
  return average <= 14;
}

String _joinProse(List<String> pieces) {
  final buf = StringBuffer(pieces.first);
  for (final next in pieces.skip(1)) {
    final prev = buf.toString();
    if (prev.isEmpty) {
      buf.write(next);
      continue;
    }
    final left = prev.runes.last;
    final right = next.runes.first;
    final spaced = prev.endsWith(' ') || next.startsWith(' ');
    // CJK runs stay flush. Latin words, and CJK beside Latin, keep a space.
    if (!spaced && !(_isCjk(left) && _isCjk(right))) buf.write(' ');
    buf.write(next);
  }
  return buf.toString();
}

String _relaxBlock(String block) {
  if (!block.contains(_brJoin)) return block;
  final pieces = block.split(_brJoin).map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
  if (pieces.length < 2) return pieces.join();
  if (_looksLikeVerse(pieces)) return pieces.join('\n');
  return _joinProse(pieces);
}

String relaxBookLineBreaks(String markdown) {
  return mapMarkdownOutsideFences(markdown, (prose) {
    return prose.split(RegExp(r'\n{2,}')).map(_relaxBlock).join('\n\n');
  });
}

String _listFromHtml(String inner, {required bool ordered}) {
  var index = 1;
  final items = <String>[];
  for (final match in _htmlLi.allMatches(inner)) {
    final text = _plainBlock(match.group(1) ?? '').replaceAll('\n', ' ').trim();
    if (text.isEmpty) continue;
    items.add(ordered ? '${index++}. $text' : '- $text');
  }
  if (items.isEmpty) return _plainBlock(inner);
  return items.join('\n');
}

bool _skipParagraphIndent(String trimmed) {
  if (trimmed.isEmpty) return true;
  if (trimmed.startsWith('\u3000')) return true;
  if (trimmed.startsWith('#')) return true;
  if (trimmed.startsWith('>')) return true;
  if (trimmed.startsWith('|')) return true;
  if (trimmed.startsWith('![')) return true;
  if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) return true;
  if (RegExp(r'^\d+\.\s').hasMatch(trimmed)) return true;
  if (!RegExp(r'[\u3400-\u9FFF]').hasMatch(trimmed)) return true;
  final lines = trimmed.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
  if (_looksLikeVerse(lines)) return true;
  return false;
}

String indentChineseParagraphs(String markdown) {
  return mapMarkdownOutsideFences(markdown, (prose) {
    return prose.split(RegExp(r'\n{2,}')).map(_indentBlock).join('\n\n');
  });
}

String _indentBlock(String block) {
  final trimmed = block.trim();
  if (trimmed.isEmpty) return block;
  final lines = trimmed.split('\n');
  final content = lines.map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
  if (_looksLikeVerse(content)) return trimmed;
  var indented = false;
  return lines.map((line) {
    final text = line.trimLeft();
    if (indented || _skipParagraphIndent(text)) return line.trimRight().isEmpty ? line : text;
    indented = true;
    final lead = line.substring(0, line.length - text.length);
    return '$lead\u3000\u3000$text';
  }).join('\n');
}

String decorateBookLinks(String markdown) {
  return mapMarkdownOutsideFences(markdown, (prose) {
    return mapOutsideInlineCode(prose, (chunk) {
      return chunk.replaceAllMapped(_mdLink, (match) {
        final text = match.group(1) ?? '';
        final href = match.group(2) ?? '';
        if (bookMarkdownExternalUri(href) == null) return match.group(0)!;
        if (text.endsWith('↗')) return match.group(0)!;
        return '[$text↗]($href)';
      });
    });
  });
}

String softenBookMarkdown(String markdown) {
  return mapMarkdownOutsideFences(markdown, (prose) {
    return mapOutsideInlineCode(prose, (chunk) {
      final parked = <String>[];
      String hold(String token) {
        parked.add(token);
        return '\u0002${parked.length - 1}\u0002';
      }

      final saved = chunk
          .replaceAllMapped(RegExp(r'!\[[^\]]*\]\([^)\s]+\)'), (match) => hold(match.group(0)!))
          .replaceAllMapped(_mdLink, (match) => hold(match.group(0)!));
      final softened = saved.replaceAllMapped(RegExp(r'[!-~]{16,}'), (match) {
        return breakLongRuns(match.group(0)!);
      });
      return softened.replaceAllMapped(RegExp(r'\u0002(\d+)\u0002'), (match) {
        return parked[int.parse(match.group(1)!)];
      });
    });
  });
}

String omitLeadingChapterHeading(String markdown, String title) {
  final wanted = sanitizeBookDisplayTitle(title);
  if (wanted.isEmpty) return markdown;
  final lines = markdown.split('\n');
  var start = 0;
  while (start < lines.length && lines[start].trim().isEmpty) {
    start += 1;
  }
  if (start >= lines.length) return markdown;
  final first = lines[start].trim();
  final heading = RegExp(r'^#{1,6}\s+(.+)$').firstMatch(first);
  final text = heading?.group(1) ?? first;
  if (sanitizeBookDisplayTitle(text) != wanted) return markdown;
  var next = start + 1;
  while (next < lines.length && lines[next].trim().isEmpty) {
    next += 1;
  }
  return lines.sublist(next).join('\n');
}

String _normalizeBookProse(String markdown) {
  final notes = _footnoteBodies(markdown);
  var out = markdown;
  out = out.replaceAllMapped(_htmlFootnote, (match) {
    final attrs = match.group(1) ?? '';
    final href = decodeBookHtmlEntities(
      (_htmlAttr.firstMatch(attrs)?.group(2) ?? _htmlAttr.firstMatch(attrs)?.group(3) ?? '').trim(),
    );
    final label = _plainBlock(match.group(2) ?? '');
    var note = label;
    if (href.startsWith('#')) {
      var id = href.substring(1);
      try {
        id = Uri.decodeComponent(id);
      } catch (_) {}
      final body = notes[id];
      if (body != null && body.isNotEmpty) note = body;
    }
    if (note.isEmpty) return '';
    final marker = _footnoteMarker(label.isEmpty ? '注' : label);
    return '[$marker](wx-footnote:${Uri.encodeComponent(note)})';
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
  out = out.replaceAllMapped(_htmlHeading, (match) {
    final level = int.parse(match.group(1)!);
    final text = _plainBlock(match.group(2) ?? '').replaceAll('\n', ' ').trim();
    if (text.isEmpty) return '';
    return '\n\n${'#' * level} $text\n\n';
  });
  out = out.replaceAllMapped(_htmlOrdered, (match) {
    return '\n\n${_listFromHtml(match.group(1) ?? '', ordered: true)}\n\n';
  });
  out = out.replaceAllMapped(_htmlUnordered, (match) {
    return '\n\n${_listFromHtml(match.group(1) ?? '', ordered: false)}\n\n';
  });
  out = out.replaceAllMapped(_htmlLi, (match) {
    final text = _plainBlock(match.group(1) ?? '').replaceAll('\n', ' ').trim();
    return text.isEmpty ? '' : '\n- $text\n';
  });
  out = out.replaceAllMapped(_htmlQuote, (match) {
    final quoted = _plainBlock(match.group(1) ?? '')
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .map((line) => line.startsWith('>') ? line : '> $line')
        .join('\n');
    return quoted.isEmpty ? '' : '\n\n$quoted\n\n';
  });
  out = _markBreaks(out);
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
  final converted = mapMarkdownOutsideFences(
    markdown,
    (prose) => mapOutsideInlineCode(prose, _normalizeBookProse),
  ).replaceAll(RegExp(r'\n{3,}'), '\n\n');
  final relaxed = relaxBookLineBreaks(converted).replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return indentChineseParagraphs(softenBookMarkdown(decorateBookLinks(relaxed)))
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .replaceAll(RegExp(r'^\n+|\n+$'), '');
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
