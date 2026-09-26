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
