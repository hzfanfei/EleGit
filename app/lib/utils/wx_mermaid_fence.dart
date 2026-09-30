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

const _mermaidDiagramPrefixes = <String>[
  'flowchart',
  'graph',
  'sequencediagram',
  'statediagram',
  'classdiagram',
  'erdiagram',
  'journey',
  'gantt',
  'pie',
  'gitgraph',
  'mindmap',
  'timeline',
  'quadrantchart',
  'xychart',
  'sankey',
  'block',
  'packet',
  'kanban',
  'architecture',
  'c4context',
  'zenuml',
];

bool firstLineLooksLikeMermaidDiagram(String line) {
  final l = line.trim().toLowerCase();
  if (l.isEmpty) return false;
  for (final prefix in _mermaidDiagramPrefixes) {
    if (l == prefix || l.startsWith('$prefix ')) return true;
  }
  return false;
}

/// Fence info line after ``` (e.g. `mermaid`, `flowchart LR`).
bool isMermaidFenceLang(String lang) {
  final l = lang.trim().toLowerCase();
  if (l.isEmpty) return false;
  if (l == 'mermaid') return true;
  return firstLineLooksLikeMermaidDiagram(l);
}

/// Whole diagram source (for generic ``` fences whose body starts with flowchart…).
bool looksLikeMermaidSource(String code) {
  for (final line in code.split('\n')) {
    if (line.trim().isEmpty) continue;
    return firstLineLooksLikeMermaidDiagram(line);
  }
  return false;
}

/// Ensures mermaid-cli receives a valid diagram header line.
String normalizeMermaidFenceSource(String openLang, String body) {
  final trimmedBody = body.trimRight();
  if (trimmedBody.isEmpty) return trimmedBody;
  final lang = openLang.trim();
  if (lang.toLowerCase() == 'mermaid') return trimmedBody;
  for (final line in trimmedBody.split('\n')) {
    if (line.trim().isEmpty) continue;
    if (firstLineLooksLikeMermaidDiagram(line.trim())) return trimmedBody;
    break;
  }
  if (lang.isEmpty) return trimmedBody;
  return '${lang.trim()}\n$trimmedBody';
}

bool isMermaidFenceOpenLine(String line) {
  final stripped = line.trimLeft();
  if (!stripped.startsWith('```')) return false;
  final lang = stripped.substring(3).trim();
  return isMermaidFenceLang(lang);
}

bool isMermaidFenceCloseLine(String line) {
  final stripped = line.trimLeft();
  return stripped.startsWith('```') && stripped.replaceAll('`', '').trim().isEmpty;
}

/// Splits [markdown] so every mermaid-class fence is its own segment.
List<WxMarkdownMermaidSegment> splitMarkdownByMermaidFences(String markdown) {
  if (markdown.isEmpty) return const [];

  final normalized = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = normalized.split('\n');
  final segments = <WxMarkdownMermaidSegment>[];
  final proseBuf = StringBuffer();
  final mermaidBuf = StringBuffer();
  var inMermaid = false;
  var mermaidOpenLang = '';

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
    segments.add(
      WxMarkdownMermaidSegment.mermaid(
        normalizeMermaidFenceSource(mermaidOpenLang, code),
        closed,
      ),
    );
    mermaidOpenLang = '';
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
      mermaidOpenLang = line.trimLeft().substring(3).trim();
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
