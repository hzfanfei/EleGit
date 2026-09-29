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

/// Candidate URIs for [WebViewCookieManager.getCookies] on Anna hosts.
Iterable<Uri> annaCookieLookupUris(Uri downloadUri, {String? pageUrl}) {
  final host = downloadUri.host.toLowerCase();
  final out = <Uri>{};
  out.add(downloadUri);
  out.add(Uri.parse('${downloadUri.scheme}://$host/'));
  out.add(Uri.parse('${downloadUri.scheme}://$host'));
  if (host.startsWith('www.')) {
    out.add(Uri.parse('${downloadUri.scheme}://${host.substring(4)}/'));
  }
  final md5 = annaMd5FromPath(downloadUri.path);
  if (md5 != null) {
    out.add(Uri.parse('${downloadUri.origin}/md5/$md5'));
  }
  final page = pageUrl?.trim() ?? '';
  if (page.isNotEmpty) {
    if (Uri.tryParse(page) case final Uri u) out.add(u);
  }
  return out;
}

/// Supports `/slow_download/{md5}/…` and `/slow_download/0/{md5}/…`.
String? annaMd5FromPath(String path) {
  var match = RegExp(
    r'/slow_download/(?:\d+/)?([a-f0-9]{32})(?:/|$)',
    caseSensitive: false,
  ).firstMatch(path);
  if (match != null) return match.group(1)!.toLowerCase();
  match = RegExp(
    r'/fast_download/(?:\d+/)?([a-f0-9]{32})(?:/|$)',
    caseSensitive: false,
  ).firstMatch(path);
  return match?.group(1)?.toLowerCase();
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
