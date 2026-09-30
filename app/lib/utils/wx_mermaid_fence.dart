/// Result of parsing a chat/stream block that contains only a mermaid fence.
class WxMermaidFenceParse {
  const WxMermaidFenceParse({required this.code, required this.closed});

  final String code;
  final bool closed;
}

/// When [block] is solely a ```mermaid fence (open or closed), returns its body.
WxMermaidFenceParse? parseMermaidFenceBlock(String block) {
  if (block.trim().isEmpty) return null;
  final normalized = block.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  if (lines.isEmpty) return null;

  final open = lines.first.trimLeft();
  if (!open.startsWith('```')) return null;
  final lang = open.substring(3).trim().toLowerCase();
  if (lang != 'mermaid') return null;

  var closed = false;
  if (lines.length >= 2) {
    final closeLine = lines.last.trimLeft();
    if (closeLine.startsWith('```') && closeLine.replaceAll('`', '').trim().isEmpty) {
      closed = true;
    }
  }

  final body = <String>[];
  for (var i = 1; i < lines.length; i++) {
    if (closed && i == lines.length - 1) {
      final closeLine = lines[i].trimLeft();
      if (closeLine.startsWith('```') && closeLine.replaceAll('`', '').trim().isEmpty) {
        continue;
      }
    }
    body.add(lines[i]);
  }

  return WxMermaidFenceParse(code: body.join('\n').trimRight(), closed: closed);
}
