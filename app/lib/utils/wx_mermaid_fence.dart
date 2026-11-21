import 'markdown_syntax.dart';

class WxMarkdownSegment {
  const WxMarkdownSegment.prose(this.prose)
      : code = null,
        language = '',
        closed = true,
        isMermaid = false;

  const WxMarkdownSegment.fenced(
    this.code,
    this.language, {
    required this.closed,
    required this.isMermaid,
  }) : prose = null;

  final String? prose;
  final String? code;
  final String language;
  final bool closed;
  final bool isMermaid;
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
final _gluedMermaidStart = RegExp(r'(?<![\\`])```(?!`)([^`\n]+)$');

/// ACP text deltas sometimes arrive with newlines removed, so a fence shows up
/// as ` ```mermaidflowchart TD A-->B ``` ` and never becomes a diagram.
String restoreFlattenedMermaidFences(String input) {
  if (!input.contains('```')) return input;
  final scanner = MarkdownLiteralScanner();
  final lines = <String>[];
  for (final line in input.split('\n')) {
    final open = scanner.fence;
    final trimmed = line.trimLeft();
    if (open != null &&
        open.marker == '```' &&
        isMermaidFenceLang(open.info) &&
        trimmed.startsWith('```') &&
        !trimmed.startsWith('````') &&
        trimmed.substring(3).trim().isNotEmpty) {
      // The closing marker and the next paragraph can share a line.
      scanner.consume('```');
      lines.add('```');
      lines.add(_reflowMermaidLine(trimmed.substring(3).trimLeft(), scanner));
    } else if (scanner.consume(line) || !line.contains('```')) {
      lines.add(line);
    } else {
      lines.add(_reflowMermaidLine(line, scanner));
    }
  }
  return lines.join('\n');
}

String _reflowMermaidLine(String line, MarkdownLiteralScanner scanner) {
  final out = StringBuffer();
  var cursor = 0;
  var protectedEnd = 0;
  for (final match in markdownProtectedInline.allMatches(line)) {
    protectedEnd = match.end;
    final span = match[0]!;
    if (!span.startsWith('```') || span.startsWith('````')) continue;
    final diagram = _reflowMermaidInner(span.substring(3, span.length - 3));
    if (diagram == null) continue;
    out.write(line.substring(cursor, match.start));
    if (match.start > cursor) out.writeln();
    out.write(diagram);
    if (match.end < line.length) out.writeln();
    cursor = match.end;
  }
  final glued = _gluedMermaidStart.firstMatch(line);
  if (glued != null &&
      glued.start >= protectedEnd &&
      isMermaidFenceLang(glued[1]!)) {
    out.write(line.substring(cursor, glued.start));
    if (glued.start > cursor) out.writeln();
    final opening = glued[0]!;
    scanner.consume(opening);
    out.write(opening);
  } else {
    out.write(line.substring(cursor));
  }
  return out.toString();
}

String? _reflowMermaidInner(String inner) {
  final trimmed = inner.trim();
  if (trimmed.isEmpty) return null;
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
    if (lower == 'pie') {
      var pieRest = rest;
      var header = 'pie';
      final showData = RegExp(r'^\s*showData', caseSensitive: false).firstMatch(pieRest);
      if (showData != null) {
        header = 'pie showData';
        pieRest = pieRest.substring(showData.end);
      }
      return _DiagramHead('pie', header, pieRest.trimLeft());
    }
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
  if (lower == 'classdiagram') return _splitClassStatements(body);
  if (lower == 'erdiagram') return _splitErStatements(body);
  if (lower == 'pie') return _splitPieStatements(body);
  return body.trim();
}

String _applyCuts(String source, List<int> cuts) {
  final unique = cuts.where((cut) => cut > 0 && cut < source.length && source[cut - 1] != '\n').toSet().toList()
    ..sort((a, b) => b.compareTo(a));
  var out = source;
  for (final cut in unique) {
    final left = out.substring(0, cut).replaceAll(RegExp(r'[ \t]+$'), '');
    out = '$left\n${out.substring(cut)}';
  }
  return out;
}

int _peelLabeledName(String source, int index, String name, {required bool entityUpper}) {
  final peeled = entityUpper
      ? RegExp(r'^(.*[a-z])([A-Z][A-Z0-9_]*)$').firstMatch(name)
      : RegExp(r'^(.*[a-z])([A-Z][A-Za-z0-9_]*)$').firstMatch(name);
  if (peeled == null || !RegExp(r':\s*$').hasMatch(source.substring(0, index))) return index;
  return index + peeled.group(1)!.length;
}

List<int> _classRelationCuts(String source) {
  final re = RegExp(
    r'([A-Za-z_][A-Za-z0-9_]*)\s*(?:<\|--|<\|\.\.|\*--|o--|-->|<--|==>|\.\.>|\.\.|--)',
  );
  return [
    for (final match in re.allMatches(source))
      _peelLabeledName(source, match.start, match.group(1)!, entityUpper: false),
  ];
}

List<int> _erRelationCuts(String source) {
  final re = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*(?:\|\||\|o|\}o|\}\|)(?:--|\.\.)');
  return [
    for (final match in re.allMatches(source))
      _peelLabeledName(source, match.start, match.group(1)!, entityUpper: true),
  ];
}

