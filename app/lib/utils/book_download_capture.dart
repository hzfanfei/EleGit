bool _isAnnasHost(String host) => host.contains('annas-archive');

/// Anna slow mirror gate — must load in WebView before HTTP/WebView binary fetch.
bool isAnnaSlowDownloadGateUri(Uri uri) {
  if (!_isAnnasHost(uri.host.toLowerCase())) return false;
  return uri.path.toLowerCase().contains('/slow_download/');
}

/// 是否为本机应入库的安娜下载链（不含 slow 等待页；导航劫持已停用，仅作工具函数）。
bool shouldCaptureBookDownloadUrl(Uri uri, {String? mimeType}) {
  return _annasBookDownloadUri(uri, mimeType: mimeType, includeSlowGate: false);
}

/// 剪切板：仅 path 以 `.epub` 结尾时触发入库。
bool shouldCaptureBookDownloadFromClipboard(Uri uri) {
  if (!uri.hasScheme || uri.host.isEmpty) return false;
  return uri.path.toLowerCase().endsWith('.epub');
}

bool _annasBookDownloadUri(
  Uri uri, {
  String? mimeType,
  required bool includeSlowGate,
}) {
  final host = uri.host.toLowerCase();
  if (!_isAnnasHost(host)) return false;

  if (isAnnaSlowDownloadGateUri(uri)) return includeSlowGate;

  final mime = (mimeType ?? '').toLowerCase();
  if (mime.contains('epub') ||
      mime == 'application/zip' ||
      mime == 'application/x-zip-compressed') {
    return true;
  }

  final path = uri.path.toLowerCase();
  if (path.endsWith('.epub') || path.endsWith('.epub.zip')) return true;
  if (path.contains('/fast_download/')) return true;
  if (path.contains('/slow_download/')) return includeSlowGate;
  return false;
}

final _clipboardHttpUrl = RegExp(r'https?://[^\s]+', caseSensitive: false);

String _trimUrlToken(String url) {
  var s = url.trim();
  while (s.isNotEmpty && ',.;)]}'.contains(s[s.length - 1])) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 从剪切板文本解析第一条以 `.epub` 结尾的下载 URL。
Uri? annaDownloadUriFromClipboard(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  Uri? pick(String candidate) {
    final uri = Uri.tryParse(_trimUrlToken(candidate));
    if (uri != null && shouldCaptureBookDownloadFromClipboard(uri)) return uri;
    return null;
  }
  final direct = pick(text);
  if (direct != null) return direct;
  for (final match in _clipboardHttpUrl.allMatches(text)) {
    final found = pick(match.group(0)!);
    if (found != null) return found;
  }
  return null;
}

String annasArchiveStartUrl({String? query}) {
  const base = 'https://annas-archive.gl';
  final q = query?.trim() ?? '';
  if (q.isEmpty) return base;
  return '$base/search?q=${Uri.encodeComponent(q)}&ext=epub';
}

/// 原样交给服务端（安娜 fast/slow_download 等）。
String bookDownloadUrlForServer(Uri uri) => uri.toString();

String? suggestedTitleFromDownloadUrl(Uri uri) {
  final path = uri.path;
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return null;
  final segment = parts.last;
  var name = Uri.decodeComponent(segment);
  name = name.replaceAll(RegExp(r'\.epub(\.zip)?$', caseSensitive: false), '');
  if (name.isEmpty || name.contains('.php')) return null;
  return name;
}
