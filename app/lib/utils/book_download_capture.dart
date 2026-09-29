bool _isAnnasHost(String host) => host.contains('annas-archive');

/// Anna slow mirror gate — must load in WebView before HTTP/WebView binary fetch.
bool isAnnaSlowDownloadGateUri(Uri uri) {
  if (!_isAnnasHost(uri.host.toLowerCase())) return false;
  return uri.path.toLowerCase().contains('/slow_download/');
}

/// 判断 WebView 里出现的 URL 是否应交给问象服务端下载到 workspace/books（仅安娜域名）。
bool shouldCaptureBookDownloadUrl(Uri uri, {String? mimeType}) {
  final host = uri.host.toLowerCase();
  if (!_isAnnasHost(host)) return false;

  if (isAnnaSlowDownloadGateUri(uri)) return false;

  final mime = (mimeType ?? '').toLowerCase();
  if (mime.contains('epub') ||
      mime == 'application/zip' ||
      mime == 'application/x-zip-compressed') {
    return true;
  }

  final path = uri.path.toLowerCase();
  if (path.endsWith('.epub') || path.endsWith('.epub.zip')) return true;
  if (path.contains('/fast_download/')) return true;
  return false;
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
