import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../copy/errors.dart';
import '../utils/anna_cookie.dart';
import '../utils/anna_device_download.dart';
import '../utils/book_download_capture.dart';
import '../widgets/wx_chrome.dart';

class AnnasBrowserOutcome {
  AnnasBrowserOutcome({required this.savedCount});
  final int savedCount;
}

/// 内置浏览器打开安娜的档案；剪切板中的 .epub 链交给问象服务端下载并写入问书目录。
class AnnasBrowserPage extends StatefulWidget {
  const AnnasBrowserPage({
    super.key,
    required this.api,
    this.initialQuery,
  });

  final WenxiangApi api;
  final String? initialQuery;

  @override
  State<AnnasBrowserPage> createState() => _AnnasBrowserPageState();
}

class _AnnasBrowserPageState extends State<AnnasBrowserPage> {
  static const _clipboardPollInterval = Duration(milliseconds: 450);

  late final WebViewController _controller;
  int _progress = 0;
  bool _pageLoading = true;
  int _savedCount = 0;
  String? _capturingLabel;
  BookDownloadProgress? _captureProgress;
  final Set<String> _inFlightUrls = {};
  String _currentUrl = '';
  String? _activeDownloadUrl;
  final WebViewCookieManager _cookieManager = WebViewCookieManager();
  Timer? _clipboardTimer;
  String? _lastSeenClipboard;
  String? _ignoreClipboardUntil;