List<int> _erBlockCuts(String source) {
  final cuts = <int>[];
  for (final match in RegExp(r'(?<![o|])\{').allMatches(source)) {
    var index = match.start - 1;
    while (index >= 0 && RegExp(r'\s').hasMatch(source[index])) {
      index -= 1;
    }
    final end = index + 1;
    while (index >= 0 && RegExp(r'[A-Za-z0-9_]').hasMatch(source[index])) {
      index -= 1;
    }
    final start = index + 1;
    if (start >= end) continue;
    final name = source.substring(start, end);
    final peeled = RegExp(r'^(.*[a-z])([A-Z][A-Z0-9_]*)$').firstMatch(name);
    var cut = start;
    if (peeled != null && RegExp(r':\s*$').hasMatch(source.substring(0, start))) {
      cut = start + peeled.group(1)!.length;
    }
    cuts.add(cut);
  }
  return cuts;
}

String _splitClassStatements(String body) {
  var s = body.trim();
  if (s.isEmpty) return s;
  s = s.replaceAllMapped(RegExp(r'(?<=\})(?=[A-Za-z_][A-Za-z0-9_])'), (_) => '\n');
  s = s.replaceAllMapped(RegExp(r'\s+(?=class\b)'), (_) => '\n');
  s = s.replaceAllMapped(RegExp(r'\{(?!\n)'), (_) => '{\n');
  s = s.replaceAllMapped(RegExp(r'\s*(?=})'), (_) => '\n');
  s = s.replaceAllMapped(
    RegExp(r'(?:(?<=\S)\s*|\s+)(?=(?:[+\#~]|(?<![-|<*o.])-(?![->.])))'),
    (_) => '\n',
  );
  s = _applyCuts(s, _classRelationCuts(s));
  return s.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
}

String _splitErStatements(String body) {
  var s = body.trim();
  if (s.isEmpty) return s;
  s = s.replaceAllMapped(
    RegExp(
      r'\b(string|int|integer|float|double|bool|boolean|date|datetime|number|varchar|char)(?=\S)',
      caseSensitive: false,
    ),
    (m) => '${m[1]} ',
  );
  s = _applyCuts(s, _erRelationCuts(s));
  s = _applyCuts(s, _erBlockCuts(s));
  s = s.replaceAllMapped(RegExp(r'(?<![o|])\{(?!\n)'), (_) => '{\n');
  s = s.replaceAllMapped(RegExp(r'\s*\}(?!\s*[|o])'), (_) => '\n}');
  s = s.replaceAllMapped(RegExp(r'(?<=\})(?=[A-Za-z_][A-Za-z0-9_])'), (_) => '\n');
  s = s.replaceAllMapped(
    RegExp(
      r'\s+(?=(?:string|int|integer|float|double|bool|boolean|date|datetime|number|varchar|char)\b)',
      caseSensitive: false,
    ),
    (_) => '\n',
  );
  return s.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
}

String _splitPieStatements(String body) {
  var s = body.trim();
  if (s.isEmpty) return s;
  s = s.replaceAllMapped(RegExp(r'\btitle(?=[^\s:])', caseSensitive: false), (_) => 'title ');
  s = s.replaceAllMapped(RegExp(r'\s+(?=title\b)', caseSensitive: false), (_) => '\n');
  s = s.replaceAllMapped(RegExp(r'(?:\s+|(?<=\S))(?="[^"]*"\s*:)'), (_) => '\n');
  return s.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
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

/// Extracts standalone code fences before handing prose to GptMarkdown.
List<WxMarkdownSegment> splitMarkdownFences(
  String markdown, {
  bool includeCode = true,
}) {
  if (markdown.isEmpty) return const [];
  if (!markdown.contains('```') && !markdown.contains('~~~')) {
    return [WxMarkdownSegment.prose(markdown)];
  }
  final text = restoreFlattenedMermaidFences(
    markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
  );
  final segments = <WxMarkdownSegment>[];
  final scanner = MarkdownLiteralScanner();
  var proseStart = 0;
  var fenceStart = 0;
  var codeStart = 0;

  void addProse(int end) {
    final prose = text.substring(proseStart, end);
    if (prose.trim().isNotEmpty) segments.add(WxMarkdownSegment.prose(prose));
  }

  void addFence(MarkdownCodeFence open, int codeEnd, int end,
      {required bool closed}) {
    final code = text.substring(codeStart, codeEnd);
    final mermaid = isMermaidFenceLang(open.info) ||
        (open.info.isEmpty && looksLikeMermaidSource(code));
    if (!includeCode && !mermaid) return;
    addProse(fenceStart);
    segments.add(WxMarkdownSegment.fenced(
      mermaid ? normalizeMermaidFenceSource(open.info, code) : code,
      open.info,
      closed: closed,
      isMermaid: mermaid,
    ));
    proseStart = end;
  }

  var cursor = 0;
  while (cursor < text.length) {
    final newline = text.indexOf('\n', cursor);
    final lineEnd = newline == -1 ? text.length : newline;
    final next = newline == -1 ? text.length : newline + 1;
    final open = scanner.fence;
    scanner.consume(text.substring(cursor, lineEnd));
    if (open == null && scanner.fence != null) {
      fenceStart = cursor;
      codeStart = next;
    } else if (open != null && scanner.fence == null) {
      final codeEnd = cursor == codeStart ? cursor : cursor - 1;
      addFence(open, codeEnd, next, closed: true);
    }
    cursor = next;
  }
  if (scanner.fence case final open?) {
    addFence(open, text.length, text.length, closed: false);
  }
  addProse(text.length);
  return segments;
}
