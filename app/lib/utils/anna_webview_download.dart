import 'dart:convert';
import 'dart:typed_data';

import 'package:webview_flutter/webview_flutter.dart';

import '../models.dart';
import 'anna_device_download.dart';

const _maxWebViewBytes = 120 * 1024 * 1024;

/// Uses the WebView cookie jar (credentials: include) when plain HTTP gets 403.
Future<Uint8List> downloadAnnaEpubViaWebView({
  required WebViewController controller,
  required Uri downloadUri,
  void Function(BookDownloadProgress progress)? onProgress,
}) async {
  onProgress?.call(
    BookDownloadProgress(phase: 'downloading', bytesReceived: 0, bytesTotal: null),
  );
  final urlJson = jsonEncode(downloadUri.toString());
  final js = '''
(async function() {
  try {
    const url = $urlJson;
    const resp = await fetch(url, { credentials: 'include', redirect: 'follow' });
    const ct = (resp.headers.get('content-type') || '').toLowerCase();
    if (!resp.ok) {
      return JSON.stringify({ ok: false, status: resp.status, ct: ct });
    }
    if (ct.startsWith('text/html')) {
      return JSON.stringify({ ok: false, status: 415, ct: ct });
    }
    const buf = await resp.arrayBuffer();
    if (buf.byteLength > $_maxWebViewBytes) {
      return JSON.stringify({ ok: false, status: 413, size: buf.byteLength });
    }
    const bytes = new Uint8Array(buf);
    const chunk = 32768;
    let binary = '';
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return JSON.stringify({ ok: true, b64: btoa(binary), size: buf.byteLength });
  } catch (e) {
    return JSON.stringify({ ok: false, status: 0, err: String(e) });
  }
})()
''';

  final raw = await controller
      .runJavaScriptReturningResult(js)
      .timeout(const Duration(minutes: 22));
  final text = _unwrapJsJson(raw);
  final map = jsonDecode(text) as Map<String, dynamic>;
  if (map['ok'] != true) {
    final status = map['status'];
    final st = status is int ? status : int.tryParse('$status') ?? 0;
    if (st == 415) {
      throw Exception('下载到了网页而不是 epub（请先在浏览器完成验证或换一本）');
    }
    if (st == 413) {
      throw Exception('文件过大，WebView 直载超过 120MB 限制');
    }
    throw Exception('WebView 下载失败 (${st == 0 ? map['err'] ?? 'unknown' : st})');
  }

  final b64 = (map['b64'] ?? '').toString();
  if (b64.isEmpty) throw Exception('WebView 下载返回空内容');
  final bytes = base64Decode(b64);
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
}

String _unwrapJsJson(Object? raw) {
  var s = raw?.toString() ?? '';
  if (s == 'null' || s.isEmpty) return '{}';
  if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
    try {
      return jsonDecode(s) as String;
    } catch (_) {
      s = s.substring(1, s.length - 1);
    }
  }
  return s;
}
