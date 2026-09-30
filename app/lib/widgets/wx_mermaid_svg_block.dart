import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/wx_mermaid_cache.dart';
import 'wx_rich_text.dart';

/// Server-rendered Mermaid (SVG via companion `/v1/mermaid/render`).
class WxMermaidSvgBlock extends StatefulWidget {
  const WxMermaidSvgBlock({
    super.key,
    required this.code,
    required this.closed,
    required this.api,
    required this.serverTheme,
    this.backgroundColor = 'transparent',
    this.shellColor,
    this.monoStyle,
  });

  final String code;
  final bool closed;
  final WenxiangApi? api;
  final String serverTheme;
  final String backgroundColor;
  final Color? shellColor;
  final TextStyle? monoStyle;

  @override
  State<WxMermaidSvgBlock> createState() => _WxMermaidSvgBlockState();
}

class _WxMermaidSvgBlockState extends State<WxMermaidSvgBlock> {
  Uint8List? _png;
  String? _svg;
  String? _error;
  var _requestGen = 0;

  String get _cacheKey => WxMermaidCache.key(
        code: widget.code,
        theme: widget.serverTheme,
        backgroundColor: widget.backgroundColor,
      );

  @override
  void initState() {
    super.initState();
    _bindDiagram(notify: false);
  }

  @override
  void didUpdateWidget(covariant WxMermaidSvgBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code ||
        oldWidget.closed != widget.closed ||
        oldWidget.serverTheme != widget.serverTheme ||
        oldWidget.backgroundColor != widget.backgroundColor ||
        oldWidget.api != widget.api) {
      _bindDiagram(notify: true);
    }
  }

  void _publish(VoidCallback fn, {required bool notify}) {
    if (notify) {
      setState(fn);
    } else {
      fn();
    }
  }

  void _bindDiagram({required bool notify}) {
    if (!widget.closed || widget.code.trim().isEmpty) {
      _publish(() {
        _png = null;
        _svg = null;
        _error = null;
      }, notify: notify);
      return;
    }
    final api = widget.api;
    if (api == null) {
      _publish(() => _error = '未连接问象服务，无法渲染图表', notify: notify);
      return;
    }
    final key = _cacheKey;
    final cached = WxMermaidCache.instance.peek(key);
    if (cached != null) {
      _publish(() {
        _png = cached.png;
        _svg = cached.svg;
        _error = null;
      }, notify: notify);
      return;
    }
    final gen = ++_requestGen;
    _publish(() {
      _png = null;
      _svg = null;
      _error = null;
    }, notify: notify);
    WxMermaidCache.instance
        .load(
          key,
          () => api.renderMermaidSvg(
            widget.code,
            theme: widget.serverTheme,
            backgroundColor: widget.backgroundColor,
          ),
        )
        .then((diagram) {
          if (!mounted || gen != _requestGen) return;
          setState(() {
            _png = diagram.png;
            _svg = diagram.svg;
            _error = null;
          });
        })
        .catchError((Object err) {
          if (!mounted || gen != _requestGen) return;
          setState(() {
            _error = err.toString().replaceFirst('ApiException: ', '');
            _png = null;
            _svg = null;
          });
        });
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.shellColor ?? Wx.raised;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: DecoratedBox(
        key: const Key('wx-mermaid-diagram'),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(Wx.radius),
          border: Border.all(color: Wx.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.account_tree_outlined, size: 16, color: Wx.muted),
                  const SizedBox(width: 8),
                  Text(
                    '图表',
                    style: TextStyle(
                      color: Wx.muted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.35,
                      fontFamilyFallback: Wx.fontFallback,
                    ),
                  ),
                  if (!widget.closed) ...[
                    const SizedBox(width: 6),
                    Text(
                      '生成中',
                      style: TextStyle(
                        color: Wx.faint,
                        fontSize: 11,
                        fontFamilyFallback: Wx.fontFallback,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const ColoredBox(color: Wx.hairline, child: SizedBox(height: 1)),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
              child: _body(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (!widget.closed) {
      return SizedBox(
        height: 88,
        child: Center(
          child: Text(
            '正在绘制图表…',
            style: TextStyle(color: Wx.muted, fontSize: 13, fontFamilyFallback: Wx.fontFallback),
          ),
        ),
      );
    }

    if (_error != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _error!,
            style: TextStyle(
              color: Wx.danger,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamilyFallback: Wx.fontFallback,
            ),
          ),
          const SizedBox(height: 8),
          WxFencedCode(
            code: widget.code.trim(),
            language: 'mermaid',
            framed: false,
            style: widget.monoStyle ?? const TextStyle(fontFamily: 'ui-monospace', fontSize: 13),
          ),
        ],
      );
    }

    if (_png == null && _svg == null) {
      return SizedBox(
        height: 120,
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Wx.muted.withValues(alpha: 0.75),
            ),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite ? constraints.maxWidth : MediaQuery.sizeOf(context).width - 48;
        final png = _png;
        if (png != null) {
          return Image.memory(
            png,
            width: maxW,
            fit: BoxFit.fitWidth,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => _svgFallback(maxW),
          );
        }
        return _svgFallback(maxW);
      },
    );
  }

  Widget _svgFallback(double maxW) {
    final svg = _svg;
    if (svg == null || svg.isEmpty) {
      return Text(
        '图表无法显示',
        style: TextStyle(color: Wx.danger, fontSize: 13, fontFamilyFallback: Wx.fontFallback),
      );
    }
    return SvgPicture.string(
      svg,
      fit: BoxFit.contain,
      width: maxW,
      theme: const SvgTheme(currentColor: Wx.text),
      errorBuilder: (_, __, ___) => Text(
        '图表无法显示',
        style: TextStyle(color: Wx.danger, fontSize: 13, fontFamilyFallback: Wx.fontFallback),
      ),
    );
  }
}
