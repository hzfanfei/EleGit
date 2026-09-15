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
    final r = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      const Radius.circular(9),
    );
    canvas.drawRRect(
      r,
      Paint()
        ..color = Wx.surface
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      r,
      Paint()
        ..color = Wx.hairline
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final bar = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * 0.32, size.height * 0.22, 2.4, size.height * 0.56),
      const Radius.circular(1.2),
    );
    canvas.drawRRect(bar, Paint()..color = Wx.accent);
    canvas.drawCircle(
      Offset(size.width * 0.68, size.height * 0.36),
      2.1,
      Paint()..color = Wx.muted,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class WxErrorPanel extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final detail = errorDetail(error);
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
              humanizeError(error),
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: Wx.text),
            ),
            if (detail != null) ...[
              const SizedBox(height: 8),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: Text('详情', style: Theme.of(context).textTheme.bodyMedium),
                  dense: true,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        detail,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: Wx.muted,
                              fontSize: 12,
                              height: 1.45,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
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
