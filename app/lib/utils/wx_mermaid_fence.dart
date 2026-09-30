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

const _reflowDiagramTypes = <String>[
  'stateDiagram-v2',
  'sequenceDiagram',
  'classDiagram',
  'erDiagram',
  'quadrantChart',
  'xychart-beta',
  'sankey-beta',
  'block-beta',
  'architecture-beta',
  'flowchart',
  'stateDiagram',
  'gitGraph',
  'mindmap',
  'timeline',
  'C4Context',
  'journey',
  'kanban',
  'zenuml',
  'gantt',
  'graph',
  'pie',
];

final _flowDirection = RegExp(r'^(TD|TB|LR|RL|BT)\b', caseSensitive: false);

/// ACP text deltas sometimes arrive with newlines removed, so a fence shows up
/// as ` ```mermaidflowchart TD A-->B ``` ` and never becomes a diagram.
String restoreFlattenedMermaidFences(String input) {
  if (!input.contains('```')) return input;
  final text = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final start = _fenceOpenAt(text, i);
    if (start < 0) {
      out.write(text.substring(i));
      break;
    }
    out.write(text.substring(i, start));
    final close = _fenceCloseAt(text, start + 3);
    if (close < 0) {
      out.write(text.substring(start));
      break;
    }
    final inner = text.substring(start + 3, close);
    final reflowed = _reflowMermaidInner(inner);
    if (out.isNotEmpty && !out.toString().endsWith('\n')) out.writeln();
    if (reflowed == null) {
      out
        ..write('```')
        ..write(inner)
        ..write('```');
    } else {
      out.write(reflowed);
    }
    final after = close + 3;
    if (after < text.length && text[after] != '\n') out.writeln();
    i = after;
  }
  return out.toString();
}

int _fenceOpenAt(String text, int from) {
  var i = from;
  while (i < text.length) {
    final at = text.indexOf('```', i);
    if (at < 0) return -1;
    final glued = (at > 0 && text[at - 1] == '`') || (at + 3 < text.length && text[at + 3] == '`');
    if (!glued) return at;
    i = at + 1;
  }
  return -1;
}

int _fenceCloseAt(String text, int from) => _fenceOpenAt(text, from);

String? _reflowMermaidInner(String inner) {
  final trimmed = inner.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.contains('\n')) {
    final first = trimmed.split('\n').first.trim().toLowerCase();
    if (first == 'mermaid' || firstLineLooksLikeMermaidDiagram(first)) return null;
  }
  var source = trimmed;
  if (source.toLowerCase().startsWith('mermaid')) {
    final rest = source.substring('mermaid'.length);
    if (rest.isEmpty || !RegExp(r'^[A-Za-z]').hasMatch(rest)) return null;
    source = rest;
  }
  final head = _matchDiagramHead(source);
  if (head == null) return null;
  final statements = _splitDiagramStatements(head.type, head.body);
  final buf = StringBuffer('```mermaid\n');
  buf.writeln(head.header);
  if (statements.isNotEmpty) buf.writeln(statements);
  buf.write('```');
  return buf.toString();
}

class _DiagramHead {
  const _DiagramHead(this.type, this.header, this.body);
  final String type;
  final String header;
  final String body;
}

_DiagramHead? _matchDiagramHead(String source) {
  final trimmed = source.trimLeft();
  for (final type in _reflowDiagramTypes) {
    if (!trimmed.toLowerCase().startsWith(type.toLowerCase())) continue;
    final rest = trimmed.substring(type.length);
    final lower = type.toLowerCase();
    if (lower == 'flowchart' || lower == 'graph') {
      if (rest.isNotEmpty && RegExp(r'^[A-Za-z]').hasMatch(rest)) {
        final dir = _flowDirection.firstMatch(rest);
        if (dir == null) continue;
        final header = '$lower ${dir.group(1)!.toUpperCase()}';
        return _DiagramHead(lower, header, rest.substring(dir.end).trimLeft());
      }
      if (rest.isNotEmpty && !RegExp(r'^\s').hasMatch(rest)) continue;
      final spaced = RegExp(r'^\s+(TD|TB|LR|RL|BT)\b', caseSensitive: false).firstMatch(rest);
      if (spaced == null) continue;
      final header = '$lower ${spaced.group(1)!.toUpperCase()}';
      return _DiagramHead(lower, header, rest.substring(spaced.end).trimLeft());
    }
    if (lower == 'pie' && rest.isNotEmpty && RegExp(r'^[A-Za-z]').hasMatch(rest)) continue;
    return _DiagramHead(type, type, rest.trimLeft());
  }
  return null;
}

String _splitDiagramStatements(String type, String body) {
  final lower = type.toLowerCase();
  if (lower == 'flowchart' || lower == 'graph' || lower.startsWith('statediagram')) {
    return _splitFlowStatements(body);
  }
  if (lower == 'sequencediagram') return _splitSequenceStatements(body);
  return body.trim();
}

String _splitFlowStatements(String body) {
  var s = body.trim();
  if (s.isEmpty) return s;
  s = s.replaceAllMapped(RegExp(r'(?<=[\]\}])\s+(?=[A-Za-z_])'), (_) => '\n');
  s = s.replaceAllMapped(
    RegExp(r'(?<=\S)\s+(?=(?:subgraph|end|classDef|click|style|linkStyle|direction)\b)'),
    (_) => '\n',
  );
  s = s.replaceAllMapped(
    RegExp(r'(?<=\S)\s+(?=[A-Za-z_][\w-]*\s*(?:-->|---|==>|-.->))'),
    (_) => '\n',
  );
  return s;
}

String _splitSequenceStatements(String body) {
  var s = body.trim();
  if (s.isEmpty) return s;
  s = s.replaceAllMapped(
    RegExp(
      r'(?<=\S)\s+(?=(?:participant|actor|Note|loop|alt|else|opt|par|and|rect|activate|deactivate|autonumber|end)\b)',
    ),
    (_) => '\n',
  );
  s = s.replaceAllMapped(
    RegExp(r'(?<=\S)\s+(?=[A-Za-z_][\w-]*\s*(?:-->>|->>|--x|-x|-->|->))'),
    (_) => '\n',
  );
  return s;
}

/// Splits [markdown] so every mermaid-class fence is its own segment.
List<WxMarkdownMermaidSegment> splitMarkdownByMermaidFences(String markdown) {
  if (markdown.isEmpty) return const [];

  final normalized = restoreFlattenedMermaidFences(
    markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
  );
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
