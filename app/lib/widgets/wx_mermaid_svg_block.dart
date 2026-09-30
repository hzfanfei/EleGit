import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../utils/wx_diagram_fit.dart';
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
          final pixels = readRasterSize(png);
          final box = fitDiagramBox(
            maxWidth: maxW,
            pixelWidth: (pixels?.width ?? 0).toDouble(),
            pixelHeight: (pixels?.height ?? 0).toDouble(),
          );
          return Align(
            alignment: Alignment.center,
            child: GestureDetector(
              onTap: () => _openFullscreen(png: png),
              child: Image.memory(
                png,
                width: box.width,
                height: box.height,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
                gaplessPlayback: true,
                errorBuilder: (_, __, ___) => _svgFallback(maxW),
              ),
            ),
          );
        }
        return _svgFallback(maxW);
      },
    );
  }

  void _openFullscreen({Uint8List? png, String? svg}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _DiagramStage(png: png, svg: svg),
      ),
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
    final pixels = readSvgViewBoxSize(svg);
    final box = fitDiagramBox(
      maxWidth: maxW,
      pixelWidth: (pixels?.width ?? 0).toDouble(),
      pixelHeight: (pixels?.height ?? 0).toDouble(),
    );
    return Align(
      alignment: Alignment.center,
      child: GestureDetector(
        onTap: () => _openFullscreen(svg: svg),
        child: SvgPicture.string(
          svg,
          fit: BoxFit.contain,
          width: box.width,
          height: box.height,
          theme: const SvgTheme(currentColor: Wx.text),
          errorBuilder: (_, __, ___) => Text(
            '图表无法显示',
            style: TextStyle(color: Wx.danger, fontSize: 13, fontFamilyFallback: Wx.fontFallback),
          ),
        ),
      ),
    );
  }
}

/// Full-screen diagram. Scale 1 fits the screen; pinch or the buttons zoom,
/// and a drag moves the picture.
class _DiagramStage extends StatefulWidget {
  const _DiagramStage({this.png, this.svg});

  final Uint8List? png;
  final String? svg;

  @override
  State<_DiagramStage> createState() => _DiagramStageState();
}

class _DiagramStageState extends State<_DiagramStage> {
  static const _minScale = 0.35;
  static const _maxScale = 6.0;

  final _transform = TransformationController();

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _zoomBy(double factor) {
    final current = _transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(_minScale, _maxScale);
    if ((next - current).abs() < 0.001) return;
    final size = MediaQuery.sizeOf(context);
    final dx = size.width / 2;
    final dy = size.height / 2;
    final ratio = next / current;
    final around = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(ratio, ratio, 1, 1)
      ..translateByDouble(-dx, -dy, 0, 1);
    _transform.value = around.multiplied(_transform.value);
  }

  @override
  Widget build(BuildContext context) {
    final png = widget.png;
    final svg = widget.svg;
    return Scaffold(
      backgroundColor: Wx.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transform,
              minScale: _minScale,
              maxScale: _maxScale,
              panEnabled: true,
              scaleEnabled: true,
              boundaryMargin: const EdgeInsets.all(160),
              child: png != null
                  ? Image.memory(png, fit: BoxFit.contain, filterQuality: FilterQuality.high)
                  : SvgPicture.string(
                      svg ?? '',
                      fit: BoxFit.contain,
                      theme: const SvgTheme(currentColor: Wx.text),
                    ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: _StageButton(
                  tooltip: '关闭',
                  icon: Icons.close,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Wx.raised.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(color: Wx.hairline),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StageButton(
                        tooltip: '缩小',
                        icon: Icons.remove,
                        onPressed: () => _zoomBy(0.8),
                      ),
                      _StageButton(
                        tooltip: '放大',
                        icon: Icons.add,
                        onPressed: () => _zoomBy(1.25),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StageButton extends StatelessWidget {
  const _StageButton({required this.tooltip, required this.icon, required this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: Wx.text),
    );
  }
}
