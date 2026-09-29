/// 判断 WebView 里出现的 URL 是否应交给问象服务端下载到 workspace/books。
bool shouldCaptureBookDownloadUrl(Uri uri, {String? mimeType}) {
  final mime = (mimeType ?? '').toLowerCase();
  if (mime.contains('epub') ||
      mime == 'application/zip' ||
      mime == 'application/x-zip-compressed') {
    return true;
  }

  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();

  if (path.endsWith('.epub') || path.endsWith('.epub.zip')) {
    return true;
  }

  if (path.endsWith('/get.php') || path.contains('/get.php')) {
    final md5 = uri.queryParameters['md5'] ?? '';
    if (RegExp(r'^[a-f0-9]{32}$').hasMatch(md5)) return true;
  }
  if (path.endsWith('/ads.php') || path.contains('/ads.php')) {
    final md5 = uri.queryParameters['md5'] ?? '';
    if (RegExp(r'^[a-f0-9]{32}$').hasMatch(md5)) return true;
  }

  if (host.contains('libgen') && (path.contains('get.php') || path.contains('ads.php'))) {
    return true;
  }

  if (host.endsWith('archive.org') &&
      (path.contains('/download/') || path.endsWith('.epub'))) {
    return true;
  }

  if (host.contains('annas-archive') &&
      (path.contains('/fast_download/') || path.contains('/slow_download/'))) {
    return true;
  }

  return false;
}

String annasArchiveStartUrl({String? query}) {
  const base = 'https://annas-archive.gl';
  final q = query?.trim() ?? '';
  if (q.isEmpty) return base;
  return '$base/search?q=${Uri.encodeComponent(q)}&ext=epub';
}

/// 交给服务端前统一成 LibGen ads.php，避免 Anna 403 或 get.php 一次性 key 失效。
String bookDownloadUrlForServer(Uri uri) {
  final md5 = uri.queryParameters['md5'] ?? '';
  final hasMd5 = RegExp(r'^[a-f0-9]{32}$').hasMatch(md5);
  final host = uri.host.toLowerCase();
  final path = uri.path.toLowerCase();

  if (hasMd5 &&
      (host.contains('libgen') || host.contains('library.lol')) &&
      path.contains('get.php')) {
    return 'https://libgen.li/ads.php?md5=$md5';
  }

  if (host.contains('annas-archive') &&
      (path.contains('/fast_download/') || path.contains('/slow_download/'))) {
    final fromPath = _md5FromAnnasDownloadPath(path);
    if (fromPath != null) {
      return 'https://libgen.li/ads.php?md5=$fromPath';
    }
  }

  return uri.toString();
}

String? _md5FromAnnasDownloadPath(String path) {
  final slow = RegExp(r'/slow_download/\d+/([a-f0-9]{32})', caseSensitive: false);
  final slowMatch = slow.firstMatch(path);
  if (slowMatch != null) return slowMatch.group(1)!.toLowerCase();

  final fast = RegExp(
    r'/fast_download/(?:\d+/)?([a-f0-9]{32})',
    caseSensitive: false,
  );
  final fastMatch = fast.firstMatch(path);
  if (fastMatch != null) return fastMatch.group(1)!.toLowerCase();

  return null;
}

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
