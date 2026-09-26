import 'package:flutter/material.dart';

import '../copy/errors.dart';
import '../theme.dart';

class WxMark extends StatelessWidget {
  const WxMark({super.key, this.size = 36});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '问象',
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _MarkPainter()),
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.shortestSide * 0.05);
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.7, 0.7, size.width - 1.4, size.height - 1.4),
      radius,
    );
    canvas.drawRRect(rect, Paint()..color = Wx.surface);
    canvas.drawRRect(
      rect,
      Paint()
        ..color = Wx.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    final barW = size.width * 0.075;
    final bar = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        (size.width - barW) / 2,
        size.height * 0.26,
        barW,
        size.height * 0.48,
      ),
      const Radius.circular(0.4),
    );
    canvas.drawRRect(bar, Paint()..color = Wx.accent);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class WxPageHeader extends StatelessWidget {
  const WxPageHeader({
    super.key,
    this.onBack,
    this.backEnabled = true,
    this.backTooltip = '返回',
    this.showMark = false,
    this.onBrandTap,
    this.brandTooltip = '设置',
    required this.title,
    this.subtitle,
    this.status,
    this.trailing,
  });

  final VoidCallback? onBack;
  final bool backEnabled;
  final String backTooltip;
  final bool showMark;
  final VoidCallback? onBrandTap;
  final String brandTooltip;
  final String title;
  final String? subtitle;
  final Widget? status;
  final List<Widget>? trailing;

  @override
  Widget build(BuildContext context) {
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    return SafeArea(
      bottom: false,
      child: SizedBox(
        height: hasSubtitle ? 64 : 56,
        child: Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Row(
            children: [
              if (onBack != null)
                IconButton(
                  tooltip: backTooltip,
                  onPressed: backEnabled ? onBack : null,
                  icon: const Icon(Icons.arrow_back),
                )
              else if (!showMark)
                const SizedBox(width: Wx.inset),
              Expanded(
                child: _BrandTitle(
                  showMark: showMark,
                  padMark: onBack == null,
                  title: title,
                  subtitle: hasSubtitle ? subtitle : null,
                  status: status,
                  onTap: onBrandTap,
                  tooltip: brandTooltip,
                ),
              ),
              ...?trailing,
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandTitle extends StatelessWidget {
  const _BrandTitle({
    required this.showMark,
    required this.padMark,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.onTap,
    required this.tooltip,
  });

  final bool showMark;
  final bool padMark;
  final String title;
  final String? subtitle;
  final Widget? status;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showMark)
          Padding(
            padding: EdgeInsets.only(left: padMark ? Wx.inset : 0, right: 10),
            child: const WxMark(size: 22),
          ),
        Flexible(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
            ],
          ),
        ),
      ],
    );
    final tappable = onTap == null
        ? brand
        : Tooltip(
            message: tooltip,
            child: InkWell(
              onTap: onTap,
              child: brand,
            ),
          );
    return Row(
      children: [
        Flexible(child: tappable),
        if (status != null) ...[
          const SizedBox(width: 6),
          status!,
        ],
      ],
    );
  }
}

class WxErrorPanel extends StatefulWidget {
  const WxErrorPanel({
    super.key,
    required this.error,
    this.onRetry,
    this.retryLabel = '重试',
  });

  final Object error;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  State<WxErrorPanel> createState() => _WxErrorPanelState();
}

class _WxErrorPanelState extends State<WxErrorPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final detail = errorDetail(widget.error);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Wx.surface,
        borderRadius: BorderRadius.circular(Wx.radius),
        border: Border.all(color: Wx.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              humanizeError(widget.error),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Wx.text),
            ),
            if (detail != null && _open) ...[
              const SizedBox(height: 8),
              SelectableText(
                detail,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Wx.muted,
                      fontSize: 12,
                      height: 1.45,
                    ),
              ),
            ],
            if (detail != null || widget.onRetry != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    if (widget.onRetry != null)
                      TextButton(onPressed: widget.onRetry, child: Text(widget.retryLabel)),
                    if (detail != null)
                      TextButton(
                        onPressed: () => setState(() => _open = !_open),
                        child: Text(_open ? '收起详情' : '详情'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class WxEmpty extends StatelessWidget {
  const WxEmpty({
    super.key,
    required this.title,
    this.detail,
    this.action,
  });

  final String title;
  final String? detail;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
          if (detail != null) ...[
            const SizedBox(height: 8),
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
          if (action != null) ...[
            const SizedBox(height: 16),
            action!,
          ],
        ],
      ),
    );
  }
}

class WxBusy extends StatelessWidget {
  const WxBusy({super.key, this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          if (label != null) ...[
            const SizedBox(height: 14),
            Text(label!, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

class WxHairline extends StatelessWidget {
  const WxHairline({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Wx.hairline,
      child: SizedBox(height: 1, width: double.infinity),
    );
  }
}
