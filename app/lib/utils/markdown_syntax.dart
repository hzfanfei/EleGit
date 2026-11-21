final _codeOpening = RegExp(r'^(`{3,}|~{3,})(.*)$');
final _mathEnd = RegExp(r'(?<!\\)\\\]');
final _dollarEnd = RegExp(r'(?<!\\)\$\$');

final markdownProtectedInline = RegExp(
  r'<img\b[^>]*>|!?\[[^\]\n]*\]\([^)\n]*\)'
  r'|(?<!`)(`+)(?!`)[^\n]*?(?<!`)\1(?!`)'
  r'|(?<!\\)\\\([^\n]*?(?<!\\)\\\)'
  r'|(?<!\\)\\\[[\s\S]*?(?<!\\)\\\]'
  r'|(?<!\\)\$\$[\s\S]*?(?<!\\)\$\$',
);

class MarkdownCodeFence {
  const MarkdownCodeFence._(this.marker, this.info);

  final String marker;
  final String info;

  static MarkdownCodeFence? opening(String line) {
    final text = line.trimLeft();
    if (!text.startsWith('```') && !text.startsWith('~~~')) return null;
    final match = _codeOpening.firstMatch(text.trimRight());
    if (match == null) return null;
    final marker = match[1]!;
    final info = match[2]!.trim();
    if (marker.startsWith('`') && info.contains('`')) return null;
    return MarkdownCodeFence._(marker, info);
  }

  bool closes(String line) {
    final text = line.trim();
    if (!text.startsWith(marker)) return false;
    for (var i = marker.length; i < text.length; i++) {
      if (text.codeUnitAt(i) != marker.codeUnitAt(0)) return false;
    }
    return true;
  }
}

bool startsMarkdownDisplayMath(String trimmed) =>
    trimmed.startsWith(r'\[') || trimmed.startsWith(r'$$');

/// Fences and display math can contain blank lines and Markdown syntax.
/// The opening and closing lines belong to the protected region as well.
class MarkdownLiteralScanner {
  MarkdownCodeFence? fence;
  RegExp? _closingMath;

  bool get isOpen => fence != null || _closingMath != null;

  bool consume(String line) {
    if (fence case final open?) {
      if (open.closes(line)) fence = null;
      return true;
    }
    if (_closingMath case final closing?) {
      if (closing.hasMatch(line)) _closingMath = null;
      return true;
    }
    fence = MarkdownCodeFence.opening(line);
    if (fence != null) return true;
    final text = line.trimLeft();
    if (!startsMarkdownDisplayMath(text)) return false;
    final closing = text.startsWith(r'$$') ? _dollarEnd : _mathEnd;
    if (!closing.hasMatch(text.substring(2))) _closingMath = closing;
    return true;
  }
}

String mapOutsideMarkdownLiterals(
  String markdown,
  String Function(String prose) rewrite,
) {
  final scanner = MarkdownLiteralScanner();
  final out = <String>[];
  final prose = <String>[];

  void flushProse() {
    if (prose.isEmpty) return;
    out.add(rewrite(prose.join('\n')));
    prose.clear();
  }

  for (final line in markdown.split('\n')) {
    if (scanner.consume(line)) {
      flushProse();
      out.add(line);
    } else {
      prose.add(line);
    }
  }
  flushProse();
  return out.join('\n');
}

/// GptMarkdown accepts bracket delimiters for display math. Keep the formula
/// body, inline code and link targets intact, and leave single dollars alone.
String normalizeMarkdownDisplayMath(String text) {
  if (!text.contains(r'$$') && !text.contains(r'\[')) return text;
  return text.replaceAllMapped(markdownProtectedInline, (match) {
    final value = match[0]!;
    final dollars = value.startsWith(r'$$');
    if (!dollars && !value.startsWith(r'\[')) return value;

    final formula =
        dollars ? '\\[${value.substring(2, value.length - 2)}\\]' : value;
    if (match.end == text.length || text[match.end] == '\n') return formula;
    final lineStart =
        match.start == 0 ? 0 : text.lastIndexOf('\n', match.start - 1) + 1;
    // The block renderer consumes the closing line. Keep any prose after it.
    return text.substring(lineStart, match.start).trim().isEmpty
        ? '$formula\n'
        : formula;
  });
}
