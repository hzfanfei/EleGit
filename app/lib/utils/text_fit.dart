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
/// Put a blank line between prose lines, indent Chinese paragraphs, and
/// break a long run of sentences into more than one paragraph. Lists,
/// tables, quotes, headings, and fenced code stay together. Top-level
/// bullets are separated so each item is its own block.
String separateChatParagraphs(String markdown) {
  if (markdown.isEmpty) return markdown;
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
  if (content.length < 2) {
    if (content.isEmpty) return block;
    final groups = _groupChatProse(content.first);
    if (groups.length < 2) {
      final shown = _indentChatProse(groups.isEmpty ? content.first : groups.first);
      return shown.isEmpty ? block : shown;
    }
    return groups.map(_indentChatProse).join('\n\n');
  }

  final out = <String>[];
  final structural = <String>[];
  String? prose;

  void flushStructural() {
    if (structural.isEmpty) return;
    out.add(_joinChatStructural(structural));
    structural.clear();
  }

  void flushProse() {
    if (prose == null) return;
    final text = prose!.trim();
    prose = null;
    if (text.isEmpty) return;
    for (final part in text.split('\n')) {
      for (final group in _groupChatProse(part)) {
        final shown = _indentChatProse(group);
        if (shown.isNotEmpty) out.add(shown);
      }
    }
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

String _joinChatStructural(List<String> lines) {
  final out = <String>[];
  for (final line in lines) {
    if (out.isNotEmpty && _topLevelBullet(line)) out.add('');
    out.add(line);
  }
  return out.join('\n');
}

bool _topLevelBullet(String line) {
  if (line.startsWith(' ') || line.startsWith('\t')) return false;
  final trimmed = line.trimLeft();
  return trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ');
}

final _chatBoldLabel = RegExp(r'^\*\*[^*\n]+\*\*$');
final _chatHan = RegExp(r'[\u3400-\u9FFF]');

String _indentChatProse(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.startsWith('\u3000')) return trimmed;
  if (_chatStructuralLine(trimmed) || !_chatHan.hasMatch(trimmed)) return trimmed;
  if (_chatBoldLabel.hasMatch(trimmed) && trimmed.runes.length <= 32) return trimmed;
  // A bare ideographic space is trimmed away before the paragraph is drawn.
  // A zero-width space keeps the indent in the text.
  return '\u200b\u3000\u3000$trimmed';
}

/// A phone column is about eighteen characters wide. Two long sentences on
/// one line read as a wall, so start a new paragraph after two sentences or
/// once the current group already fills about two lines.
List<String> _groupChatProse(String line) {
  final text = line.trim();
  if (text.isEmpty) return const [];
  final sentences = _cutChatSentences(text);
  if (sentences.length < 2) return [text];
  final groups = <String>[];
  final buf = StringBuffer();
  var count = 0;
  var runes = 0;
  for (final sentence in sentences) {
    final startNew = count >= 2 || (count >= 1 && runes >= 36);
    if (startNew && buf.isNotEmpty) {
      groups.add(buf.toString());
      buf.clear();
      count = 0;
      runes = 0;
    }
    buf.write(sentence);
    count++;
    runes += sentence.runes.length;
  }
  if (buf.isNotEmpty) groups.add(buf.toString());
  return groups.length < 2 ? [text] : groups;
}

const _chatSentenceClosers = '）」』”"';

List<String> _cutChatSentences(String text) {
  final cuts = <int>[];
  var bold = false;
  var code = false;
  var square = 0;
  var angle = 0;
  var corner = 0;
  var curly = 0;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (!code && i + 1 < text.length && ch == '*' && text[i + 1] == '*') {
      bold = !bold;
      i++;
      continue;
    }
    if (ch == '`') {
      code = !code;
      continue;
    }
    if (code || bold) continue;
    if (ch == '[') {
      square++;
    } else if (ch == ']' && square > 0) {
      square--;
    } else if (ch == '「') {
      angle++;
    } else if (ch == '」' && angle > 0) {
      angle--;
    } else if (ch == '『') {
      corner++;
    } else if (ch == '』' && corner > 0) {
      corner--;
    } else if (ch == '“') {
      curly++;
    } else if (ch == '”' && curly > 0) {
      curly--;
    }
    if (square > 0 || angle > 0 || corner > 0 || curly > 0) continue;
    if (ch != '。' && ch != '！' && ch != '？') continue;
    var end = i + 1;
    while (end < text.length && _chatSentenceClosers.contains(text[end])) {
      end++;
    }
    if (text.substring(end).trim().isNotEmpty) cuts.add(end);
  }
  if (cuts.isEmpty) return [text];
  final out = <String>[];
  var start = 0;
  for (final cut in cuts) {
    final part = text.substring(start, cut).trim();
    if (part.isNotEmpty) out.add(part);
    start = cut;
  }
  final tail = text.substring(start).trim();
  if (tail.isNotEmpty) out.add(tail);
  return out.length < 2 ? [text] : out;
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
