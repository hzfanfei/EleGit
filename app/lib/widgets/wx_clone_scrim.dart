import 'dart:async';

import 'package:flutter/material.dart';

import '../copy/errors.dart';
import '../models.dart';
import '../theme.dart';
import 'wx_chrome.dart';

class WxCloneScrim extends StatefulWidget {
  const WxCloneScrim({
    super.key,
    required this.repo,
    this.error,
    this.onRetry,
    this.onDismiss,
    this.dismissLabel = '关闭',
  });

  final RepoItem repo;
  final Object? error;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;
  final String dismissLabel;

  @override
  State<WxCloneScrim> createState() => _WxCloneScrimState();
}

class _WxCloneScrimState extends State<WxCloneScrim> {
  static const _stages = ['准备', '正在克隆', '即将打开'];
  int _stage = 0;
  Timer? _timer;

  String get _path => '~/问象/${widget.repo.owner}/${widget.repo.name}';

  String get _stageDetail {
    switch (_stage) {
      case 0:
        return '先确认 ${widget.repo.fullName}，再落到本机。';
      case 1:
        return '正在克隆到 $_path';
      default:
        return '马上打开这份仓库。';
    }
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (timer) {
      if (!mounted || widget.error != null) return;
      if (_stage < _stages.length - 1) {
        setState(() => _stage += 1);
      }
    });
  }

  @override
  void didUpdateWidget(covariant WxCloneScrim oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null) {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed = widget.error != null;
    return ColoredBox(
      color: const Color(0xCC0C0D0F),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Wx.surface,
              borderRadius: BorderRadius.circular(Wx.radius),
              border: Border.all(color: Wx.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failed ? '克隆失败' : _stages[_stage],
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    failed ? humanizeError(widget.error!) : _stageDetail,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _path,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (!failed) ...[
                    const SizedBox(height: 18),
                    const ClipRRect(
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  ],
                  if (failed) ...[
                    const SizedBox(height: 16),
                    WxErrorPanel(
                      error: widget.error!,
                      onRetry: widget.onRetry,
                      retryLabel: '再试一次',
                    ),
                  ],
                  if (widget.onDismiss != null) ...[
                    SizedBox(height: failed ? 4 : 14),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: widget.onDismiss,
                        child: Text(widget.dismissLabel),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
