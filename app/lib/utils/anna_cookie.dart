/// Merge Cookie headers for Anna / DDoS-Guard (values never logged elsewhere).
String mergeAnnaCookieHeader(String? existing, Iterable<String> setCookieLines) {
  final byName = <String, String>{};
  void ingestPair(String pair) {
    final eq = pair.indexOf('=');
    if (eq <= 0) return;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (name.isNotEmpty) byName[name] = value;
  }

  final base = existing?.trim() ?? '';
  if (base.isNotEmpty) {
    for (final part in base.split(';')) {
      ingestPair(part.trim());
    }
  }
  for (final line in setCookieLines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final semi = trimmed.indexOf(';');
    ingestPair(semi >= 0 ? trimmed.substring(0, semi) : trimmed);
  }
  if (byName.isEmpty) return base;
  return byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
}

List<String> setCookieLinesFromHeaders(Map<String, String> headers) {
  final split = _headersSplitValues(headers);
  final fromList = split['set-cookie'];
  if (fromList != null && fromList.isNotEmpty) return fromList;
  final single = headers['set-cookie'];
  if (single == null || single.isEmpty) return const [];
  return [single];
}

Map<String, List<String>> _headersSplitValues(Map<String, String> headers) {
  final out = <String, List<String>>{};
  for (final entry in headers.entries) {
    final key = entry.key.toLowerCase();
    final values = entry.value.split(RegExp(r'\s*,\s*'));
    out.putIfAbsent(key, () => []).addAll(values);
  }
  return out;
}

String cookieNamesForLog(String? cookieHeader) {
  if (cookieHeader == null || cookieHeader.isEmpty) return '(none)';
  return cookieHeader
      .split(';')
      .map((p) => p.split('=').first.trim())
      .where((n) => n.isNotEmpty)
      .take(16)
      .join(', ');
}
