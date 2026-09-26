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

/// Soft-wrap long ASCII in chat markdown prose without touching tables or
/// fenced code (those use dedicated renderers).
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
    out.add(breakLongRuns(line));
  }
  return out.join('\n');
}
