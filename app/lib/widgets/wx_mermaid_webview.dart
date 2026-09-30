import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../theme.dart';
import 'wx_chrome.dart';
import 'wx_rich_text.dart';

/// WebView skin for [mermaid.js] (full Mermaid syntax).
enum WxMermaidWebTheme {
  dark,
  light,
}

/// Renders Mermaid source with mermaid.js inside a fixed-height WebView.
class WxMermaidWebView extends StatefulWidget {
  const WxMermaidWebView({
    super.key,
    required this.code,
    this.theme = WxMermaidWebTheme.dark,
    this.monoStyle,
  });

  final String code;
  final WxMermaidWebTheme theme;
  final TextStyle? monoStyle;

  @override
  State<WxMermaidWebView> createState() => _WxMermaidWebViewState();
}

class _WxMermaidWebViewState extends State<WxMermaidWebView> {
  static const _minHeight = 140.0;
  static const _maxHeight = 3200.0;

  WebViewController? _controller;
  double _height = _minHeight;
  String? _error;
  var _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void didUpdateWidget(covariant WxMermaidWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code || oldWidget.theme != widget.theme) {
      _boot();
    }
  }

  Future<void> _boot() async {
    if (WebViewPlatform.instance == null) return;
    final gen = ++_loadGeneration;
    setState(() {
      _error = null;
      _height = _minHeight;
    });

    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'WxMermaidHeight',
        onMessageReceived: (message) {
          if (!mounted || gen != _loadGeneration) return;
          final raw = message.message;
          if (raw.startsWith('error:')) {
            setState(() => _error = raw.substring(6).trim());
            return;
          }
          final h = double.tryParse(raw);
          if (h == null || h <= 0) return;
          setState(() => _height = h.clamp(_minHeight, _maxHeight));
        },
      )
      ..loadHtmlString(
        _mermaidHtml(widget.code, widget.theme),
        baseUrl: 'https://cdn.jsdelivr.net',
      );

    if (!mounted || gen != _loadGeneration) return;
    setState(() => _controller = controller);
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Mermaid 渲染失败',
              style: TextStyle(
                color: Wx.muted,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFamilyFallback: Wx.fontFallback,
              ),
            ),
            if (_error!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: TextStyle(color: Wx.faint, fontSize: 12, fontFamilyFallback: Wx.fontFallback),
              ),
            ],
            const SizedBox(height: 8),
            WxFencedCode(
              code: widget.code,
              language: 'mermaid',
              framed: false,
              style: widget.monoStyle ?? const TextStyle(fontFamily: 'ui-monospace', fontSize: 13),
            ),
          ],
        ),
      );
    }

    final controller = _controller;
    if (controller == null) {
      if (WebViewPlatform.instance == null) {
        return SizedBox(
          height: _minHeight,
          child: Center(
            child: Text(
              'Mermaid 图表',
              style: TextStyle(color: Wx.muted, fontSize: 13, fontFamilyFallback: Wx.fontFallback),
            ),
          ),
        );
      }
      return SizedBox(
        height: _minHeight,
        child: const Center(child: WxLoading(size: 22)),
      );
    }

    return SizedBox(
      height: _height,
      child: WebViewWidget(controller: controller),
    );
  }
}

String _mermaidHtml(String code, WxMermaidWebTheme theme) {
  final b64 = base64Encode(utf8.encode(code));
  final mermaidTheme = theme == WxMermaidWebTheme.dark ? 'dark' : 'default';
  final bg = theme == WxMermaidWebTheme.dark ? '#1c1f24' : '#faf8f5';
  final fg = theme == WxMermaidWebTheme.dark ? '#d8d4cc' : '#2a2824';

  return '''
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
<script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
<style>
  html, body { margin: 0; padding: 0; background: $bg; color: $fg; overflow: hidden; }
  #wrap { padding: 10px 12px 14px; box-sizing: border-box; }
  .mermaid { background: transparent; }
  .mermaid svg { max-width: 100% !important; height: auto !important; }
</style>
</head>
<body>
<div id="wrap"><pre class="mermaid" id="diagram"></pre></div>
<script>
(function () {
  const src = atob('$b64');
  document.getElementById('diagram').textContent = src;
  mermaid.initialize({
    startOnLoad: false,
    theme: '$mermaidTheme',
    securityLevel: 'loose',
    fontFamily: 'system-ui, sans-serif',
  });
  function postHeight() {
    const h = Math.ceil(document.documentElement.scrollHeight || document.body.scrollHeight || 140);
    WxMermaidHeight.postMessage(String(h));
  }
  mermaid.run({ nodes: [document.getElementById('diagram')] })
    .then(function () {
      requestAnimationFrame(function () { requestAnimationFrame(postHeight); });
    })
    .catch(function (err) {
      WxMermaidHeight.postMessage('error:' + (err && err.message ? err.message : String(err)));
    });
})();
</script>
</body>
</html>
''';
}
