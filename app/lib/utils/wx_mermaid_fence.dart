/// One prose or mermaid segment after splitting markdown.
class WxMarkdownMermaidSegment {
  const WxMarkdownMermaidSegment.prose(this.prose)
      : mermaidCode = null,
        mermaidClosed = true;

  const WxMarkdownMermaidSegment.mermaid(this.mermaidCode, this.mermaidClosed)
      : prose = null;

  final String? prose;
  final String? mermaidCode;
  final bool mermaidClosed;

  bool get isMermaid => mermaidCode != null;
}

bool isMermaidFenceOpenLine(String line) {
  final stripped = line.trimLeft();
  if (!stripped.startsWith('```')) return false;
  final lang = stripped.substring(3).trim().toLowerCase();
  return lang == 'mermaid';
}

bool isMermaidFenceCloseLine(String line) {
  final stripped = line.trimLeft();
  return stripped.startsWith('```') && stripped.replaceAll('`', '').trim().isEmpty;
}

/// Splits [markdown] so every ```mermaid fence is its own segment.
List<WxMarkdownMermaidSegment> splitMarkdownByMermaidFences(String markdown) {
  if (markdown.isEmpty) return const [];

  final normalized = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final segments = <WxMarkdownMermaidSegment>[];
  final proseBuf = StringBuffer();
  final mermaidBuf = StringBuffer();
  var inMermaid = false;

  void flushProse() {
    final text = proseBuf.toString();
    proseBuf.clear();
    if (text.trim().isEmpty) return;
    segments.add(WxMarkdownMermaidSegment.prose(text));
  }

  void flushMermaid({required bool closed}) {
    final code = mermaidBuf.toString().trimRight();
    mermaidBuf.clear();
    inMermaid = false;
    segments.add(WxMarkdownMermaidSegment.mermaid(code, closed));
  }

  for (final line in lines) {
    if (inMermaid) {
      if (isMermaidFenceCloseLine(line)) {
        flushMermaid(closed: true);
      } else {
        mermaidBuf.writeln(line);
      }
      continue;
    }

    if (isMermaidFenceOpenLine(line)) {
      flushProse();
      inMermaid = true;
      continue;
    }

    proseBuf.writeln(line);
  }

  if (inMermaid) {
    flushMermaid(closed: false);
  } else {
    flushProse();
  }

  return segments;
}

String markdownSourceForMermaidSegment(WxMarkdownMermaidSegment segment) {
  if (!segment.isMermaid) return segment.prose ?? '';
  final buf = StringBuffer('```mermaid\n');
  final code = segment.mermaidCode ?? '';
  buf.write(code);
  if (segment.mermaidClosed) {
    if (code.isNotEmpty && !code.endsWith('\n')) buf.writeln();
    buf.writeln('```');
  }
  return buf.toString();
}

List<String> expandMarkdownBlockByMermaid(String block) {
  if (block.trim().isEmpty) return const [];
  final segments = splitMarkdownByMermaidFences(block);
  if (segments.length == 1 && !segments.single.isMermaid) {
    return [block];
  }
  return [
    for (final seg in segments)
      if (seg.isMermaid || (seg.prose ?? '').trim().isNotEmpty)
        markdownSourceForMermaidSegment(seg),
  ];
}
