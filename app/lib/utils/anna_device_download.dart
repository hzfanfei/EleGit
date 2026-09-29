import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models.dart';
import 'anna_cookie.dart';

const annaMobileChromeUa =
    'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

const _maxAnnaBytes = 200 * 1024 * 1024;

/// Thrown when HTTP download fails; [cookieHeader] reflects merged cookies tried.
class AnnaHttpDownloadException implements Exception {
  AnnaHttpDownloadException({
    required this.statusCode,
    required this.cookieHeader,
    required this.referer,
    this.bodySnippet = '',
  });

  final int statusCode;
  final String? cookieHeader;
  final String referer;
  final String bodySnippet;

  @override
  String toString() => '下载失败 ($statusCode)';
}

/// Anna / DDoS-Guard cookies are tied to the phone IP — download on device, then upload.
String? annaMd5FromDownloadUrl(Uri uri) {
  final path = uri.path;
  var match = RegExp(
    r'/slow_download/\d+/([a-f0-9]{32})',
    caseSensitive: false,
  ).firstMatch(path);
  if (match != null) return match.group(1)!.toLowerCase();
  match = RegExp(
    r'/fast_download/(?:\d+/)?([a-f0-9]{32})',
    caseSensitive: false,
  ).firstMatch(path);
  return match?.group(1)?.toLowerCase();
}

/// Browser-like GET headers. Do not send Sec-Fetch-Mode: cors — Anna / DDoS-Guard
/// often returns 403 for non-navigation fetches.
Map<String, String> annaFetchHeaders({
  required String userAgent,
  String? cookieHeader,
  String? referer,
}) {
  final ref = referer?.trim() ?? '';
  return {
    'User-Agent': userAgent,
    'Accept': '*/*',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
    if (ref.isNotEmpty) 'Referer': ref,
    if (cookieHeader != null && cookieHeader.isNotEmpty) 'Cookie': cookieHeader,
  };
}

Future<String?> _warmAnnaMd5Page(
  Uri downloadUri, {
  required String userAgent,
  String? cookieHeader,
  String? referer,
}) async {
  final md5 = annaMd5FromDownloadUrl(downloadUri);
  if (md5 == null) return cookieHeader;
  final md5Uri = Uri.parse('${downloadUri.origin}/md5/$md5');
  final res = await http
      .get(
        md5Uri,
        headers: annaFetchHeaders(
          userAgent: userAgent,
          cookieHeader: cookieHeader,
          referer: referer ?? md5Uri.toString(),
        ),
      )
      .timeout(const Duration(seconds: 45));
  return mergeAnnaCookieHeader(
    cookieHeader,
    setCookieLinesFromHeaders(res.headers),
  );
}

Future<Uint8List> downloadAnnaEpubOnDevice({
  required Uri downloadUri,
  required String userAgent,
  String? cookieHeader,
  String? referer,
  void Function(BookDownloadProgress progress)? onProgress,
}) async {
  final md5 = annaMd5FromDownloadUrl(downloadUri);
  final md5Referer =
      md5 != null ? '${downloadUri.origin}/md5/$md5' : (referer ?? downloadUri.origin);
  final effectiveReferer =
      (referer != null && referer.contains('/md5/')) ? referer : md5Referer;

  var cookies = await _warmAnnaMd5Page(
    downloadUri,
    userAgent: userAgent,
    cookieHeader: cookieHeader,
    referer: effectiveReferer,
  );

  onProgress?.call(
    BookDownloadProgress(phase: 'downloading', bytesReceived: 0, bytesTotal: null),
  );

  final client = http.Client();
  try {
    Future<http.StreamedResponse> sendOnce(String? cookiesNow) {
      final request = http.Request('GET', downloadUri);
      request.headers.addAll(
        annaFetchHeaders(
          userAgent: userAgent,
          cookieHeader: cookiesNow,
          referer: effectiveReferer,
        ),
      );
      return client.send(request).timeout(const Duration(minutes: 20));
    }

    var response = await sendOnce(cookies);
    if (response.statusCode == 403) {
      cookies = mergeAnnaCookieHeader(
        cookies,
        setCookieLinesFromHeaders(response.headers),
      );
      cookies = await _warmAnnaMd5Page(
        downloadUri,
        userAgent: userAgent,
        cookieHeader: cookies,
        referer: effectiveReferer,
      );
      response = await sendOnce(cookies);
    }

    if (response.statusCode != 200) {
      var snippet = '';
      try {
        snippet = (await response.stream.bytesToString())
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (snippet.length > 160) snippet = '${snippet.substring(0, 160)}…';
      } catch (_) {}
      throw AnnaHttpDownloadException(
        statusCode: response.statusCode,
        cookieHeader: cookies,
        referer: effectiveReferer,
        bodySnippet: snippet,
      );
    }

    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.startsWith('text/html')) {
      throw Exception('下载到了网页而不是 epub（请先在浏览器完成验证或换一本）');
    }

    final totalHeader = response.headers['content-length'];
    final bytesTotal = totalHeader != null ? int.tryParse(totalHeader) : null;
    final builder = BytesBuilder(copy: false);
    var received = 0;
    var lastReport = 0;

    await for (final chunk in response.stream) {
      received += chunk.length;
      if (received > _maxAnnaBytes) {
        throw Exception('文件过大，已超过 200MB 限制');
      }
      builder.add(chunk);
      if (received - lastReport >= 256 * 1024) {
        lastReport = received;
        onProgress?.call(
          BookDownloadProgress(
            phase: 'downloading',
            bytesReceived: received,
            bytesTotal: bytesTotal,
          ),
        );
      }
    }

    final bytes = builder.takeBytes();
    if (bytes.length < 4 ||
        bytes[0] != 0x50 ||
        bytes[1] != 0x4b ||
        bytes[2] != 0x03 ||
        bytes[3] != 0x04) {
      throw Exception('下载内容不是合法的 epub 文件');
    }

    onProgress?.call(
      BookDownloadProgress(
        phase: 'downloading',
        bytesReceived: bytes.length,
        bytesTotal: bytes.length,
      ),
    );
    return bytes;
  } finally {
    client.close();
  }
}
