/// Adapts common Mermaid.js / ChatGPT output for [flutter_mermaid] parsers.
String normalizeMermaidForFlutter(String source) {
  var text = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.isEmpty) return text;

  final lines = text.split('\n');
  final firstLower = lines.first.trim().toLowerCase();

  if (firstLower.startsWith('pie')) {
    text = _normalizePieHeader(text);
  } else if (firstLower == 'radar' || firstLower.startsWith('radar ')) {
    text = _normalizeRadarShorthand(text);
  } else if (firstLower == 'kanban' || firstLower.startsWith('kanban ')) {
    text = _normalizeKanbanSections(text);
  } else if (firstLower.startsWith('graph ') || firstLower.startsWith('flowchart ')) {
    text = _normalizeFlowchartSubgraphs(text);
  } else if (firstLower.startsWith('sequencediagram')) {
    text = _normalizeSequence(text);
  }

  return text;
}

String _normalizePieHeader(String text) {
  final lines = text.split('\n');
  if (lines.isEmpty) return text;
  final first = lines.first.trim();
  final m = RegExp(r'^pie(?:\s+showdata)?\s+title\s+(.+)$', caseSensitive: false).firstMatch(first);
  if (m == null) return text;
  final showData = first.toLowerCase().contains('showdata');
  lines[0] = showData ? 'pie showData' : 'pie';
  lines.insert(1, 'title ${m.group(1)!.trim()}');
  return lines.join('\n');
}

String _normalizeRadarShorthand(String text) {
  final lines = text.split('\n');
  if (lines.isEmpty) return text;

  String? title;
  final entries = <({String label, double value})>[];
  final out = <String>['radar-beta'];

  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.isEmpty) continue;
    final lower = trimmed.toLowerCase();
    if (lower == 'radar' || lower == 'radar-beta') continue;
    if (lower.startsWith('title ')) {
      title = trimmed.substring(6).trim();
      continue;
    }
    final slice = RegExp(r'^["\u201c](.+?)["\u201d]\s*:\s*([0-9.]+)\s*$').firstMatch(trimmed);
    if (slice != null) {
      final v = double.tryParse(slice.group(2)!);
      if (v != null) entries.add((label: slice.group(1)!.trim(), value: v));
      continue;
    }
    // Already radar-beta native syntax — pass through remainder.
    return text.replaceFirst(RegExp(r'^radar\b', caseSensitive: false), 'radar-beta');
  }

  if (entries.isEmpty) {
    return text.replaceFirst(RegExp(r'^radar\b', caseSensitive: false), 'radar-beta');
  }

  if (title != null && title.isNotEmpty) out.add('title $title');
  final axisLabels = entries.map((e) => e.label).toList();
  out.add('axis ${axisLabels.join(', ')}');
  final values = entries.map((e) => e.value.toString()).join(', ');
  out.add('curve 数据{$values}');
  return out.join('\n');
}

String _normalizeKanbanSections(String text) {
  final lines = text.split('\n');
  if (lines.isEmpty) return text;

  final out = <String>[];
  String? title;
  var colIndex = 0;
  var taskIndex = 0;
  String? currentColId;

  for (final raw in lines) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final lower = trimmed.toLowerCase();
    if (lower == 'kanban') {
      out.add('kanban');
      continue;
    }
    if (lower.startsWith('title ')) {
      title = trimmed.substring(6).trim();
      continue;
    }

    final section = RegExp(r'^section\s+(.+)$', caseSensitive: false).firstMatch(trimmed);
    if (section != null) {
      colIndex++;
      taskIndex = 0;
      final label = section.group(1)!.trim();
      currentColId = 'col$colIndex';
      out.add('$currentColId[$label]');
      continue;
    }

    // Mermaid.js kanban: tasks under section are usually indented plain text.
    final isTaskLine = raw.startsWith('  ') && !trimmed.contains('[');
    if (isTaskLine && currentColId != null) {
      taskIndex++;
      out.add('    t$colIndex$taskIndex[$trimmed]');
      continue;
    }

    // flutter_mermaid native: columnId[Title] or indented taskId[Desc]
    out.add(raw);
  }

  if (title != null && title.isNotEmpty) {
    final kanbanIdx = out.indexOf('kanban');
    out.insert(kanbanIdx + 1, 'title $title');
  }

  return out.join('\n');
}

String _normalizeFlowchartSubgraphs(String text) {
  final lines = text.split('\n');
  final out = <String>[];
  var sg = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    if (!trimmed.toLowerCase().startsWith('subgraph ')) {
      out.add(line);
      continue;
    }
    final rest = trimmed.substring(9).trim();
    if (RegExp(r'^\w+\s*\[').hasMatch(rest)) {
      out.add(line);
      continue;
    }
    sg++;
    final label = rest.replaceAll('"', '');
    out.add('subgraph sg$sg[$label]');
  }
  return out.join('\n');
}

String _normalizeSequence(String text) {
  final lines = text.split('\n');
  final out = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('note ')) continue;
    out.add(line);
  }
  return out.join('\n');
}
