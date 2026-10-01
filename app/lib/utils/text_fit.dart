/// Inserts wrap opportunities into long ASCII runs so a phone column can
/// show the whole token without a horizontal scroller.
String breakLongRuns(String text, {int every = 8}) {
  if (text.length < every) return text;
  final buf = StringBuffer();
  var run = 0;
  for (final rune in text.runes) {
    final sticky = rune > 32 && rune < 127;
    if (!sticky) {
      run = 0;
      buf.writeCharCode(rune);
      continue;
    }
    if (run > 0 && run % every == 0) buf.write('\u200b');
    buf.writeCharCode(rune);
    run++;
  }
  return buf.toString();
}

final _protectedMarkdown = RegExp(
  r'<img\b[^>]*>|!\[[^\]]*\]\([^)\n]*\)|\[[^\]\n]*\]\([^)\n]*\)|`[^`\n]+`',
);

final _chatFenceOpen = RegExp(r'^(```+|~~~+)');
final _chatOrdered = RegExp(r'^\d+\.\s');
final _chatRule = RegExp(r'^(?:\*{3,}|-{3,}|_{3,})[ \t]*$');

/// Chat replies often break lines once where a new paragraph was meant.
/// Markdown keeps those lines in one block, so the phone shows them stacked.
/// Put a blank line between prose lines. Lists, tables, quotes, headings,
/// and fenced code stay together.
String separateChatParagraphs(String markdown) {
  if (markdown.isEmpty || !markdown.contains('\n')) return markdown;
  final text = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return _mapChatOutsideFences(text, (prose) {
    return prose.split(RegExp(r'\n{2,}')).map(_separateChatBlock).join('\n\n');
  });
}

String _mapChatOutsideFences(String markdown, String Function(String prose) rewrite) {
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
    final open = _chatFenceOpen.firstMatch(line);
    if (fence.isEmpty && open != null) {
      flushText();
      fence = open.group(1)!;
      out.add(line);
      continue;
    }
    if (fence.isNotEmpty && line.startsWith(fence) && line.trim() == fence) {
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

bool _chatStructuralLine(String line) {
  final trimmed = line.trimLeft();
  if (trimmed.isEmpty) return false;
  if (trimmed.startsWith('#')) return true;
  if (trimmed.startsWith('>')) return true;
  if (trimmed.startsWith('|')) return true;
  if (trimmed.startsWith('![')) return true;
  if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) {
    return true;
  }
  if (_chatOrdered.hasMatch(trimmed)) return true;
  if (_chatFenceOpen.hasMatch(trimmed)) return true;
  if (_chatRule.hasMatch(trimmed)) return true;
  return false;
}

bool _chatHardBreak(String line) => line.endsWith('  ') || line.endsWith('\\');

String _separateChatBlock(String block) {
  final lines = block.split('\n');
  final content = lines.where((line) => line.trim().isNotEmpty).toList();
  if (content.length < 2) return block;

  final out = <String>[];
  final structural = <String>[];
  String? prose;

  void flushStructural() {
    if (structural.isEmpty) return;
    out.add(structural.join('\n'));
    structural.clear();
  }

  void flushProse() {
    if (prose == null) return;
    final text = prose!.trim();
    if (text.isNotEmpty) out.add(text);
    prose = null;
  }

  for (final line in content) {
    if (_chatStructuralLine(line)) {
      flushProse();
      structural.add(line.trimRight());
      continue;
    }
    if (structural.isNotEmpty && (line.startsWith(' ') || line.startsWith('\t'))) {
      structural.add(line.trimRight());
      continue;
    }
    flushStructural();
    if (prose != null && _chatHardBreak(prose!)) {
      prose = '$prose\n${line.trim()}';
      continue;
    }
    flushProse();
    prose = line.trimRight();
  }
  flushProse();
  flushStructural();
  return out.join('\n\n');
}

/// Soft-wrap long ASCII in chat markdown prose without touching tables,
/// fenced code, or link and image targets (those must stay byte-for-byte).
String prepareChatMarkdownForDisplay(
  String data, {
  bool Function(String line)? isTableLine,
}) {
  if (data.isEmpty) return data;
  final tableLine = isTableLine ?? (_) => false;
  var inFence = false;
  final out = <String>[];
  for (final line in data.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence ||
        line.trim().isEmpty ||
        tableLine(line) ||
        trimmed.startsWith('|')) {
      out.add(line);
      continue;
    }
    out.add(_breakOutsideProtected(line));
  }
  return out.join('\n');
}

String _breakOutsideProtected(String line) {
  final out = StringBuffer();
  var last = 0;
  for (final match in _protectedMarkdown.allMatches(line)) {
    out.write(breakLongRuns(line.substring(last, match.start)));
    out.write(match.group(0));
    last = match.end;
  }
  out.write(breakLongRuns(line.substring(last)));
  return out.toString();
}
