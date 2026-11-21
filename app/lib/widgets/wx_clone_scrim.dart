import 'package:flutter/material.dart';

import '../copy/errors.dart';
import '../models.dart';
import '../theme.dart';
import 'wx_chrome.dart';

enum WxCloneMode { open, checkRemote, clone, sync }

class WxCloneScrim extends StatelessWidget {
  const WxCloneScrim({
    super.key,
    required this.repo,
    required this.path,
    this.mode = WxCloneMode.clone,
    this.error,
    this.onRetry,
    this.onDismiss,
    this.dismissLabel = '关闭',
  });

  final RepoItem repo;
  final String path;
  final WxCloneMode mode;
  final Object? error;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;
  final String dismissLabel;

  @override
  Widget build(BuildContext context) {
    final problem = error;
    final (action, detail) = switch (mode) {
      WxCloneMode.open => ('打开', '正在检查 ${repo.fullName} 的本机目录。'),
      WxCloneMode.checkRemote => ('打开', '正在检查 ${repo.fullName} 的远端更新。'),
      WxCloneMode.sync => ('更新', '正在同步 ${repo.fullName} 的远端变更。'),
      WxCloneMode.clone => ('克隆', '正在将 ${repo.fullName} 下载到本机。'),
    };
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
                  Semantics(
                    liveRegion: true,
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            problem == null ? '正在$action' : '$action失败',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (problem == null) ...[
                          const SizedBox(width: 6),
                          const ExcludeSemantics(child: WxLoading(size: 22)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    problem == null ? detail : humanizeError(problem),
                    style: Theme.of(context)
                        .textTheme
                        .bodyLarge
                        ?.copyWith(height: 1.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    path,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (problem != null) ...[
                    const SizedBox(height: 16),
                    WxErrorPanel(
                      error: problem,
                      onRetry: onRetry,
                      retryLabel: '再试一次',
                    ),
                  ],
                  if (onDismiss != null) ...[
                    SizedBox(height: problem != null ? 4 : 14),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: onDismiss,
                        child: Text(dismissLabel),
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