  @override
  void initState() {
    super.initState();
    final startUrl = annasArchiveStartUrl(query: widget.initialQuery);
    _currentUrl = startUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(annaMobileChromeUa)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (!mounted) return;
            setState(() => _progress = p);
          },
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _pageLoading = true;
              _currentUrl = url;
            });
          },
          onPageFinished: (url) {
            if (!mounted) return;
            setState(() {
              _pageLoading = false;
              _currentUrl = url;
            });
          },
          onUrlChange: (change) {
            final url = change.url;
            if (url != null && url.isNotEmpty && mounted) {
              setState(() => _currentUrl = url);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(startUrl));
    unawaited(_seedClipboardBaseline());
    _clipboardTimer = Timer.periodic(_clipboardPollInterval, (_) {
      unawaited(_pollClipboardForDownload());
    });
  }

  @override
  void dispose() {
    _clipboardTimer?.cancel();
    super.dispose();
  }

  Future<void> _seedClipboardBaseline() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      _lastSeenClipboard = data?.text?.trim();
    } catch (_) {}
  }

  Future<void> _pollClipboardForDownload() async {
    if (!mounted) return;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text == null || text.isEmpty) return;
      if (text == _lastSeenClipboard) return;
      _lastSeenClipboard = text;
      final ignore = _ignoreClipboardUntil;
      if (ignore != null && text == ignore) {
        _ignoreClipboardUntil = null;
        return;
      }
      final uri = annaDownloadUriFromClipboard(text);
      if (uri == null) return;
      recordBookDownloadDiag(
        '剪切板检测到下载链',
        summary: 'url=${uri.toString()}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已检测到 .epub 链接，问象开始下载…'),
          duration: Duration(milliseconds: 1600),
        ),
      );
      await _requestServerDownload(uri);
    } catch (_) {}
  }

  Future<String?> _cookieHeaderFor(Uri downloadUri) async {
    final byName = <String, String>{};
    String? pageUrl = _currentUrl.trim().isNotEmpty ? _currentUrl.trim() : null;
    try {
      final cur = await _controller.currentUrl();
      if (cur != null && cur.isNotEmpty) pageUrl = cur;
    } catch (_) {}
    final candidates = annaCookieLookupUris(downloadUri, pageUrl: pageUrl);
    for (final uri in candidates) {
      try {
        for (final c in await _cookieManager.getCookies(domain: uri)) {
          byName[c.name] = c.value;
        }
      } catch (_) {}
    }
    try {
      final raw = await _controller.runJavaScriptReturningResult('document.cookie');
      final js = raw?.toString().trim() ?? '';
      if (js.isNotEmpty && js != 'null') {
        for (final part in js.split(';')) {
          final eq = part.indexOf('=');
          if (eq <= 0) continue;
          final name = part.substring(0, eq).trim();
          final value = part.substring(eq + 1).trim();
          if (name.isNotEmpty) byName.putIfAbsent(name, () => value);
        }
      }
    } catch (_) {}
    if (byName.isEmpty) return null;
    return byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> _copyText(String text, {String doneHint = '已复制'}) async {
    _ignoreClipboardUntil = text.trim();
    _lastSeenClipboard = text.trim();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(doneHint), duration: const Duration(milliseconds: 1200)),
    );
  }

  Future<void> _requestServerDownload(Uri uri) async {
    final url = bookDownloadUrlForServer(uri);
    if (_inFlightUrls.contains(url)) return;
    _inFlightUrls.add(url);
    final title = suggestedTitleFromDownloadUrl(uri);
    final cookieHeader = await _cookieHeaderFor(uri);
    var referer = _currentUrl.trim();
    try {
      final cur = await _controller.currentUrl();
      if (cur != null && cur.isNotEmpty) referer = cur;
    } catch (_) {}
    if (referer.isEmpty) referer = uri.origin;

    recordBookDownloadDiag(
      '问象服务端下载开始',
      summary:
          'url=$url · referer=$referer · cookies=${cookieNamesForLog(cookieHeader)}',
    );
    if (mounted) {
      setState(() {
        _capturingLabel = title ?? '电子书';
        _captureProgress = BookDownloadProgress(
          phase: 'queued',
          bytesReceived: 0,
          bytesTotal: null,
        );
        _activeDownloadUrl = url;
      });
    }
    try {
      final result = await widget.api.downloadBook(
        url: url,
        title: title,
        cookieHeader: cookieHeader,
        referer: referer,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _captureProgress = p);
        },
      );
      recordBookDownloadDiag(
        '问象已写入问书目录',
        summary: 'file=${result.filename} · path=${result.path} · bytes=${result.size}',
      );
      if (!mounted) return;
      setState(() => _savedCount += 1);
      final label = title != null && title.isNotEmpty ? title! : result.filename;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存《$label》到问书库')),
      );
    } catch (err) {
      if (!mounted) return;
      recordBookDownloadDiag(
        '问象下载入库失败：${err.toString()}',
        summary: 'url=$url · referer=$referer · cookies=${cookieNamesForLog(cookieHeader)}',
      );
      showWxFailureSnackBar(context, err, prefix: '保存失败：');
    } finally {
      _inFlightUrls.remove(url);
      if (mounted) {
        setState(() {
          _capturingLabel = null;
          _captureProgress = null;
          _activeDownloadUrl = null;
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _captureStatusLine() {
    final label = _capturingLabel ?? '电子书';
    final p = _captureProgress;
    if (p == null) return '正在下载「$label」…';
    if (p.phase == 'queued') return '已提交问象，排队下载…';
    if (p.phase == 'resolving') return '正在准备下载…';
    if (p.phase == 'uploading') return '正在写入问书库…';
    final received = p.bytesReceived;
    final total = p.bytesTotal;
    if (total != null && total > 0) {
      final pct = (received / total * 100).clamp(0, 100).toStringAsFixed(0);
      return '正在下载「$label」 $pct%（${_formatBytes(received)} / ${_formatBytes(total)}）';
    }
    if (received > 0) return '正在下载「$label」… 已接收 ${_formatBytes(received)}';
    return '正在下载「$label」…';
  }

  double? _captureProgressValue() {
    final p = _captureProgress;
    if (p == null) return null;
    if (p.phase == 'queued' || p.phase == 'resolving') return null;
    final total = p.bytesTotal;
    if (total == null || total <= 0) return null;
    return (p.bytesReceived / total).clamp(0.0, 1.0);
  }

  void _close() {
    Navigator.of(context).pop(AnnasBrowserOutcome(savedCount: _savedCount));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = _capturingLabel != null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        body: Column(
          children: [
            WxPageHeader(
              showMark: false,
              title: '安娜的档案',
              subtitle: _savedCount > 0 ? '已保存 $_savedCount 本' : '复制 .epub 链即可入库',
              onBack: _close,
              backTooltip: '返回',
              trailing: [
                IconButton(
                  tooltip: '刷新',
                  onPressed: () => _controller.reload(),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
              ],
            ),
            if (_pageLoading || _progress < 100)
              LinearProgressIndicator(
                minHeight: 2,
                value: _pageLoading && _progress == 0 ? null : _progress / 100,
              ),
            if (_activeDownloadUrl != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 0),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Wx.surface,
                    borderRadius: BorderRadius.circular(Wx.radius),
                    border: Border.all(color: Wx.hairline),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '下载地址',
                                style: theme.textTheme.labelSmall?.copyWith(color: Wx.muted),
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                _activeDownloadUrl!,
                                style: theme.textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '复制下载地址',
                          icon: const Icon(Icons.copy, size: 18),
                          onPressed: () => _copyText(_activeDownloadUrl!, doneHint: '已复制下载地址'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (busy)
              Padding(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LinearProgressIndicator(
                      minHeight: 3,
                      value: _captureProgressValue(),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _captureStatusLine(),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 6, Wx.inset, 6),
              child: Text(
                _currentUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint),
              ),
            ),
            const WxHairline(),
            Expanded(child: WebViewWidget(controller: _controller)),
            const WxHairline(),
            Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 12),
              child: Text(
                '网页内正常浏览；复制以 .epub 结尾的链接到剪切板，问象在本机服务端下载并写入问书目录（约每 0.45 秒检测，进度见上方）。',
                style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
