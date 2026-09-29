import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/book_download_capture.dart';
import '../widgets/wx_chrome.dart';

class AnnasBrowserOutcome {
  AnnasBrowserOutcome({required this.savedCount});
  final int savedCount;
}

/// 内置浏览器打开安娜的档案；拦截 epub / LibGen 等直链，由服务端写入 workspace/books。
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
  static const _mobileChromeUa =
      'Mozilla/5.0 (Linux; Android 13; Mobile) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  late final WebViewController _controller;
  int _progress = 0;
  bool _pageLoading = true;
  int _savedCount = 0;
  String? _capturingLabel;
  final Set<String> _inFlightUrls = {};
  String _currentUrl = '';

  @override
  void initState() {
    super.initState();
    final startUrl = annasArchiveStartUrl(query: widget.initialQuery);
    _currentUrl = startUrl;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_mobileChromeUa)
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
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri != null && shouldCaptureBookDownloadUrl(uri)) {
              unawaited(_captureAndDownload(uri));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
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
  }

  Future<void> _captureAndDownload(Uri uri) async {
    final url = uri.toString();
    if (_inFlightUrls.contains(url)) return;
    _inFlightUrls.add(url);
    final title = suggestedTitleFromDownloadUrl(uri);
    if (mounted) {
      setState(() => _capturingLabel = title ?? '电子书');
    }
    try {
      await widget.api.downloadBook(url: url, title: title);
      if (!mounted) return;
      setState(() => _savedCount += 1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            title != null && title.isNotEmpty ? '已保存《$title》到问书库' : '已保存到问书库',
          ),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$err')),
      );
    } finally {
      _inFlightUrls.remove(url);
      if (mounted) setState(() => _capturingLabel = null);
    }
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
              subtitle: _savedCount > 0 ? '已保存 $_savedCount 本' : '站内点下载，问象自动入库',
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
            if (busy)
              Padding(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 0),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '正在保存「$_capturingLabel」…',
                        style: theme.textTheme.bodySmall,
                      ),
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
                '在网页里正常搜索、点下载即可；检测到 epub / LibGen 链接时会写入本机 workspace 的 books 目录，无需再点「下载到手机」。',
                style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
